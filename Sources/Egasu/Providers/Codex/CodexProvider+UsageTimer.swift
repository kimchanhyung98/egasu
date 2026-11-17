import Foundation

extension CodexProvider: UsageTimerProviding {
    func prepareUsageTimer(
        _ observation: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let session = try await prepareWeeklyTimerSession(
            expectedAccountKey: observation.accountKey, timerID: observation.timerID
        )
        let pool = observation.timerID.split(separator: ".").dropLast().joined(separator: ".")
        guard !usageTimerObservations.contains(where: { $0.timerID.hasPrefix(pool + ".") && $0.usedPercent >= 100 }) else { return nil }
        let model = observation.timerID.hasPrefix("codex.spark.") ? "gpt-5.3-codex-spark" : nil
        return UsageTimerSession(
            observation: session.observation,
            send: { [self] canLaunch in
                var result = await executors.codex.execute(auth: session.authState.auth, model: model) {
                    guard await canLaunch() else { return false }
                    do { try await self.validateWeeklyTimerSession(session) }
                    catch {
                        AppDiagnostics.failure(.weeklyTimer, error: error, providerID: self.provider.id)
                        return false
                    }
                    return await canLaunch()
                }
                if let updated = result.updatedAuth {
                    do {
                        let save = Task { try await self.persistUpdatedWeeklyTimerAuth(updated, original: session.authState) }
                        try await save.value
                    } catch {
                        AppDiagnostics.failure(.weeklyTimer, error: error, providerID: self.provider.id)
                        result.failureDescription = "Usage timer credentials changed. Refresh this account before trying again."
                        result.verificationCanClearFailure = false
                    }
                }
                return UsageTimerExecutionResult(
                    launched: result.launched, completed: result.completed,
                    failureDescription: result.failureDescription,
                    verificationCanClearFailure: result.verificationCanClearFailure
                )
            },
            verify: { [self] in
                try await prepareWeeklyTimerSession(expectedAccountKey: observation.accountKey,
                                                    timerID: observation.timerID).observation
            }
        )
    }
}
