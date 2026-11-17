import Foundation

extension KimiProvider: UsageTimerProviding {
    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        _ = await quotaSnapshot()
        guard let observation = usageTimerObservations.first,
            observation.accountKey == expected.accountKey,
            let document = usageTimerCredential,
            let token = document.credentials.accessToken,
            document.credentials.expiresAt.map({ $0.timeIntervalSince(now()) > 120 }) ?? false
        else { throw UsageTimerError.usageUnavailable }
        return UsageTimerSession(
            observation: observation,
            send: { [authStore] canLaunch in
                await executors.cli.execute(
                    .kimi(
                        accessToken: token,
                        baseURL: document.service.usageURL.deletingLastPathComponent().absoluteString
                    )
                ) {
                    guard await canLaunch() else { return false }
                    do {
                        let current = try await loadOffMainActor { try authStore.loadCredentialDocument() }
                        guard current == document else { return false }
                    } catch { return false }
                    return await canLaunch()
                }
            },
            verify: { [self] in
                _ = await quotaSnapshot()
                return usageTimerObservations.first { $0.accountKey == expected.accountKey }
            }
        )
    }
}
