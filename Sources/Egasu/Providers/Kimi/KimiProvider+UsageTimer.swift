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
            Self.hasTimerLifetime(document, at: now())
        else { throw UsageTimerError.usageUnavailable }
        return UsageTimerSession(
            observation: observation,
            send: { [authStore, now] canLaunch in
                await executors.cli.execute(
                    .kimi(
                        accessToken: token,
                        baseURL: document.service.usageURL.deletingLastPathComponent().absoluteString
                    )
                ) {
                    guard await canLaunch() else { return false }
                    do {
                        let current = try await loadOffMainActor { try authStore.loadCredentialDocument() }
                        guard let current, current == document, Self.hasTimerLifetime(current, at: now()) else {
                            return false
                        }
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

    private static func hasTimerLifetime(_ document: KimiCredentialDocument, at now: Date) -> Bool {
        guard let expiry = document.credentials.expiresAt, expiry.timeIntervalSince1970 != 0 else { return true }
        return expiry.timeIntervalSince(now) > 120
    }
}
