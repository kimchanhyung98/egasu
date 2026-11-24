import XCTest
@testable import Egasu

@MainActor
final class UsageTimerQueueInvalidationTests: XCTestCase {
    func testInvalidatedPreparationAndVerificationDoNotReadOrStartAFollowUp() async throws {
        for verifying in [false, true] {
            let suite = "TimerQueue.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let setting = UsageTimerSetting(defaults: defaults)
            let fixture = try UsageTimerRouterTests.Fixture()
            defer { fixture.remove() }
            let provider = UsageTimerRouterRevalidationTests.ProviderStub(observedAt: fixture.clock.current())
            let queue = BackgroundWorkQueue()
            var blocker: BackgroundWorkQueue.Ticket?
            if verifying {
                provider.sendAfterCheck = {
                    Task { blocker = await queue.acquire("hold-verification") }
                    while queue.pendingCount == 0 { await Task.yield() }
                    return .init(launched: true, completed: true)
                }
            } else {
                blocker = await queue.acquire("hold-preparation")
            }
            var followUps: [String] = []
            let router = UsageTimerRouter(
                providers: [provider], isProviderEnabled: { _ in true }, usageTimerSetting: setting,
                executor: fixture.executor(), store: fixture.store, report: { _, _ in },
                refresh: { id, isCurrent in if isCurrent() { followUps.append(id) } },
                now: { fixture.clock.current() }, workQueue: queue)
            router.receive(await provider.refresh(), trigger: .manual)
            let deadline = ContinuousClock.now + .seconds(3)
            while (blocker == nil || queue.pendingCount == 0), ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(queue.pendingCount, 1)
            setting.isEnabled = false
            setting.isEnabled = true
            queue.finish(try XCTUnwrap(blocker))
            await router.waitForPendingWork(providerIDs: [provider.provider.id])
            XCTAssertEqual(provider.prepareCount, verifying ? 1 : 0)
            XCTAssertEqual(provider.verifyCount, 0)
            XCTAssertTrue(followUps.isEmpty)
            if !verifying {
                fixture.clock.advance(.seconds(1))
                provider.observation.observedAt = fixture.clock.current()
                router.receive(await provider.refresh(), trigger: .manual)
                await router.waitForPendingWork(providerIDs: [provider.provider.id])
                XCTAssertEqual(followUps, [provider.provider.id])
            }
            await router.shutdown()
        }
    }

    func testPostTimerRefreshQueuedBeforeInvalidationDoesNotReadOrPublish() async throws {
        let suite = "TimerQueue.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = UsageTimerRouterRevalidationTests.ProviderStub(observedAt: Date())
        let queue = BackgroundWorkQueue()
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, workQueue: queue)
        let ticket = await queue.acquire("hold-follow-up")
        var current = true
        let task = Task { await store.refreshAfterWeeklyTimer(providerID: provider.provider.id) { current } }
        let deadline = ContinuousClock.now + .seconds(3)
        while queue.pendingCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(queue.pendingCount, 1)
        current = false
        queue.finish(try XCTUnwrap(ticket))
        await task.value
        XCTAssertEqual(provider.refreshCount, 0)
        XCTAssertNil(store.snapshots[provider.provider.id])
        await store.refreshAfterWeeklyTimer(providerID: provider.provider.id) { true }
        XCTAssertNotNil(store.snapshots[provider.provider.id])
    }
}
