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
        return UsageTimerSession(
            observation: observation,
            send: { canLaunch in
                await executors.cli.execute(.claude(accessToken: accessToken)) {
                    guard await canLaunch() else { return false }
                    do {
                        let current = try await Self.validateTimerLogin(cliStore, credentials: credentials)
                        guard current.oauth.accessToken == accessToken else { return false }
                    } catch {
                        AppDiagnostics.failure(
                            .weeklyTimer, error: error, localContext: "Claude timer credential validation failed")
                        return false
                    }
                    return await canLaunch()
                }
            },
            verify: { [self] in
                let snapshot = await refresh()
                return usageTimerObservations.first {
                    $0.accountKey == expected.accountKey && snapshot.liveQuotaObservedAt == $0.observedAt
                }
            }
        )
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
