import Foundation

extension KimiProvider: UsageTimerProviding {
    func prepareUsageTimer(
        _ expected: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession? {
        let reading = await readQuota()
        guard let observation = reading.observation,
            observation.accountKey == expected.accountKey,
            let document = reading.credential,
            let token = document.credentials.accessToken,
            Self.hasTimerLifetime(document, at: now())
        else { throw UsageTimerError.usageUnavailable }
        return executors.cli.session(
            observation: observation,
            configuration: .kimi(
                accessToken: token, baseURL: document.service.usageURL.deletingLastPathComponent().absoluteString),
            now: now,
            validateLogin: { [authStore, now] in
                guard let current = try await loadOffMainActor({ try authStore.loadCredentialDocument() }) else {
                    return false
                }
                return current == document && Self.hasTimerLifetime(current, at: now())
            },
            readQuota: { [self] in
                let reading = await readQuota()
                guard reading.snapshot.liveQuotaObservedAt != nil else { throw UsageTimerError.usageUnavailable }
                guard let observation = reading.observation else { return nil }
                guard observation.accountKey == expected.accountKey else { throw UsageTimerError.accountChanged }
                return observation
            })
    }

    private static func hasTimerLifetime(_ document: KimiCredentialDocument, at now: Date) -> Bool {
        guard let expiry = document.credentials.expiresAt, expiry.timeIntervalSince1970 != 0 else { return true }
        return expiry.timeIntervalSince(now) > 120
    }
}
