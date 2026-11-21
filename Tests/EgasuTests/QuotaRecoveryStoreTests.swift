import XCTest
@testable import Egasu

@MainActor
final class QuotaRecoveryStoreTests: XCTestCase {
    private final class Runtime: ProviderRuntime {
        let provider = MockData.claude
        let widgetDescriptors: [WidgetDescriptor]
        var snapshot: ProviderSnapshot

        init(estimated: Bool, mixed: Bool) {
            var descriptor = WidgetDescriptor(
                id: "claude.weekly", providerID: provider.id, metricLabel: "Weekly",
                sample: WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 0, limit: 100)
            ).exportingLimit("weekly", unit: "percent", estimated: estimated)
            if mixed { descriptor = descriptor.exportingLimit("weeklySpend", unit: "usd", estimated: true) }
            widgetDescriptors = [descriptor]
            snapshot = ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        }

        func refresh() async -> ProviderSnapshot { snapshot }
    }

    private var now = Date(timeIntervalSince1970: 1_700_000_000)
    private var posts: [String] = []

    private func fixture(
        estimated: Bool = false, mixed: Bool = false, post: QuotaNotificationEvaluator.Post? = nil
    ) -> (WidgetDataStore, Runtime) {
        let suite = "QuotaRecoveryStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let runtime = Runtime(estimated: estimated, mixed: mixed)
        let registry = WidgetRegistry(providers: [runtime.provider], descriptors: runtime.widgetDescriptors)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.quotaRecovered = true
        let store = WidgetDataStore(
            registry: registry, providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { self.now }),
            defaults: defaults, orderedDescriptors: { runtime.widgetDescriptors }, now: { self.now },
            notificationSettings: { settings },
            postNotification: post ?? { id, _, _, _, _ in
                self.posts.append(id); return true
            }
        )
        store.replaceProviderCatalog(registry: registry, providers: [runtime], identityKeys: ["claude": "catalog-A"])
        return (store, runtime)
    }

    private func set(_ runtime: Runtime, used: Double, account: String?, observed: Date?, reset: Date? = nil) {
        runtime.snapshot = ProviderSnapshot(
            providerID: runtime.provider.id, displayName: runtime.provider.displayName,
            lines: [
                .progress(
                    label: "Weekly", used: used, limit: 100, format: .percent,
                    resetsAt: reset ?? now.addingTimeInterval(86_400), periodDurationMs: MetricPeriod.weekMs)
            ],
            refreshedAt: now, liveQuotaObservedAt: observed, liveQuotaAccountKey: account
        )
    }

    func testSingleAndBulkManualRefreshCompareOnlyActualQuotaAccounts() async {
        let (store, runtime) = fixture()
        set(runtime, used: 100, account: "cli-A", observed: now)
        await store.refresh(providerID: "claude", force: true, trigger: .manual)
        set(runtime, used: 0, account: "desktop-B", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        XCTAssertTrue(posts.isEmpty)

        set(runtime, used: 100, account: "desktop-B", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        set(runtime, used: 0, account: "desktop-B", observed: now)
        await store.refresh(providerID: "claude", force: true, trigger: .manual)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["claude.quotaRecovered"])
    }

    func testScheduledRecoveryRequiresAnIdentifiedFreshUnexpiredQuota() async {
        let (store, runtime) = fixture()
        set(runtime, used: 100, account: "A", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        for (account, observed, reset): (String?, Date?, Date?) in [
            (nil, now, nil), ("A", nil, nil), ("A", now.addingTimeInterval(-86_400), nil), ("A", now, now)
        ] {
            set(runtime, used: 0, account: account, observed: observed, reset: reset)
            await store.refreshAll(force: true)
            await store.evaluateNotifications(now: now)
        }
        XCTAssertTrue(posts.isEmpty)
        set(runtime, used: 0, account: "A", observed: now)
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["claude.quotaRecovered"])
    }

    func testEstimatedOrMixedQuotaCannotTriggerRecovery() async {
        for (store, runtime) in [fixture(estimated: true), fixture(mixed: true)] {
            for used: Double in [100, 0] {
                set(runtime, used: used, account: "A", observed: now)
                await store.refreshAll(force: true, trigger: .manual)
            }
        }
        XCTAssertTrue(posts.isEmpty)
    }

    func testDeliveryRechecksResponseAccountAfterWaitingForPermission() async {
        var refreshWhileWaiting: (@MainActor () async -> Void)?
        var delivered: Bool?
        let (store, runtime) = fixture { _, _, _, _, isCurrent in
            await refreshWhileWaiting?()
            delivered = isCurrent()
            return delivered == true
        }
        refreshWhileWaiting = {
            self.set(runtime, used: 0, account: "B", observed: self.now)
            await store.refresh(providerID: "claude", force: true)
        }
        set(runtime, used: 100, account: "A", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        set(runtime, used: 0, account: "A", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        XCTAssertEqual(delivered, false)
    }

    func testReconciliationFailureInvalidatesTheReadingUntilAnotherSuccessfulRefresh() async {
        let (store, runtime) = fixture()
        set(runtime, used: 100, account: "A", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        store.setClaudeReconciliationFailure(.init(message: "fixture", category: .credentialAccess))
        set(runtime, used: 0, account: "A", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        store.setClaudeReconciliationFailure(nil)
        await store.evaluateNotifications(now: now)
        XCTAssertTrue(posts.isEmpty)
        now.addTimeInterval(1)
        set(runtime, used: 0, account: "A", observed: now)
        await store.refreshAll(force: true, trigger: .manual)
        XCTAssertEqual(posts, ["claude.quotaRecovered"])
    }
}
