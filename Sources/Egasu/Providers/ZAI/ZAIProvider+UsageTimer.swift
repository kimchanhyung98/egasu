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

    private func timerQuota(expected: UsageTimerObservation) async throws -> (UsageTimerObservation?, String) {
        guard let auth = await loadOffMainActor({ [authStore] in authStore.loadAPIKey() }),
            UsageTimerObservation.accountKey(family: "zai", identity: auth.apiKey) == expected.accountKey
        else { throw UsageTimerError.accountChanged }
        let response = try await usageClient.fetchQuota(apiKey: auth.apiKey)
        guard (200..<300).contains(response.statusCode) else { throw ZAIUsageError.requestFailed(response.statusCode) }
        let lines = try ZAIUsageMapper.mapQuota(response.body)
        recordUsageTimer(lines: lines, apiKey: auth.apiKey, observedAt: now())
        return (usageTimerObservations.first, auth.apiKey)
    }

    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let (observation, apiKey) = try await timerQuota(expected: expected)
        guard let observation else { throw UsageTimerError.usageUnavailable }
        return executors.cli.session(
            observation: observation, configuration: .zai(apiKey: apiKey), now: now,
            validateLogin: { [authStore] in
                await loadOffMainActor { authStore.loadAPIKey()?.apiKey == apiKey }
            },
            readQuota: { [self] in try await timerQuota(expected: expected).0 })
    }
}
