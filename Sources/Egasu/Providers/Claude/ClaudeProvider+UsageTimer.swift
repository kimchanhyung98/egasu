import Foundation

extension ClaudeProvider: UsageTimerProviding {
    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let snapshot = await refresh()
        guard let observation = usageTimerObservations.first,
            snapshot.liveQuotaObservedAt == observation.observedAt,
            observation.accountKey == expected.accountKey,
            let credentials = usageTimerCredentialState
        else { throw UsageTimerError.usageUnavailable }
        let cliStore = authStore
        guard try cliStore.oauthConfig().usageURL.absoluteString == "https://api.anthropic.com/api/oauth/usage" else {
            throw UsageTimerError.currentLoginRequired
        }
        let current = try await Self.validateTimerLogin(cliStore, credentials: credentials)
        guard let accessToken = current.oauth.accessToken else { throw UsageTimerError.currentLoginRequired }
        return executors.cli.session(
            observation: observation, configuration: .claude(accessToken: accessToken), now: now,
            validateLogin: {
                let current = try await Self.validateTimerLogin(cliStore, credentials: credentials)
                return current.oauth.accessToken == accessToken
            },
            readQuota: { [self] in
                let snapshot = await refresh()
                guard let observedAt = snapshot.liveQuotaObservedAt else { throw UsageTimerError.usageUnavailable }
                return usageTimerObservations.first {
                    $0.accountKey == expected.accountKey && $0.observedAt == observedAt
                }
            })
    }

    private static func validateTimerLogin(_ store: ClaudeAuthStore, credentials: ClaudeCredentialState) async throws
        -> ClaudeCredentialState
    {
        let load = await loadOffMainActor { store.loadCredentialSet() }
        if let error = load.credentialError { throw error }
        guard
            let current = load.candidates.first(where: {
                $0.hasUsableAccessToken && $0.source != .desktop && $0.source != .environment
                    && $0.source == credentials.source && $0.oauth.accessToken == credentials.oauth.accessToken
            })
        else { throw UsageTimerError.currentLoginRequired }
        return current
    }
}
