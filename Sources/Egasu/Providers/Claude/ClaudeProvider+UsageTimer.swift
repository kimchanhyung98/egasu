import Foundation

extension ClaudeProvider: UsageTimerProviding {
    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let snapshot = await refresh()
        if usageTimerCredentialState?.oauth.hasOnlyProfileScope == true { return nil }
        guard let observation = usageTimerObservations.first,
            snapshot.liveQuotaObservedAt == observation.observedAt,
            observation.accountKey == expected.accountKey,
            let credentials = usageTimerCredentialState
        else { throw UsageTimerError.usageUnavailable }
        let cliStore = authStore
        guard try cliStore.oauthConfig().usageURL.absoluteString == "https://api.anthropic.com/api/oauth/usage" else {
            throw UsageTimerError.currentLoginRequired
        }
        guard let accessToken = try await Self.timerAccessToken(cliStore, credentials: credentials) else { return nil }
        return executors.cli.session(
            observation: observation, configuration: .claude(accessToken: accessToken), now: now,
            validateLogin: {
                guard let current = try await Self.timerAccessToken(cliStore, credentials: credentials) else {
                    throw UsageTimerError.noLongerEligible
                }
                return current == accessToken
            },
            readQuota: { [self] in
                let snapshot = await refresh()
                guard let observedAt = snapshot.liveQuotaObservedAt else { throw UsageTimerError.usageUnavailable }
                return usageTimerObservations.first {
                    $0.accountKey == expected.accountKey && $0.observedAt == observedAt
                }
            })
    }

    private static func timerAccessToken(_ store: ClaudeAuthStore, credentials: ClaudeCredentialState) async throws
        -> String?
    {
        let load = await loadOffMainActor { store.loadCredentialSet() }
        if let error = load.credentialError { throw error }
        guard
            let current = load.candidates.first(where: {
                $0.hasUsableAccessToken && $0.source != .desktop && $0.source != .environment
                    && $0.source == credentials.source
            })
        else { throw UsageTimerError.currentLoginRequired }
        let sameToken = current.oauth.accessToken == credentials.oauth.accessToken
        let sameAccountAndOrganization =
            current.accountIdentityKey?.contains("|") == true
            && current.accountIdentityKey == credentials.accountIdentityKey
        if current.oauth.hasOnlyProfileScope, sameToken || sameAccountAndOrganization { return nil }
        guard sameToken else { throw UsageTimerError.currentLoginRequired }
        return current.oauth.accessToken
    }
}
