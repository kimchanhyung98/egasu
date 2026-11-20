import Foundation

@MainActor
final class KimiProvider: ProviderRuntime {
    let provider = Provider(
        id: "kimi",
        displayName: "Kimi",
        icon: .providerMark("kimi"),
        links: [],
        usesDedicatedSpendLines: true
    )

    let authStore: KimiAuthStore
    let usageClient: KimiUsageClient
    let credentialLock: KimiCredentialLock
    let usageScanner: KimiUsageScanner
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    var usageTimerObservations: [UsageTimerObservation] = []
    var usageTimerCredential: KimiCredentialDocument?

    var retainsDedicatedSpendOnScanFailure: Bool { true }

    init(
        authStore: KimiAuthStore = KimiAuthStore(),
        usageClient: KimiUsageClient = KimiUsageClient(),
        credentialLock: KimiCredentialLock = KimiCredentialLock(),
        usageScanner: KimiUsageScanner? = nil,
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.credentialLock = credentialLock
        self.usageScanner = usageScanner ?? KimiUsageScanner(
            environment: authStore.environment, homeDirectory: authStore.homeDirectory()
        )
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "kimi.session", provider: provider, title: "Session", sessionStartSignal: .zeroUsage)
                .exportingLimit("session", unit: "percent"),
            .percent(id: "kimi.weekly", provider: provider, title: "Weekly")
                .supportingSoftLimit(.weekly)
                .exportingLimit("weekly", unit: "percent"),
            .percent(id: "kimi.total", provider: provider, title: "Total Usage")
                .supportingSoftLimit(.monthly, acceptsMissingDuration: true)
                .exportingLimit("totalUsage", unit: "percent"),
            .values(
                id: "kimi.extra", provider: provider, title: "Extra Usage", selection: .kind(.dollars),
                valueWord: "spent"
            )
            .exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .dollarBalance(id: "kimi.extraBalance", provider: provider, title: "Extra Balance", valueWord: "left")
                .exportingLimit("extraUsageBalance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        ]
    }

    func hasLocalCredentials() async -> Bool {
        do {
            guard let document = try await loadOffMainActor({ [authStore] in
                try authStore.loadCredentialDocument()
            }) else {
                return false
            }
            return authStore.isUsable(document, now: now())
        } catch {
            return false
        }
    }

    func refresh() async -> ProviderSnapshot {
        let quota = await readQuota()
        var snapshot = quota.snapshot
        guard snapshot.errorCategory == nil else { return snapshot }
        let refreshedAt = snapshot.refreshedAt
        do {
            try Task.checkCancellation()
            if let scan = try await usageScanner.scan(now: refreshedAt, pricing: await pricing()) {
                if !scan.series.daily.isEmpty || (scan.invalidRows == 0 && scan.fileErrors.isEmpty) {
                    snapshot.totalSpendLines = scan.totalSpendLines(now: refreshedAt)
                }
                for warning in scan.readWarnings {
                    appendWarning(warning, to: &snapshot)
                }
                if !scan.warnings.isEmpty { snapshot.isDegraded = true }
                // 개별 진단은 모두 기록하고, 대표 원인은 저장소 오류 > 형식 오류 > 가격 미확인 순으로 선택.
                if scan.hasUnpricedUsage {
                    snapshot.reportedPartialFailure = .other
                    AppDiagnostics.record(
                        .historyScan, result: .degraded, category: .other, providerID: provider.id,
                        localContext: "local usage contains unpriced models or cache pricing")
                }
                if scan.invalidRows > 0 {
                    snapshot.reportedPartialFailure = .decoding
                    AppDiagnostics.record(
                        .historyScan, result: .degraded, category: .decoding, providerID: provider.id,
                        localContext: "invalid Kimi Code usage records=\(scan.invalidRows)"
                    )
                }
                if let fileError = KimiHistoryError.representative(in: scan.fileErrors) {
                    snapshot.reportedPartialFailure = fileError.errorCategory
                    AppDiagnostics.record(
                        .historyScan, result: .degraded,
                        category: fileError.errorCategory,
                        providerID: provider.id, localContext: scan.readWarnings.joined(separator: " "))
                }
            }
        } catch is CancellationError {
            return ProviderSnapshot.error(provider: provider, error: CancellationError())
        } catch {
            snapshot.reportedPartialFailure = ErrorCategory.classify(error)
            AppDiagnostics.record(
                .historyScan, result: .failure, providerID: provider.id, error: error
            )
            appendWarning((error as? KimiHistoryError ?? .unreadable).localizedDescription, to: &snapshot)
        }
        // 이력 조회 중 로그인 전환 가능. 한도 요청에 사용한 인증과 같은 경우에만 결과 사용.
        if let credential = quota.credential, hasSoftLimitQuota(in: snapshot.lines) {
            do {
                let current = try await loadOffMainActor { [authStore] in try authStore.loadCredentialDocument() }
                try Task.checkCancellation()
                guard current == credential else { throw KimiAuthError.credentialsChanged }
            } catch is CancellationError {
                return ProviderSnapshot.error(provider: provider, error: CancellationError())
            } catch {
                usageTimerObservations = []
                usageTimerCredential = nil
                return ProviderSnapshot.error(provider: provider, error: normalized(error))
            }
        }
        return snapshot
    }

    private func appendWarning(_ message: String, to snapshot: inout ProviderSnapshot) {
        snapshot.warning = [snapshot.warning, message].compactMap { $0 }.joined(separator: " ")
        snapshot.warningPresentation = (snapshot.warningPresentation ?? []) + [.init(message)]
        snapshot.isDegraded = true
    }

    func quotaSnapshot() async -> ProviderSnapshot {
        await readQuota().snapshot
    }

    func readQuota(using prepared: KimiCredentialDocument? = nil) async -> (
        snapshot: ProviderSnapshot, observation: UsageTimerObservation?, credential: KimiCredentialDocument?
    ) {
        usageTimerObservations = []
        usageTimerCredential = nil
        do {
            var document: KimiCredentialDocument
            if let prepared {
                document = prepared
            } else if let current = try await loadOffMainActor({ [authStore] in
                try authStore.loadCredentialDocument()
            }) {
                document = current
            } else {
                throw KimiAuthError.notLoggedIn
            }
            guard authStore.isUsable(document, now: now()) else {
                throw KimiAuthError.authExpired
            }

            if prepared == nil && authStore.needsRefresh(document, now: now()) {
                document = try await rotate(document, force: false)
            }
            guard var accessToken = document.credentials.accessToken?.nilIfEmpty else {
                throw KimiAuthError.authExpired
            }
            let usesAPIKey = if case .apiKey = document.credentials.source { true } else { false }

            var response = try await fetch(accessToken, service: document.service)
            if ProviderAuthRetry.isAuthFailure(response) {
                if usesAPIKey {
                    throw KimiAuthError.apiKeyRejected
                }
                guard prepared == nil, case .current = document.credentials.source,
                      authStore.oauthLockEnabled
                else {
                    throw KimiAuthError.authExpired
                }
                document = try await rotate(document, force: true)
                guard let refreshedAccessToken = document.credentials.accessToken?.nilIfEmpty else {
                    throw KimiAuthError.authExpired
                }
                accessToken = refreshedAccessToken
                response = try await fetch(accessToken, service: document.service)
                guard !ProviderAuthRetry.isAuthFailure(response) else {
                    throw KimiAuthError.authExpired
                }
            }

            try ProviderAuthRetry.requireSuccess(
                response,
                authExpired: KimiAuthError.authExpired,
                requestFailed: KimiUsageError.requestFailed
            )
            let mapped = try KimiUsageMapper.map(response.body)
            let observedAt = now()
            let observation: UsageTimerObservation?
            if !usesAPIKey,
               let subject = ProviderParse.jwtPayload(accessToken)?["sub"] as? String, !subject.isEmpty,
               !UsageTimerObservation.hasExhaustedQuota(mapped.lines) {
                // 기존 기본 서버의 계정 키 유지, 다른 서버의 동명 계정은 분리.
                let identity = document.service == .standard
                    ? subject : "\(document.service.baseURL)|\(document.service.oauthHost)|\(subject)"
                observation = UsageTimerObservation.from(
                    lines: mapped.lines, accountKey: UsageTimerObservation.accountKey(family: "kimi", identity: identity),
                    timerID: "kimi.session", observedAt: observedAt
                )
            } else {
                observation = nil
            }
            usageTimerObservations = [observation].compactMap { $0 }
            usageTimerCredential = observation == nil ? nil : document
            let snapshot = ProviderSnapshot.make(
                provider: provider,
                plan: mapped.plan,
                lines: mapped.lines,
                refreshedAt: observedAt, liveQuotaObservedAt: observedAt
            )
            return (snapshot, observation, document)
        } catch {
            usageTimerObservations = []
            usageTimerCredential = nil
            return (ProviderSnapshot.error(provider: provider, error: normalized(error)), nil, nil)
        }
    }

    private func rotate(
        _ original: KimiCredentialDocument,
        force: Bool
    ) async throws -> KimiCredentialDocument {
        guard case .current(_, _, let lockTarget) = original.credentials.source,
              authStore.oauthLockEnabled
        else {
            throw KimiAuthError.authExpired
        }

        let handle = try await credentialLock.acquire(target: lockTarget)
        do {
            let live = try await loadOffMainActor { [authStore] in
                try authStore.reloadCurrentDocument(original)
            }
            let tokenChanged = live.credentials.accessToken != original.credentials.accessToken
            if tokenChanged, authStore.hasUsableAccess(live, now: now()) {
                guard await handle.release() else {
                    throw KimiAuthError.credentialLockCompromised
                }
                return live
            }
            if !force, !authStore.needsRefresh(live, now: now()),
               authStore.isUsable(live, now: now()) {
                guard await handle.release() else {
                    throw KimiAuthError.credentialLockCompromised
                }
                return live
            }
            guard let refreshToken = live.credentials.refreshToken?.nilIfEmpty else {
                throw KimiAuthError.authExpired
            }

            let rotated: KimiTokenRefresh
            do {
                rotated = try await usageClient.refreshToken(refreshToken: refreshToken, service: live.service)
            } catch let error as KimiAuthError {
                throw error
            } catch let error as KimiUsageError {
                throw error
            } catch {
                throw KimiUsageError.connectionFailed
            }
            try await handle.performWhileValid { [authStore] in
                try await loadOffMainActor {
                    try authStore.persistRotatedCredentials(replacing: live, with: rotated)
                }
            }

            let updated = try await loadOffMainActor { [authStore] in
                try authStore.reloadCurrentDocument(live)
            }
            guard await handle.release() else {
                throw KimiAuthError.credentialLockCompromised
            }
            return updated
        } catch {
            guard await handle.release() else {
                throw KimiAuthError.credentialLockCompromised
            }
            throw error
        }
    }

    private func fetch(_ accessToken: String, service: KimiService) async throws -> HTTPResponse {
        do {
            return try await usageClient.fetchUsage(accessToken: accessToken, service: service)
        } catch {
            throw KimiUsageError.connectionFailed
        }
    }

    private func normalized(_ error: Error) -> Error {
        if error is KimiAuthError || error is KimiUsageError { return error }
        return KimiUsageError.connectionFailed
    }
}
