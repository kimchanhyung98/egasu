import Foundation

@MainActor
final class CopilotProvider: ProviderRuntime {
    /// Copilot credit usage를 실은 org slug를 caching하는 `UserDefaults` key — steady-state refresh는 모든 org 재탐색 대신 billing 호출 1회.
    nonisolated static let billingOrgDefaultsKey = "copilot.billingOrg"

    let provider = Provider(
        id: "copilot",
        displayName: "Copilot",
        icon: .providerMark("copilot"),
        links: [
            .init(label: "Status", url: "https://www.githubstatus.com/"),
            .init(label: "Dashboard", url: "https://github.com/settings/billing")
        ]
    )

    let authStore: CopilotAuthStore
    let usageClient: CopilotUsageClient
    let orgBillingClient: CopilotOrgBillingClient
    let usageScanner: CopilotUsageScanner
    let sharedUsage: UsageCollectionCoordinator
    let defaults: UserDefaults
    let now: @Sendable () -> Date
    private static let historySourceNote = "From your Copilot CLI logs and local tools"

    init(
        authStore: CopilotAuthStore = CopilotAuthStore(),
        usageClient: CopilotUsageClient = CopilotUsageClient(),
        orgBillingClient: CopilotOrgBillingClient = CopilotOrgBillingClient(),
        usageScanner: CopilotUsageScanner = CopilotUsageScanner(),
        sharedUsage: UsageCollectionCoordinator = .shared,
        defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.orgBillingClient = orgBillingClient
        self.usageScanner = usageScanner
        self.sharedUsage = sharedUsage
        self.defaults = defaults
        self.now = now
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "copilot.premium", provider: provider, title: "Credits")
                .supportingSoftLimit(.monthly)
                .exportingLimit("premiumCredits", unit: "credits", source: .progressOrValue(kind: .count))
                .exportingHistory(scope: .machineLocal, estimatedCost: false, sourceNote: Self.historySourceNote),
            .values(id: "copilot.extra", provider: provider, title: "Extra Usage", selection: .kind(.count))
                .exportingLimit("extraUsage", unit: "count", source: .value(kind: .count)),
            .values(id: "copilot.orgCredits", provider: provider, title: "Org Credits", selection: .kind(.count))
                .exportingLimit("orgCredits", unit: "credits", source: .value(kind: .count, label: "credits")),
            .values(id: "copilot.orgSpend", provider: provider, title: "Org Spend", selection: .kind(.dollars), valueWord: "spent")
                .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars)),
            .percent(id: "copilot.chat", provider: provider, title: "Chat")
                .supportingSoftLimit(.monthly)
                .exportingLimit("chat", unit: "percent"),
            .percent(id: "copilot.completions", provider: provider, title: "Completions")
                .supportingSoftLimit(.monthly)
                .exportingLimit("completions", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        if await loadOffMainActor({ [authStore, usageScanner] in
            usageScanner.hasLocalUsageStore() || authStore.loadToken() != nil
        }) { return true }
        let shared = await sharedUsage.scan(providerID: provider.id, now: now(), pricing: .empty, allowEstimates: false)
        return !Task.isCancelled && shared?.usageHistory?.series.daily.isEmpty == false
    }

    func refresh() async -> ProviderSnapshot {
        let refreshedAt = now()
        var snapshot: ProviderSnapshot
        do {
            snapshot = try await quotaSnapshot(refreshedAt: refreshedAt)
        } catch {
            snapshot = ProviderSnapshot.error(provider: provider, error: error)
            snapshot.refreshedAt = refreshedAt
        }

        var native: LogUsageScan?
        do {
            native = try await usageScanner.scan(now: refreshedAt)
        } catch is CancellationError {
            return snapshot
        } catch {
            AppDiagnostics.record(
                .historyScan, result: .failure, category: ErrorCategory.classify(error), providerID: provider.id
            )
            appendWarning(error.localizedDescription, presentation: UserFacingErrors.presentation(error), to: &snapshot)
            native = LogUsageScan(series: .init(daily: []), unknownModelsByDay: [:], readFailureCount: 1)
        }
        let shared = await sharedUsage.scan(providerID: provider.id, now: refreshedAt, pricing: .empty, allowEstimates: false)
        guard !Task.isCancelled else { return snapshot }
        if let scan = DailyUsageAccumulator.merged([native, shared]) {
            if let history = scan.usageHistory {
                // 로컬 이력은 현재 원격 로그인과 무관한 Mac 전체 기록. 할당량 실패도 이 기록을 가리지 않음.
                snapshot.usageHistory = history
                if snapshot.errorCategory == nil {
                    snapshot = UsageHistorySnapshotRenderer.render(
                        local: snapshot, history: history,
                        descriptor: UsageHistoryDescriptor(
                            scope: .machineLocal, estimatedCost: false, sourceNote: Self.historySourceNote
                        ),
                        now: refreshedAt, combined: false
                    )
                }
            }
            if let warning = shared?.readWarning { appendWarning(warning, to: &snapshot) }
        }
        return snapshot
    }

    private func appendWarning(_ message: String, presentation: LocalizedMessage? = nil, to snapshot: inout ProviderSnapshot) {
        snapshot.warningPresentation = (snapshot.warningPresentation ?? []) + [presentation ?? .init(message)]
        snapshot.warning = [snapshot.warning, message].compactMap { $0 }.joined(separator: " ")
        snapshot.isDegraded = true
    }

    private func quotaSnapshot(refreshedAt: Date) async throws -> ProviderSnapshot {
        let token = await loadOffMainActor { [authStore] in authStore.loadToken() }
        guard let token else {
            throw CopilotAuthError.notLoggedIn
        }

        do {
            let response = try await usageClient.fetchUsage(token: token.value)

            if response.statusCode == 401 || response.statusCode == 403 {
                throw CopilotAuthError.tokenInvalid
            }
            guard (200..<300).contains(response.statusCode) else {
                throw CopilotUsageError.requestFailed(response.statusCode)
            }

            let mapped = try CopilotUsageMapper.map(response)
            let observedAt = mapped.isOrgManagedSeat ? nil : now()

            let warning: String?
            if mapped.hasIncompleteQuota {
                AppLog.warn(LogTag.plugin("copilot"), "monthly quota response contained an incomplete bucket")
                warning = "Some Copilot quota data is unavailable. Try refreshing again later."
            } else if mapped.hasInvalidPersonalCredits {
                AppLog.warn(LogTag.plugin("copilot"), "personal credits used is invalid; omitting personal credits")
                warning = "Personal Credits are unavailable. Try refreshing again later."
            } else {
                warning = nil
            }

            var snapshot = ProviderSnapshot.make(
                provider: provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: refreshedAt,
                warning: warning,
                isDegraded: warning == nil ? nil : true,
                incompleteQuotaWindows: mapped.hasIncompleteQuota ? [.monthly] : nil,
                liveQuotaObservedAt: observedAt
            )
            // 조직 청구 실패 시 이미 확인한 개인 지표와 요금제 유지.
            if mapped.isOrgManagedSeat {
                do {
                    snapshot.lines += try await orgBillingLines(token: token.value)
                } catch {
                    if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                        return snapshot
                    }
                    snapshot.reportedPartialFailure = ErrorCategory.classify(error)
                    appendWarning(
                        "Copilot organization billing is unavailable. Try refreshing again later.", to: &snapshot)
                    AppLog.warn(
                        LogTag.plugin("copilot"), "organization billing unavailable \(AppLog.errorDetails(error))")
                }
            }
            return snapshot
        } catch let error as CopilotAuthError {
            throw error
        } catch let error as CopilotUsageError {
            throw error
        } catch {
            throw CopilotUsageError.connectionFailed
        }
    }

    // MARK: - Org billing lookup

    /// 저장한 조직의 일시 장애는 다음 갱신에 재시도. 탐색 중 다른 조직에서 정상 자료를 얻으면 그 결과 사용.
    private func orgBillingLines(token: String) async throws -> [MetricLine] {
        if let cached = defaults.string(forKey: Self.billingOrgDefaultsKey) {
            if let lines = try await usageLines(org: cached, token: token) { return lines }
            try Task.checkCancellation()
            defaults.removeObject(forKey: Self.billingOrgDefaultsKey)
        }

        let response = try await orgBillingClient.fetchUserOrgs(token: token)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: break
        case 403, 404: return []
        default: throw CopilotUsageError.requestFailed(response.statusCode)
        }

        let orgs = try CopilotOrgBillingMapper.orgLogins(response)
        var lookupError: Error?
        for org in orgs.logins {
            do {
                if let lines = try await usageLines(org: org, token: token) {
                    try Task.checkCancellation()
                    defaults.set(org, forKey: Self.billingOrgDefaultsKey)
                    return lines
                }
            } catch {
                try ProviderAuthRetry.rethrowCancellation(error)
                if lookupError == nil { lookupError = error }
                AppLog.debug(
                    LogTag.plugin("copilot"), "organization summary lookup failed \(AppLog.errorDetails(error))")
            }
        }
        if let lookupError { throw lookupError }
        if orgs.incomplete { throw CopilotUsageError.invalidResponse }
        return []
    }

    /// 조직의 청구 자료가 없거나 접근 권한이 없으면 nil. 일시적인 오류와 잘못된 응답은 호출부에 전달.
    private func usageLines(org: String, token: String) async throws -> [MetricLine]? {
        let response = try await orgBillingClient.fetchUsageSummary(org: org, token: token)
        try Task.checkCancellation()
        switch response.statusCode {
        case 200: return try CopilotOrgBillingMapper.usageLines(response)
        case 403, 404: return nil
        default: throw CopilotUsageError.requestFailed(response.statusCode)
        }
    }
}
