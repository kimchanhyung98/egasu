import Foundation

extension ZAIProvider: UsageTimerProviding {
    func recordUsageTimer(lines: [MetricLine], apiKey: String, observedAt: Date) {
        usageTimerObservations =
            UsageTimerObservation.hasExhaustedQuota(lines)
            ? []
            : [
                UsageTimerObservation.from(
                    lines: lines, accountKey: UsageTimerObservation.accountKey(family: "zai", identity: apiKey),
                    timerID: "zai.session", observedAt: observedAt
                )
            ].compactMap { $0 }
    }

    private func timerQuota(expected: UsageTimerObservation) async throws -> (UsageTimerObservation, String) {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }),
            UsageTimerObservation.accountKey(family: "zai", identity: auth.apiKey) == expected.accountKey
        else { throw UsageTimerError.accountChanged }
        let response = try await usageClient.fetchQuota(apiKey: auth.apiKey)
        guard (200..<300).contains(response.statusCode) else { throw ZAIUsageError.requestFailed(response.statusCode) }
        let lines = try ZAIUsageMapper.mapQuota(response.body)
        recordUsageTimer(lines: lines, apiKey: auth.apiKey, observedAt: now())
        guard let observation = usageTimerObservations.first else { throw UsageTimerError.usageUnavailable }
        return (observation, auth.apiKey)
    }

    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let (observation, apiKey) = try await timerQuota(expected: expected)
        return UsageTimerSession(
            observation: observation,
            send: { [authStore] canLaunch in
                await executors.cli.execute(.zai(apiKey: apiKey)) {
                    guard await canLaunch(),
                        let auth = await loadOffMainActor({ authStore.loadAPIKey() }), auth.apiKey == apiKey
                    else { return false }
                    return await canLaunch()
                }
            },
            verify: { [self] in try await timerQuota(expected: expected).0 }
        )
    }
}
