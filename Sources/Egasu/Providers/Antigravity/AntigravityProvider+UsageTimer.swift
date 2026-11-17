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

    private func timerQuota(_ expected: UsageTimerObservation) async throws -> UsageTimerObservation {
        usageTimerObservations = []
        _ = try await probeCloudCode()
        guard
            let observation = usageTimerObservations.first(where: {
                $0.accountKey == expected.accountKey && $0.timerID == expected.timerID
            })
        else { throw UsageTimerError.usageUnavailable }
        return observation
    }

    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let observation = try await timerQuota(expected)
        guard let credentials = usageTimerCredential else { throw UsageTimerError.currentLoginRequired }
        let modelPrefix = expected.timerID.hasPrefix("antigravity.gemini.") ? "gemini-" : "claude-"
        return UsageTimerSession(
            observation: observation,
            send: { [authStore] canLaunch in
                await executors.cli.execute(.antigravity(model: modelPrefix)) {
                    guard await canLaunch() else { return false }
                    do {
                        let current = try await loadOffMainActor { try authStore.loadKeychainToken() }
                        guard current?.refreshToken == credentials.refreshToken else { return false }
                    } catch { return false }
                    return await canLaunch()
                }
            },
            verify: { [self] in try await timerQuota(expected) }
        )
    }
}
