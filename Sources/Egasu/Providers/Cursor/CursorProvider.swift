import Foundation

@MainActor
final class CursorProvider: CredentialBoundSnapshotProvider {
    let provider = Provider(
        id: "cursor",
        displayName: "Cursor",
        icon: .providerMark("cursor"),
        links: [
            .init(label: "Status", url: "https://status.cursor.com/"),
            .init(label: "Dashboard", url: "https://www.cursor.com/dashboard")
        ]
    )

    let authStore: CursorAuthStore
    let usageClient: CursorUsageClient
    let now: @Sendable () -> Date
    let pricing: @Sendable () async -> ModelPricing

    init(
        authStore: CursorAuthStore = CursorAuthStore(),
        usageClient: CursorUsageClient = CursorUsageClient(),
        now: @escaping @Sendable () -> Date = Date.init,
        pricing: @escaping @Sendable () async -> ModelPricing = { await ModelPricingStore.shared.current() }
    ) {
        self.authStore = authStore
        self.usageClient = usageClient
        self.now = now
        self.pricing = pricing
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage")
                .supportingSoftLimit(.weekly, .monthly, allowsDSTOffset: true)
                .exportingLimit("totalUsage", unit: "percent"),
            .percent(id: "cursor.auto", provider: provider, title: "Auto Usage", metricLabel: "Auto usage")
                .supportingSoftLimit(.weekly, .monthly, allowsDSTOffset: true)
                .exportingLimit("autoUsage", unit: "percent"),
            .percent(id: "cursor.api", provider: provider, title: "API Usage", metricLabel: "API usage")
                .supportingSoftLimit(.weekly, .monthly, allowsDSTOffset: true)
                .exportingLimit("apiUsage", unit: "percent"),
            .boundedDollars(id: "cursor.onDemand", provider: provider, title: "Extra Usage", metricLabel: "On-demand", limit: 100, valueWord: "spent")
                .exportingLimit("onDemand", unit: "usd", source: .progressOrValue(kind: .dollars)),
            .boundedCount(id: "cursor.requests", provider: provider, title: "Requests", limit: 500,
                          suffix: "requests", periodDurationMs: CursorUsageMapper.billingPeriodMs)
            .supportingSoftLimit(.weekly, .monthly, allowsDSTOffset: true)
                .exportingLimit("requests", unit: "requests"),
            .dollarBalance(id: "cursor.credits", provider: provider, title: "Credits", valueWord: "left")
                .exportingLimit("credits", kind: .balance, unit: "usd", source: .value(kind: .dollars)),
            .usageTrend(provider: provider)
                .exportingHistory(
                    scope: .accountWide,
                    estimatedCost: false,
                    sourceNote: WidgetData.cursorUsageHistoryNote
                )
        ] + WidgetDescriptor.spendTiles(
            provider: provider,
            valueTooltipNote: WidgetData.cursorUsageHistoryNote
        )
    }

    func hasLocalCredentials() async -> Bool {
        // `refresh()`와 같은 source: state DB 또는 keychain의 auth state면 충분.
        await loadOffMainActor { [authStore] in authStore.loadAuthState() } != nil
    }

    func currentIdentityKey(allowKeychainInteraction: Bool = true) async -> String? {
        guard
            let state = await loadOffMainActor({ [authStore] in
                authStore.loadAuthState(allowKeychainInteraction: allowKeychainInteraction)
            })
        else { return nil }
        let token = refreshedKeychainToken?.source == state ? refreshedKeychainToken?.accessToken : state.accessToken
        return token.flatMap { CursorUsageClient.session(from: $0)?.userID }
    }

    private var refreshIsDegraded = false
    private var historyRetryAfter: Date?
    private var mergedAccountID: String?
    private var historySessionID: String?
    private var refreshedKeychainToken: (source: CursorAuthState, accessToken: String)?

    func refresh() async -> ProviderSnapshot {
        refreshIsDegraded = false
        guard var state = await loadOffMainActor({ [authStore] in authStore.loadAuthState() }) else {
            refreshedKeychainToken = nil
            historyRetryAfter = nil
            historySessionID = nil
            mergedAccountID = nil
            return ProviderSnapshot.error(provider: provider, error: CursorAuthError.notLoggedIn)
        }

        do {
            let result = try await probe(authState: &state)
            // 여러 청구 요청 사이 외부 로그인 전환 가능. 같은 계정의 토큰 회전은 허용.
            guard let latest = await loadOffMainActor({ [authStore] in authStore.loadAuthState() }) else {
                throw CursorAuthError.credentialsChanged
            }
            if latest != state {
                guard let identity = result.producedByIdentityKey, let token = latest.accessToken,
                    CursorUsageClient.session(from: token)?.userID == identity else {
                    throw CursorAuthError.credentialsChanged
                }
            }
            return result
        } catch {
            if error is CursorAuthError { refreshedKeychainToken = nil }
            var failure = ProviderSnapshot.error(provider: provider, error: error)
            if !Task.isCancelled {
                failure.producedByIdentityKey = await currentIdentityKey()
            }
            return failure
        }
    }

    private func probe(authState: inout CursorAuthState) async throws -> ProviderSnapshot {
        if refreshedKeychainToken?.source != authState { refreshedKeychainToken = nil }
        var accessToken = refreshedKeychainToken?.accessToken
            ?? authState.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty

        if authStore.needsRefresh(accessToken) {
            do {
                if let refreshed = try await refreshAccessToken(authState: authState) {
                    if refreshed.persisted { authState.accessToken = refreshed.accessToken }
                    accessToken = refreshed.accessToken
                } else if accessToken == nil {
                    throw CursorAuthError.notLoggedIn
                }
            } catch CursorAuthError.credentialsChanged {
                throw CursorAuthError.credentialsChanged
            } catch {
                if accessToken == nil {
                    throw error
                }
            }
        }

        guard let accessToken else {
            throw CursorAuthError.notLoggedIn
        }

        let fetchedUsage = try await fetchUsageWithRetry(accessToken: accessToken, authState: &authState)
        let usageObservedAt = now()
        let usageResponse = fetchedUsage.response
        try ProviderAuthRetry.requireSuccess(
            usageResponse,
            authExpired: CursorAuthError.tokenExpired,
            requestFailed: { CursorUsageError.requestFailed($0) }
        )
        guard let usage = ProviderParse.jsonObject(usageResponse.body) else {
            throw CursorUsageError.invalidResponse
        }
        // 저장 실패 시 원본 비교용 state와 이번 요청의 live token을 분리.
        let currentToken = fetchedUsage.accessToken

        let identity = CursorUsageClient.session(from: currentToken)?.userID
        let plan = await fetchPlanInfo(accessToken: currentToken)
        if let isMerged = plan.isMerged {
            mergedAccountID = isMerged ? identity : nil
        }
        let isKnownMerged = plan.isMerged == true || (identity != nil && identity == mergedAccountID)
        let stripeBilling: (balanceCents: Double, isMerged: Bool)? = if plan.isMerged == nil, !isKnownMerged {
            await fetchStripeBilling(accessToken: currentToken)
        } else {
            nil
        }
        if isKnownMerged || stripeBilling?.isMerged == true {
            mergedAccountID = identity
            let mapped = try await mergedUsage(usage, planName: plan.name, token: currentToken)
            return await snapshot(mapped, observedAt: usageObservedAt, accessToken: currentToken)
        }
        let planName = plan.name
        let fallback = CursorUsageMapper.shouldUseRequestBasedFallback(
            usage: usage,
            planName: planName,
            planInfoUnavailable: plan.name == nil
        )
        if fallback.shouldFallback {
            let (summary, observedAt) = try await usageSummaryAndRequestResult(
                accessToken: currentToken,
                planName: planName,
                unavailableMessage: fallback.message
            )
            var mapped = summary
            CursorUsageMapper.includeUnresolvedPlanQuota(from: usage, in: &mapped)
            return await snapshot(mapped, observedAt: observedAt, accessToken: currentToken)
        }

        if shouldTryGenericRequestFallback(usage: usage) {
            do {
                var mapped = try await requestBasedResult(
                    accessToken: currentToken,
                    planName: planName,
                    unavailableMessage: "Cursor request-based usage data unavailable. Try again later."
                )
                CursorUsageMapper.includeUnresolvedPlanQuota(from: usage, in: &mapped)
                return await snapshot(mapped, observedAt: now(), accessToken: currentToken)
            } catch {
                noteDegraded(.cursorFallback, error: error, localContext: "optional request-based usage fallback failed")
            }
        }

        let creditGrants = await fetchCreditGrants(accessToken: currentToken)
        let stripeBalanceCents = if let stripeBilling {
            stripeBilling.balanceCents
        } else {
            await fetchStripeBilling(accessToken: currentToken).balanceCents
        }
        let mapped = try CursorUsageMapper.mapUsage(
            usage: usage,
            planName: planName,
            creditGrants: creditGrants,
            stripeBalanceCents: stripeBalanceCents
        )
        return await snapshot(mapped, observedAt: usageObservedAt, accessToken: currentToken)
    }

    /// 이력 실패 시 한도는 유지하고 저장소의 마지막 정상 이력을 경고와 함께 표시.
    private func appendSpendLines(to lines: inout [MetricLine], accessToken: String) async -> ProviderUsageHistory? {
        let sessionID = CursorUsageClient.session(from: accessToken)?.userID
        if historySessionID != sessionID {
            historyRetryAfter = nil
            historySessionID = sessionID
        }
        if let historyRetryAfter, now() < historyRetryAfter {
            noteDegraded(
                .historyScan, category: .http(429), localContext: "usage events retry deferred after rate limit")
            return nil
        }
        let end = now()
        let today = Calendar.current.startOfDay(for: end)
        let start = Calendar.current.date(byAdding: .day, value: -29, to: today) ?? today
        do {
            let events = try await usageClient.fetchUsageEvents(accessToken: accessToken, start: start, end: end)
            let pricing = await pricing()
            historyRetryAfter = nil
            AppDiagnostics.record(.historyScan, result: .success, providerID: provider.id)
            return CursorUsageMapper.appendSpendLines(rows: events, now: end, pricing: pricing, to: &lines)
        } catch CursorHistoryError.http(let status, let retryAfter) {
            if status == 429 { historyRetryAfter = Self.retryDate(retryAfter, receivedAt: now()) }
            noteDegraded(
                .historyScan, category: .http(status), localContext: "usage events request returned HTTP \(status)")
        } catch {
            noteDegraded(
                .historyScan, category: error as? CursorUsageError == .invalidResponse ? .decoding : nil,
                error: error, localContext: "usage events history could not be loaded completely")
        }
        return nil
    }

    static func retryDate(_ value: String?, receivedAt: Date) -> Date {
        if let value, let seconds = Double(value), seconds.isFinite, seconds >= 0 {
            return receivedAt.addingTimeInterval(seconds)
        }
        if let value {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
            if let date = formatter.date(from: value), date > receivedAt { return date }
        }
        return receivedAt.addingTimeInterval(3_600)
    }

    private func fetchUsageWithRetry(
        accessToken: String, authState: inout CursorAuthState
    ) async throws -> (response: HTTPResponse, accessToken: String) {
        var working = authState
        var currentToken = accessToken
        defer { authState = working }
        let response = try await ProviderAuthRetry.fetch(
            provider: "cursor",
            token: accessToken,
            attempt: { try await self.usageClient.fetchUsage(accessToken: $0) },
            refreshAccessToken: {
                guard let refreshed = try await self.refreshAccessToken(authState: working) else {
                    throw CursorAuthError.tokenExpired
                }
                if refreshed.persisted { working.accessToken = refreshed.accessToken }
                currentToken = refreshed.accessToken
                return refreshed.accessToken
            },
            connectionFailed: CursorUsageError.connectionFailed,
            retriedConnectionFailed: CursorUsageError.usageAfterRefreshFailed,
            authExpired: CursorAuthError.tokenExpired
        )
        return (response, currentToken)
    }

    private func refreshAccessToken(authState: CursorAuthState) async throws -> (accessToken: String, persisted: Bool)? {
        refreshedKeychainToken = nil
        guard let refreshToken = authState.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            return nil
        }

        let accessToken: String
        do {
            let response = try await usageClient.refreshToken(refreshToken)
            if response.statusCode == 400 || response.statusCode == 401 {
                let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                if body?["shouldLogout"] as? Bool == true {
                    throw CursorAuthError.sessionExpired
                }
                throw CursorAuthError.tokenExpired
            }
            guard (200..<300).contains(response.statusCode) else {
                AppDiagnostics.record(.credentialRefresh, result: .failure, category: .http(response.statusCode), providerID: provider.id,
                                      localContext: "token refresh request returned HTTP \(response.statusCode)")
                return nil
            }
            let body: [String: Any]
            do {
                guard let object = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                    throw CursorUsageError.invalidResponse
                }
                body = object
            } catch {
                AppDiagnostics.record(.credentialRefresh, result: .failure, category: .decoding, providerID: provider.id, error: error,
                                      localContext: "token refresh response was invalid")
                return nil
            }
            if body["shouldLogout"] as? Bool == true {
                throw CursorAuthError.sessionExpired
            }
            guard let token = (body["access_token"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
                AppDiagnostics.record(.credentialRefresh, result: .failure, category: .decoding, providerID: provider.id,
                                      localContext: "token refresh response contained no usable access token")
                return nil
            }
            accessToken = token
        } catch {
            AppDiagnostics.failure(.credentialRefresh, error: error, providerID: provider.id, localContext: "token refresh request failed")
            throw error
        }
        AppDiagnostics.record(.credentialRefresh, result: .success, providerID: provider.id)
        // 원본과 live token 분리 — Keychain만 같은 source·token 쌍의 다음 조회에서도 메모리 재사용.
        var persisted = false
        do {
            persisted = try await loadOffMainActor { [authStore] in
                try authStore.saveAccessToken(accessToken, replacing: authState)
            }
            if persisted {
                AppDiagnostics.record(.credentialSave, result: .success, providerID: provider.id)
            } else {
                refreshedKeychainToken = (authState, accessToken)
                AppLog.info(LogTag.auth("cursor"), "refreshed Keychain token kept in memory; conditional persistence unavailable")
            }
        } catch CursorAuthError.credentialsChanged {
            AppDiagnostics.failure(.credentialSave, error: CursorAuthError.credentialsChanged, providerID: provider.id,
                                   localContext: "sign-in changed during token refresh; discarding refreshed credentials")
            throw CursorAuthError.credentialsChanged
        } catch {
            noteDegraded(.credentialSave, error: error,
                         localContext: "failed to persist rotated access token to the selected Cursor credential store; using it for this session only")
        }
        return (accessToken, persisted)
    }

    private func fetchPlanInfo(accessToken: String) async -> (name: String?, isMerged: Bool?) {
        guard let body = await fetchOptionalJSONObject(label: "plan", operation: .cursorPlan, request: {
            try await self.usageClient.fetchPlan(accessToken: accessToken)
        }) else {
            return (nil, nil)
        }
        guard let planInfo = body["planInfo"] as? [String: Any],
              let planName = (planInfo["planName"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
        else {
            noteDegraded(.cursorPlan, category: .decoding, localContext: "optional plan response contained invalid plan metadata")
            return (nil, body["isMerged"] as? Bool)
        }
        AppDiagnostics.record(.cursorPlan, result: .success, providerID: provider.id)
        return (planName, body["isMerged"] as? Bool ?? false)
    }

    /// optional endpoint는 사용 가능한 primary snapshot을 보강할 뿐 provider 전체를 실패시키지 않음. boundary 처리를 한곳에 모아 transport·준비·status·schema 실패가 고정된 credential-free 진단으로 노출.
    func fetchOptionalJSONObject(
        label: String,
        operation: DiagnosticOperation,
        request: () async throws -> HTTPResponse?
    ) async -> [String: Any]? {
        let response: HTTPResponse?
        do {
            response = try await request()
        } catch {
            noteDegraded(operation, error: error, localContext: "optional \(label) request failed")
            return nil
        }
        guard let response else {
            noteDegraded(operation, category: .authInvalid, localContext: "optional \(label) request could not be prepared from the current session")
            return nil
        }
        guard (200..<300).contains(response.statusCode) else {
            noteDegraded(operation, category: .http(response.statusCode), localContext: "optional \(label) request returned HTTP \(response.statusCode)")
            return nil
        }
        do {
            guard let body = try JSONSerialization.jsonObject(with: response.body) as? [String: Any] else {
                throw CursorUsageError.invalidResponse
            }
            return body
        } catch {
            noteDegraded(operation, category: .decoding, error: error, localContext: "optional \(label) response was invalid")
            return nil
        }
    }

    private func requestBasedResult(accessToken: String, planName: String?, unavailableMessage: String) async throws -> CursorMappedUsage {
        guard let response = try await usageClient.fetchRequestBasedUsage(accessToken: accessToken) else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }
        guard (200..<300).contains(response.statusCode) else {
            throw CursorUsageError.requestFailed(response.statusCode)
        }
        guard let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any] else {
            throw CursorUsageError.invalidResponse
        }
        let mapped = try CursorUsageMapper.mapRequestBasedUsage(body, planName: planName, unavailableMessage: unavailableMessage)
        AppDiagnostics.record(.cursorFallback, result: .success, providerID: provider.id)
        return mapped
    }

    private func usageSummaryAndRequestResult(
        accessToken: String,
        planName: String?,
        unavailableMessage: String
    ) async throws -> (CursorMappedUsage, Date) {
        let summary = await fetchOptionalJSONObject(label: "usage-summary", operation: .cursorSummary, request: {
            try await self.usageClient.fetchUsageSummary(accessToken: accessToken)
        })
        let summaryObservedAt = summary.flatMap {
            CursorUsageSummaryMapper.hasUsableSummaryPayload($0) ? now() : nil
        }
        if summary != nil, summaryObservedAt == nil {
            noteDegraded(.cursorSummary, category: .decoding, localContext: "optional usage-summary response contained no usable usage fields")
        }
        let requestUsage = await fetchOptionalJSONObject(label: "request-based usage", operation: .cursorFallback, request: {
            try await self.usageClient.fetchRequestBasedUsage(accessToken: accessToken)
        })
        if let requestUsage, !CursorUsageSummaryMapper.hasUsableRequestPayload(requestUsage) {
            noteDegraded(.cursorFallback, category: .decoding, localContext: "optional request-based usage response contained no usable usage fields")
        }
        if summaryObservedAt != nil {
            AppDiagnostics.record(.cursorSummary, result: .success, providerID: provider.id)
        }
        if let requestUsage, CursorUsageSummaryMapper.hasUsableRequestPayload(requestUsage) {
            AppDiagnostics.record(.cursorFallback, result: .success, providerID: provider.id)
        }
        let mapped = try CursorUsageSummaryMapper.map(
            summary: summary,
            requestUsage: requestUsage,
            planName: planName,
            unavailableMessage: unavailableMessage
        )
        // 두 응답을 합친 한도는 먼저 받은 데이터의 시각부터 만료.
        return (mapped, summaryObservedAt ?? now())
    }

    private func shouldTryGenericRequestFallback(usage: [String: Any]) -> Bool {
        CursorPlanUsageFacts(usage: usage).shouldTryGenericRequestFallback
    }

    func noteDegraded(
        _ operation: DiagnosticOperation,
        category: ErrorCategory? = nil,
        error: Error? = nil,
        localContext: String? = nil
    ) {
        refreshIsDegraded = true
        AppDiagnostics.record(operation, result: .degraded, category: category, providerID: provider.id, error: error, localContext: localContext)
    }

    private func snapshot(
        _ mapped: CursorMappedUsage, observedAt: Date, accessToken: String
    ) async -> ProviderSnapshot {
        // 이력 추가 전 진행률 행은 서버가 보낸 구독 또는 추가 지출 한도.
        let hasMeasuredQuota = mapped.lines.contains { line in
            if case .progress = line { return true }
            return false
        }
        var lines = mapped.lines
        let usageHistory = await appendSpendLines(to: &lines, accessToken: accessToken)
        var snapshot = ProviderSnapshot.make(
            provider: provider,
            plan: mapped.plan,
            lines: lines,
            refreshedAt: now(),
            usageHistory: usageHistory,
            warning: usageHistory == nil ? "Cursor usage history could not be refreshed. Try again later." : nil,
            isDegraded: refreshIsDegraded ? true : nil,
            incompleteQuotaWindows: mapped.incompleteQuotaWindows.isEmpty ? nil : mapped.incompleteQuotaWindows,
            liveQuotaObservedAt: hasMeasuredQuota ? observedAt : nil
        )
        snapshot.producedByIdentityKey = CursorUsageClient.session(from: accessToken)?.userID
        snapshot.liveQuotaAccountKey = snapshot.producedByIdentityKey
        snapshot.quotaRecoveryScopes = mapped.recoveryScopes
        return snapshot
    }
}
