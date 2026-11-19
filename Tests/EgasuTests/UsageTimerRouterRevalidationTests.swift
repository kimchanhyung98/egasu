import XCTest
@testable import Egasu

@MainActor
final class UsageTimerRouterRevalidationTests: XCTestCase {
    func testInvalidatedBindingNeverEntersSessionSendAfterWaitingForExecutionQueue() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let queue = BackgroundWorkQueue()
        let previousSend = fixture.clock.current().addingTimeInterval(-600)
        let observation = provider.observation
        XCTAssertNotNil(
            try fixture.store.begin(accountKey: observation.storageKey, resetBefore: nil, now: previousSend))
        let blocked = expectation(description: "Execution queue blocked after preparation")
        var ticket: BackgroundWorkQueue.Ticket?
        provider.onPrepare = {
            Task {
                ticket = await queue.acquire("unrelated-work")
                blocked.fulfill()
            }
            while queue.pendingCount == 0 { await Task.yield() }
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true },
            executor: fixture.executor(), store: fixture.store,
            report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() }, workQueue: queue
        )
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [blocked], timeout: 3)
        while queue.pendingCount == 0 { await Task.yield() }

        router.reconfigure(providers: [])
        queue.finish(try XCTUnwrap(ticket))
        await router.waitForPendingWork(providerIDs: [provider.provider.id])

        XCTAssertEqual(provider.sendCount, 0)
        let restarted = UsageTimerAttemptStore(fileURL: fixture.store.fileURL)
        XCTAssertEqual(
            try restarted.sendLimitResetsAt(
                accountKey: observation.storageKey, now: fixture.clock.current(),
                budgetWindow: observation.budgetWindow),
            previousSend.addingTimeInterval(observation.budgetWindow))
        XCTAssertFalse(router.hasPendingWork)
        await router.shutdown()
    }

    func testUnrelatedAccountCatalogRebuildKeepsPendingNonAccountTimerBinding() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        let replacement = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        let queue = BackgroundWorkQueue()
        let blocked = expectation(description: "Prepared timer is queued")
        var ticket: BackgroundWorkQueue.Ticket?
        provider.onPrepare = {
            Task { ticket = await queue.acquire("unrelated-work"); blocked.fulfill() }
            while queue.pendingCount == 0 { await Task.yield() }
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, executor: fixture.executor(), store: fixture.store,
            report: { _, _ in }, refresh: { _, _ in }, now: { fixture.clock.current() }, workQueue: queue)
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [blocked], timeout: 3)
        while queue.pendingCount == 0 { await Task.yield() }

        router.reconfigure(providers: [replacement])
        queue.finish(try XCTUnwrap(ticket))
        await router.waitForPendingWork(providerIDs: ["zai"])

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertEqual(replacement.sendCount, 0)
        await router.shutdown()
    }

    func testTimerAcceptsTheVerifiedTimestampFromTheSnapshot() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let time = fixture.clock.current()
        let provider = ProviderStub(observedAt: time, providerID: "antigravity")
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, executor: fixture.executor(),
            store: fixture.store, report: { _, _ in }, refresh: { _, _ in }, now: { fixture.clock.current() })
        var snapshot = await provider.refresh()
        snapshot.liveQuotaObservedAt = time.addingTimeInterval(-60)
        snapshot.usageTimerObservedAt = time.addingTimeInterval(-30)

        router.receive(snapshot, trigger: .manual)
        await router.waitForPendingWork(providerIDs: [provider.provider.id])
        XCTAssertEqual(provider.sendCount, 0)

        snapshot.usageTimerObservedAt = time
        router.receive(snapshot, trigger: .manual)
        await router.waitForPendingWork(providerIDs: [provider.provider.id])
        XCTAssertEqual(provider.sendCount, 1)
        await router.shutdown()
    }

    func testStateReadFailurePreservesExistingTimerWarningAndRecoveryClearsOnlyStateWarning() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let finished = expectation(description: "Timer failure reported")
        var warnings: [String]?
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true },
            executor: fixture.executor(), store: fixture.store,
            report: { _, messages in warnings = messages }, refresh: { _, _ in finished.fulfill() },
            now: { fixture.clock.current() }
        )
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(warnings, [ProviderStub.sendFailure])
        let saved = try Data(contentsOf: fixture.store.fileURL)

        try Data("invalid-state".utf8).write(to: fixture.store.fileURL)
        fixture.clock.advance(.seconds(1))
        provider.observation.observedAt = fixture.clock.current()
        router.receive(await provider.refresh(), trigger: .manual)
        XCTAssertEqual(
            Set(warnings ?? []),
            [
                ProviderStub.sendFailure,
                "Usage timer automation could not read its saved state. No message was sent."
            ])

        try saved.write(to: fixture.store.fileURL)
        fixture.clock.advance(.seconds(1))
        provider.observation.observedAt = fixture.clock.current()
        router.receive(await provider.refresh(), trigger: .manual)
        XCTAssertEqual(warnings, [ProviderStub.sendFailure])
        XCTAssertEqual(provider.sendCount, 1)
        await router.shutdown()
    }

    func testCodexStartupWarningUsesProviderTypeAfterBindingInvalidation() throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "custom-codex-card")
        let executor = fixture.executor()
        executor.startupFailureDescription = "Temporary credentials could not be removed."
        var warning: [String]?
        let router = UsageTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store,
            report: { _, messages in warning = messages }, refresh: { _, _ in }
        )

        router.invalidate(providerIDs: [account.provider.provider.id])

        XCTAssertEqual(warning, [try XCTUnwrap(executor.startupFailureDescription)])
        XCTAssertTrue(executor.auths.isEmpty)
    }

    private final class ProviderStub: UsageTimerProviding {
        static let sendFailure = "Usage timer message could not be prepared. Refresh to try again."
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        var observation: UsageTimerObservation
        var onPrepare: (() async -> Void)?
        private(set) var sendCount = 0
        var usageTimerObservations: [UsageTimerObservation] { [observation] }

        init(observedAt: Date, providerID: String = "codex") {
            provider = CodexProvider.makeProvider(id: providerID)
            observation = .init(
                accountKey: "account", usedPercent: 0, resetsAt: nil, observedAt: observedAt,
                timerID: "test.session", duration: 18_000, startRule: .missingReset
            )
        }

        func refresh() async -> ProviderSnapshot {
            .init(
                providerID: provider.id, displayName: provider.displayName, lines: [],
                liveQuotaObservedAt: observation.observedAt)
        }

        func hasLocalCredentials() async -> Bool { false }

        func prepareUsageTimer(
            _ observation: UsageTimerObservation, executors: UsageTimerExecutors
        ) async throws -> UsageTimerSession? {
            await onPrepare?()
            return UsageTimerSession(
                observation: observation,
                send: { [self] _ in
                    sendCount += 1
                    return .init(launched: false, completed: false, failureDescription: Self.sendFailure)
                },
                verify: { nil }
            )
        }
    }
}
