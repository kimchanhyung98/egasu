import Observation
import os
import XCTest
@testable import Egasu

@MainActor
final class WidgetDataStorePipelineTests: XCTestCase {
    func testPublicRefreshStateRemainsObservable() async {
        let fixture = makeFixture()
        let store = fixture.store
        let refreshing = observe { _ = store.refreshingProviderIDs }
        let local = observe { _ = store.localSnapshots }
        let rendered = observe { _ = store.snapshots }
        let result = observe { _ = store.refreshResults }
        let schedule = observe { _ = store.scheduledRefreshDates }

        let outcome = await store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .refreshed)
        for changed in [refreshing, local, rendered, result, schedule] {
            XCTAssertTrue(changed.withLock { $0 })
        }
        XCTAssertTrue(store.refreshingProviderIDs.isEmpty)
        XCTAssertEqual(store.snapshots, store.localSnapshots)
        XCTAssertEqual(store.scheduledRefreshDate(for: "codex"), fixture.date.addingTimeInterval(300))
    }

    func testFailureChangesNoticeWithoutRepublishingUnchangedUsage() async {
        let fixture = makeFixture()
        await fixture.store.refresh(providerID: "codex", force: true)
        let snapshot = fixture.store.snapshots["codex"]
        let rendered = observe { _ = fixture.store.snapshots }
        let notice = observe { _ = fixture.store.headerNotice(for: "codex") }
        fixture.runtime.snapshot = .error(
            provider: fixture.runtime.provider, message: "Fixture failure", category: .network)

        let outcome = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(notice.withLock { $0 })
        XCTAssertFalse(rendered.withLock { $0 })
        XCTAssertEqual(fixture.store.snapshots["codex"], snapshot)
        XCTAssertEqual(fixture.store.headerNotice(for: "codex"), "Fixture failure")
    }

    func testPeerUnionStaysOutOfCacheExportAndFreshQuotaCallbacksAfterPartialFailure() async throws {
        let fixture = makeFixture()
        let store = fixture.store
        var fresh: [ProviderSnapshot] = []
        store.onFreshSnapshot = { snapshot, _, _ in fresh.append(snapshot) }
        await store.refresh(providerID: "codex", force: true)
        store.setPeerHistoryDocuments(
            [
                UsageHistoryDocument(
                    deviceID: "peer", deviceName: "Peer Mac", updatedAt: fixture.date,
                    providers: ["codex": history(tokens: 50, date: fixture.date)],
                    identities: ["codex": "account-A"])
            ], ownDeviceID: "local")
        XCTAssertEqual(tokens(in: store.snapshots["codex"]), 150)

        fixture.runtime.snapshot.usageHistory = history(tokens: 200, date: fixture.date)
        await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(tokens(in: store.snapshots["codex"]), 250)
        XCTAssertEqual(tokens(in: fresh.last), 200)

        var failure = ProviderSnapshot.error(
            provider: fixture.runtime.provider, message: "Quota unavailable", category: .network)
        failure.refreshedAt = fixture.date.addingTimeInterval(60)
        failure.usageHistory = history(tokens: 300, date: fixture.date)
        fixture.runtime.snapshot = failure
        let outcome = await store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(fresh.count, 2)
        XCTAssertEqual(tokens(in: store.snapshots["codex"]), 350)
        XCTAssertEqual(tokens(in: store.localSnapshots["codex"]), 300)
        let cached = try XCTUnwrap(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"])
        XCTAssertEqual(tokens(in: cached), 300)
        XCTAssertEqual(cached.refreshedAt, fixture.date)
        XCTAssertNil(cached.liveQuotaObservedAt)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-A")
        let exported = store.localHistoryDocument(deviceID: "local", deviceName: "Local Mac")
        XCTAssertEqual(exported.providers["codex"]?.series.daily.first?.totalTokens, 300)
        store.clearPeerHistoryDocuments()
        XCTAssertEqual(tokens(in: store.snapshots["codex"]), 300)
    }

    func testHistoryMissKeepsReportedValuesButCannotFillMissingPeriods() async throws {
        let fixture = makeFixture()
        let store = fixture.store
        let periods = WidgetDescriptor.spendTiles(provider: fixture.runtime.provider)
        let yesterday = try XCTUnwrap(periods.first { $0.id == "codex.yesterday" })
        await store.refresh(providerID: "codex", force: true)
        XCTAssertTrue(store.data(for: yesterday).isZeroUsage)

        fixture.runtime.snapshot.usageHistory = nil
        await store.refresh(providerID: "codex", force: true)

        let retained = try XCTUnwrap(store.snapshots["codex"])
        XCTAssertNil(retained.warning)
        XCTAssertEqual(retained.isDegraded, true)
        XCTAssertEqual(tokens(in: retained), 100)
        XCTAssertFalse(store.data(for: yesterday).hasData)
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["codex"])["codex"]?.isDegraded, true)

        fixture.runtime.snapshot.usageHistory = ProviderUsageHistory(series: .init(daily: []))
        await store.refresh(providerID: "codex", force: true)

        XCTAssertNil(store.snapshots["codex"]?.isDegraded)
        XCTAssertTrue(store.data(for: yesterday).isZeroUsage)
    }

    func testCatalogReplacementWhileQueuedReleasesOldWorkWithoutCallingOldRuntime() async throws {
        let fixture = makeFixture()
        let acquired = await fixture.queue.acquire("test:block-refresh")
        let ticket = try XCTUnwrap(acquired)
        defer { fixture.queue.finish(ticket) }
        let oldRefresh = Task { await fixture.store.refresh(providerID: "codex", force: true) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.queue.pendingCount == 0, ContinuousClock.now < deadline { await Task.yield() }
        guard fixture.queue.pendingCount == 1 else {
            oldRefresh.cancel()
            fixture.queue.finish(ticket)
            _ = await oldRefresh.value
            return XCTFail("Refresh did not enter the queue")
        }
        let replacement = Runtime(date: fixture.date)
        replacement.snapshot.plan = "New account"
        fixture.store.replaceProviderCatalog(
            registry: .from([replacement]), providers: [replacement],
            identityKeys: ["codex": "account-B"])
        fixture.queue.finish(ticket)
        let discarded = await oldRefresh.value
        let accepted = await fixture.store.refresh(providerID: "codex", force: true)

        XCTAssertEqual(discarded, .skipped)
        XCTAssertEqual(fixture.runtime.calls, 0)
        XCTAssertEqual(accepted, .refreshed)
        XCTAssertEqual(replacement.calls, 1)
        XCTAssertEqual(fixture.store.plan(for: "codex"), "New account")
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "codex"), "account-B")
        XCTAssertTrue(fixture.store.refreshingProviderIDs.isEmpty)
    }

    private func observe(_ read: () -> Void) -> OSAllocatedUnfairLock<Bool> {
        let changed = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking(read) {
            changed.withLock { $0 = true }
        }
        return changed
    }

    private func makeFixture() -> Fixture {
        let suite = "EgasuTests.RefreshPipeline.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let runtime = Runtime(date: date)
        runtime.snapshot.usageHistory = history(tokens: 100, date: date)
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { date })
        let queue = BackgroundWorkQueue()
        let store = WidgetDataStore(registry: .from([runtime]), providers: [runtime], cache: cache,
            defaults: defaults, now: { date }, providerIdentityKeys: ["codex": "account-A"],
            workQueue: queue)
        return Fixture(store: store, runtime: runtime, cache: cache, queue: queue, date: date)
    }

    private func history(tokens: Int, date: Date) -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: date), totalTokens: tokens, costUSD: 1)
            ]))
    }

    private func tokens(in snapshot: ProviderSnapshot?) -> Double? {
        guard case .values(_, let values, _, _, _, _) = snapshot?.line(label: "Today") else { return nil }
        return values.first { $0.kind == .count }?.number
    }

    private struct Fixture {
        let store: WidgetDataStore
        let runtime: Runtime
        let cache: ProviderSnapshotCache
        let queue: BackgroundWorkQueue
        let date: Date
    }

    private final class Runtime: ProviderRuntime {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var widgetDescriptors: [WidgetDescriptor] {
            [
                .percent(id: "codex.session", provider: provider, title: "Session")
                    .exportingHistory(scope: .machineLocal, estimatedCost: false, sourceNote: "Fixture history")
            ]
        }
        var snapshot: ProviderSnapshot
        var calls = 0

        init(date: Date) {
            snapshot = .make(
                provider: provider, plan: "Pro",
                lines: [.progress(label: "Session", used: 25, limit: 100, format: .percent)],
                refreshedAt: date, liveQuotaObservedAt: date)
        }

        func refresh() async -> ProviderSnapshot {
            calls += 1
            var result = snapshot
            if result.errorCategory == nil, let tokens = result.usageHistory?.series.daily.first?.totalTokens {
                result.lines.append(
                    .values(label: "Today", values: [.init(number: Double(tokens), kind: .count, label: "tokens")]))
            }
            return result
        }
    }
}
