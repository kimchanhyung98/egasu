import XCTest
@testable import Egasu

@MainActor
final class WidgetDataStoreHistoryFailureTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testFailedBatchesNotifyOnlyWhenLocalHistoryChanges() async throws {
        let fixture = makeFixture()
        var exported: [ProviderUsageHistory] = []
        fixture.store.onLocalHistoryChanged = { [weak store = fixture.store] in
            if let history = store?.localHistoryDocument(deviceID: "local", deviceName: "Local Mac")
                .providers["copilot"] {
                exported.append(history)
            }
        }
        let updated = history(tokens: 200)
        fixture.runtime.snapshot = failure(provider: fixture.runtime.provider, history: updated)

        await fixture.store.refreshAll(force: true)

        XCTAssertEqual(exported, [updated])
        XCTAssertNotNil(fixture.store.providerErrors["copilot"])
        XCTAssertEqual(fixture.store.localSnapshots["copilot"]?.line(label: "Credits"),
                       fixture.previous.line(label: "Credits"))

        await fixture.store.refreshAll(force: true)
        XCTAssertEqual(exported, [updated])

        let empty = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        fixture.runtime.snapshot = failure(provider: fixture.runtime.provider, history: empty)
        await fixture.store.refreshAll(force: true)
        XCTAssertEqual(exported, [updated, empty])

        fixture.runtime.snapshot = failure(provider: fixture.runtime.provider, history: nil)
        await fixture.store.refreshAll(force: true)
        XCTAssertEqual(exported, [updated, empty])
    }

    func testFailedHistoryRefreshDoesNotOverwriteAnotherIdentitysCache() async throws {
        let fixture = makeFixture(providerID: "codex@fixture", currentIdentity: "current", cachedIdentity: "previous")
        let id = fixture.runtime.provider.id
        XCTAssertNil(fixture.store.localSnapshots[id])
        let currentHistory = history(tokens: 200)
        fixture.runtime.snapshot = failure(provider: fixture.runtime.provider, history: currentHistory)

        for _ in 0..<2 {
            await fixture.store.refreshAll(force: true)

            XCTAssertEqual(fixture.store.localSnapshots[id]?.usageHistory, currentHistory)
            XCTAssertNil(fixture.store.localSnapshots[id]?.line(label: "Credits"))
            XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: [id])[id], fixture.previous)
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: id), "previous")
        }
    }

    func testQuotaFailureRevokesFreshnessAcrossCacheInstancesWithoutLosingDisplayedUsage() async throws {
        let fixture = makeFixture(providerID: "codex", currentIdentity: "current", cachedIdentity: "current")
        let id = fixture.runtime.provider.id
        let earlierReader = ProviderSnapshotCache(
            userDefaults: fixture.defaults, storageKey: "snapshots", allowsPersistedFreshness: true,
            now: { [now] in now }
        )
        XCTAssertEqual(earlierReader.snapshot(providerID: id)?.liveQuotaObservedAt, now)
        fixture.runtime.snapshot = failure(provider: fixture.runtime.provider, history: nil)
        await fixture.store.refreshAll(force: true)

        var retained = fixture.previous
        retained.liveQuotaObservedAt = nil
        XCTAssertEqual(earlierReader.snapshot(providerID: id), retained)
        XCTAssertEqual(earlierReader.producedByIdentityKey(providerID: id), "current")
        earlierReader.store(fixture.previous, producedByIdentityKey: "current")
        let newReader = ProviderSnapshotCache(
            userDefaults: fixture.defaults, storageKey: "snapshots", allowsPersistedFreshness: true,
            now: { [now] in now }
        )
        XCTAssertEqual(newReader.loadSnapshots(providerIDs: [id])[id], fixture.previous)
        XCTAssertEqual(newReader.snapshot(providerID: id), retained)

        var fresh = fixture.previous
        fresh.liveQuotaObservedAt = now.addingTimeInterval(0.25)
        fixture.runtime.snapshot = fresh
        await fixture.store.refreshAll(force: true)
        XCTAssertEqual(fixture.cache.snapshot(providerID: id)?.liveQuotaObservedAt, fresh.liveQuotaObservedAt)
        let afterRecovery = ProviderSnapshotCache(userDefaults: fixture.defaults, storageKey: "snapshots")
        XCTAssertEqual(
            afterRecovery.loadSnapshots(providerIDs: [id])[id]?.liveQuotaObservedAt, fresh.liveQuotaObservedAt)
    }

    func testFailureNoticeUsesCurrentWarningsWithoutRepeatingOrIncludingStaleWarnings() async throws {
        let fixture = makeFixture()
        fixture.runtime.snapshot.warning = "Stale warning"
        await fixture.store.refreshAll(force: true)
        var failed = failure(provider: fixture.runtime.provider, history: nil)
        failed.warning = "Current history warning"
        fixture.runtime.snapshot = failed

        await fixture.store.refreshAll(force: true)

        XCTAssertEqual(fixture.store.warningMessage(for: "copilot"), "Stale warning")
        XCTAssertEqual(fixture.store.headerNotice(for: "copilot"), "Fixture quota failure Current history warning")
        XCTAssertEqual(fixture.store.providerErrors["copilot"], "Fixture quota failure Current history warning")
    }

    private struct Fixture {
        let runtime: HistoryFailureRuntime
        let store: WidgetDataStore
        let cache: ProviderSnapshotCache
        let previous: ProviderSnapshot
        let defaults: UserDefaults
    }

    private func makeFixture(
        providerID: String = "copilot", currentIdentity: String? = nil, cachedIdentity: String? = nil
    ) -> Fixture {
        let suite = "WidgetDataStoreHistoryFailureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let provider = Provider(id: providerID, displayName: "Fixture", icon: .providerMark("copilot"))
        let descriptor = WidgetDescriptor.percent(id: "\(providerID).quota", provider: provider, title: "Credits")
            .exportingHistory(scope: .machineLocal, estimatedCost: false, sourceNote: "Fixture history")
        let previous = ProviderSnapshot.make(
            provider: provider, plan: "Pro",
            lines: [.progress(label: "Credits", used: 25, limit: 100, format: .percent)],
            refreshedAt: now, usageHistory: history(tokens: 100), liveQuotaObservedAt: now, quotaObservedAt: now
        )
        let runtime = HistoryFailureRuntime(provider: provider, descriptors: [descriptor], snapshot: previous)
        let now = now
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", now: { now })
        cache.store(previous, producedByIdentityKey: cachedIdentity)
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime], cache: cache, defaults: defaults, now: { now },
            providerIdentityKeys: currentIdentity.map { [providerID: $0] } ?? [:]
        )
        return Fixture(runtime: runtime, store: store, cache: cache, previous: previous, defaults: defaults)
    }

    private func history(tokens: Int) -> ProviderUsageHistory {
        ProviderUsageHistory(series: DailyUsageSeries(daily: [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: tokens, costUSD: 1)
        ]))
    }

    private func failure(provider: Provider, history: ProviderUsageHistory?) -> ProviderSnapshot {
        var snapshot = ProviderSnapshot.error(provider: provider, message: "Fixture quota failure", category: .network)
        snapshot.usageHistory = history
        return snapshot
    }
}

@MainActor
private final class HistoryFailureRuntime: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor]
    var snapshot: ProviderSnapshot

    init(provider: Provider, descriptors: [WidgetDescriptor], snapshot: ProviderSnapshot) {
        self.provider = provider
        self.widgetDescriptors = descriptors
        self.snapshot = snapshot
    }

    func refresh() async -> ProviderSnapshot { snapshot }
}
