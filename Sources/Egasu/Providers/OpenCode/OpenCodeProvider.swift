import Foundation

/// OpenCode provider의 typed failure — telemetry가 안정된 category로 그룹화 (`ErrorCategory.swift` 참고).
enum OpenCodeUsageError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case requestFailed(Int)
    case invalidResponse
    case credentialsChanged
    /// 인증 파일 읽기·해석 실패. detail에는 고정된 단계와 오류 코드만 저장.
    case credentialsUnreadable(detail: String)
    /// 디스크에 database가 있으나 이번 refresh에서 하나도 읽지 못한 상태.
    /// 빈 scan으로 확정값처럼 보이는 $0 meter를 그리는 대신 크게 실패.
    case databaseUnreadable

    var errorDescription: String? {
        switch self {
        case .credentialsChanged: return "OpenCode sign-in changed during refresh. Refresh this account and try again."
        case .requestFailed(let status): return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .invalidResponse: return ProviderUsageErrorText.invalidResponse
        case .notLoggedIn:
            return "OpenCode not detected. Log in with OpenCode Go or use OpenCode locally first."
        case .credentialsUnreadable:
            return "Couldn't read OpenCode's auth.json. Check its file permissions or log into OpenCode Go again."
        case .databaseUnreadable:
            return "Couldn't read OpenCode's local database. Quit OpenCode and refresh, or check the data directory's permissions."
        }
    }
}

/// Go 구독 한도는 서버에서, Go·Console 지출 이력은 로컬 원장에서 조회.
@MainActor
final class OpenCodeProvider: ProviderRuntime {
    let provider = Provider(
        id: "opencode",
        displayName: "OpenCode",
        icon: .providerMark("opencode"),
        links: [
            .init(label: "Dashboard", url: "https://opencode.ai/auth")
        ]
    )

    let http: any HTTPClient
    let authStore: OpenCodeAuthStore
    let usageScanner: OpenCodeUsageScanner
    let sharedUsage: UsageCollectionCoordinator
    let now: @Sendable () -> Date

    /// 이 머신의 원본 기록 범위. OpenCode가 기록한 비용도 카탈로그 추정값일 수 있음.
    private let sourceNote = "From your OpenCode logs and local tools"

    /// 인증 파일 읽기가 연속으로 실패하면 한 번만 경고. 읽기 성공 뒤의 새 실패는 다시 기록.
    private var loggedAuthReadFailure = false

    init(
        http: any HTTPClient = URLSessionHTTPClient(sendsCookies: false),
        authStore: OpenCodeAuthStore = OpenCodeAuthStore(),
        usageScanner: OpenCodeUsageScanner = OpenCodeUsageScanner(),
        sharedUsage: UsageCollectionCoordinator = .shared,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.http = http
        self.authStore = authStore
        self.usageScanner = usageScanner
        self.sharedUsage = sharedUsage
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        // 같은 기간은 고정·숨김 설정을 공유하고, 실측(%)과 로컬 추정(USD)은 API 키로 구분.
        // 지출·사용 추이는 OpenCode 로컬 DB와 공유 도구의 기록을 합산.
        [
            .boundedDollars(id: "opencode.session", provider: provider, title: "Session", limit: OpenCodeUsageMapper.sessionCap)
                .exportingLimit("session", unit: "usd", estimated: true, progressFormat: .dollars)
                .exportingLimit("goSession", unit: "percent", progressFormat: .percent),
            .boundedDollars(id: "opencode.weekly", provider: provider, title: "Weekly", limit: OpenCodeUsageMapper.weeklyCap)
                .supportingSoftLimit(.weekly)
                .exportingLimit("weekly", unit: "usd", estimated: true, progressFormat: .dollars)
                .exportingLimit("goWeekly", unit: "percent", progressFormat: .percent),
            .boundedDollars(id: "opencode.monthly", provider: provider, title: "Monthly", limit: OpenCodeUsageMapper.monthlyCap)
                .supportingSoftLimit(.monthly)
                .exportingLimit("monthly", unit: "usd", estimated: true, progressFormat: .dollars)
                .exportingLimit("goMonthly", unit: "percent", progressFormat: .percent),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .machineLocal,
                    estimatedCost: true,
                    sourceNote: sourceNote
                )
        ] + WidgetDescriptor.spendTiles(provider: provider)
    }

    func hasLocalCredentials() async -> Bool {
        // 읽기 불가 auth.json도 OpenCode 흔적. refresh에서 접근 오류 안내.
        if await loadOffMainActor({ [authStore, usageScanner] in
            do {
                if try authStore.goAPIKey() != nil { return true }
            } catch {
                return true
            }
            return usageScanner.hasHostedUsage()
        }) { return true }
        let shared = await sharedUsage.scan(providerID: provider.id, now: now(), pricing: .empty, allowEstimates: false)
        return !Task.isCancelled && shared?.usageHistory?.series.daily.isEmpty == false
    }

    func refresh() async -> ProviderSnapshot {
        // 자정에 집계 기간이 달라지지 않도록 조회 시작 시각을 모든 지표에 적용.
        let refreshedAt = now()

        // 인증 파일을 읽지 못하면 경고를 표시하고 접근 가능한 사용 이력은 계속 조회.
        var goKey: String?
        var authReadError: OpenCodeUsageError?
        do {
            goKey = try await loadOffMainActor { [authStore] in try authStore.goAPIKey() }
            loggedAuthReadFailure = false
        } catch let error as OpenCodeUsageError {
            authReadError = error
            if case .credentialsUnreadable(let detail) = error, !loggedAuthReadFailure {
                loggedAuthReadFailure = true
                AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            }
        } catch {
            authReadError = .credentialsUnreadable(detail: AppLog.errorDetails(error))
        }

        var live: OpenCodeGoQuota?
        var observedAt: Date?
        var quotaError: Error?
        if let goKey {
            do {
                live = try await OpenCodeGoQuota.fetch(key: goKey, http: http, now: now)
                observedAt = now()
                if live?.isIncomplete == true { quotaError = OpenCodeUsageError.invalidResponse }
            } catch {
                quotaError = error
            }
            if let quotaError {
                AppDiagnostics.record(.providerRefresh, result: .degraded, providerID: provider.id,
                                      error: quotaError, localContext: "Go subscription usage unavailable or incomplete")
            }
        }

        let scan: OpenCodeUsageScan?
        var nativeScanError: Error?
        do {
            scan = try await usageScanner.scan(now: refreshedAt, hasGoKey: false)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                return ProviderSnapshot.error(provider: provider, error: CancellationError())
            }
            scan = nil
            nativeScanError = error
        }

        let sharedScan = await sharedUsage.scan(providerID: provider.id, now: refreshedAt, pricing: .empty, allowEstimates: false)
        guard !Task.isCancelled else { return ProviderSnapshot.error(provider: provider, error: CancellationError()) }
        if let goKey {
            do {
                guard try await loadOffMainActor({ [authStore] in try authStore.goAPIKey() }) == goKey else {
                    return .error(provider: provider, error: OpenCodeUsageError.credentialsChanged)
                }
            } catch { return .error(provider: provider, error: error) }
        }
        let logScan = DailyUsageAccumulator.merged([scan?.logScan, sharedScan])
        if live == nil, let nativeScanError, sharedScan?.usageHistory?.series.daily.isEmpty != false {
            return .error(provider: provider, error: nativeScanError)
        }
        if live == nil, logScan == nil {
            return .error(provider: provider, error: quotaError ?? authReadError ?? OpenCodeUsageError.notLoggedIn)
        }

        var lines = live?.lines ?? []
        if live == nil, let windows = scan?.goWindows {
            lines += OpenCodeUsageMapper.meterLines(windows)
        }
        if let logScan {
            SpendTileMapper.appendTokenUsage(
                logScan.series, to: &lines, now: refreshedAt,
                estimated: false,
                estimatedDays: Set(scan?.logScan.series.daily.filter { $0.costUSD != nil }.map(\.date) ?? []),
                unknownModelsByDay: logScan.unknownModelsByDay,
                modelUsage: logScan.modelUsage,
                modelSourceNote: sourceNote
            )
            SpendTileMapper.appendUsageTrend(logScan.series, to: &lines, now: refreshedAt, note: sourceNote)
        }
        MetricLine.appendNoDataIfNeeded(&lines)

        let plan: String? = live != nil || scan?.goWindows != nil ? "Go" : nil
        let errors: [Error] = [quotaError, nativeScanError, authReadError].compactMap { $0 }
        let warningPresentations = errors.map(UserFacingErrors.presentation) + (logScan?.readWarning.map { [.init($0)] } ?? [])
        let warning = (errors.map(\.localizedDescription) + [logScan?.readWarning].compactMap { $0 }).joined(separator: " ")
        return ProviderSnapshot.make(
            provider: provider,
            plan: plan,
            lines: lines,
            refreshedAt: refreshedAt,
            usageHistory: logScan?.usageHistory,
            warning: warning.nilIfEmpty,
            warningPresentation: warningPresentations.isEmpty ? nil : warningPresentations,
            isDegraded: errors.isEmpty ? nil : true,
            incompleteQuotaWindows: live?.missingWindows, liveQuotaObservedAt: observedAt, quotaObservedAt: observedAt
        )
    }
}
