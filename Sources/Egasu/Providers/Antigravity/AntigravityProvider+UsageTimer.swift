import Foundation

extension AntigravityProvider: UsageTimerProviding {
    func recordUsageTimer(lines: [MetricLine], credentials: AntigravityKeychainToken) {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else { return }
        let key = UsageTimerObservation.accountKey(family: "antigravity", identity: refreshToken)
        let observedAt = now()
        usageTimerCredential = credentials
        usageTimerObservations = [
            ("gemini", AntigravityMetric.sessionLabel, AntigravityMetric.weeklyLabel),
            ("other", AntigravityMetric.claudeLabel, AntigravityMetric.claudeWeeklyLabel)
        ].flatMap { pool, session, weekly -> [UsageTimerObservation] in
            let poolLines = lines.filter { $0.label == session || $0.label == weekly }
            guard !UsageTimerObservation.hasExhaustedQuota(poolLines) else { return [] }
            return [(weekly, "weekly", 604_800.0), (session, "session", 18_000.0)].compactMap {
                label, period, duration in
                UsageTimerObservation.from(
                    lines: poolLines, label: label, accountKey: key,
                    timerID: "antigravity.\(pool).\(period)", duration: duration, observedAt: observedAt)
            }
        }
    }

    private func timerQuota(_ expected: UsageTimerObservation) async throws -> UsageTimerObservation? {
        usageTimerObservations = []
        _ = try await probeCloudCode()
        return usageTimerObservations.first { $0.storageKey == expected.storageKey }
    }

    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        guard let observation = try await timerQuota(expected) else { throw UsageTimerError.usageUnavailable }
        guard let credentials = usageTimerCredential else { throw UsageTimerError.currentLoginRequired }
        let modelPrefix = expected.timerID.hasPrefix("antigravity.gemini.") ? "gemini-" : "claude-"
        return executors.cli.session(
            observation: observation, configuration: .antigravity(model: modelPrefix), now: now,
            validateLogin: { [authStore] in
                let current = try await loadOffMainActor { try authStore.loadKeychainToken() }
                return current?.refreshToken == credentials.refreshToken
            },
            readQuota: { [self] in try await timerQuota(expected) })
    }
}
