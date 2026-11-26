import XCTest
@testable import Egasu

@MainActor
final class QuotaResetReminderLifecycleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))
    private let workspace = "quota-fixture-workspace"
    private let shared = "codex"

    @MainActor
    private final class Center {
        var pending: [String: ScheduledReminder]
        var submitted: [String] = []
        var removed: [String] = []
        var didSubmit: ((String) -> Void)?
        var didRemove: (([String]) -> Void)?

        init(_ pending: [String: ScheduledReminder]) {
            self.pending = pending
        }

        func scheduler(now: Date) -> ScheduledReminders {
            ScheduledReminders(
                prefix: QuotaResetReminders.prefix, now: { now }, pending: { Array(self.pending.values) },
                schedule: { item, isCurrent in
                    guard isCurrent() else { return }
                    self.pending[item.id] = item
                    self.submitted.append(item.id)
                    self.didSubmit?(item.id)
                },
                remove: { ids in
                    for id in ids { self.pending[id] = nil }
                    self.removed.append(contentsOf: ids)
                    self.didRemove?(ids)
                })
        }
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "QuotaResetReminderLifecycleTests.\(UUID())"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    private func reading(
        profileID: String? = nil, subject: String = "fixture-user", observedAt: Date,
        weekly: Date? = nil, monthly: Date? = nil
    ) throws -> TestProviderRuntime {
        let card = profileID.map { AccountUsageCardPlanner.cardID(family: shared, profileID: $0) } ?? shared
        let provider = CodexProvider.makeProvider(id: card)
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject])
        let token = CodexTokens(accessToken: "e30.\(payload.base64EncodedString()).fixture", accountID: workspace)
        let source: CodexAuthState.Source = profileID.map { .accountSnapshot(profileID: $0) } ?? .keychain
        let auth = CodexAuthState(auth: CodexAuth(tokens: token), source: source)
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: auth))
        let key = try XCTUnwrap(binding.verifiedAccountKey)
        var lines: [MetricLine] = []
        if let weekly {
            lines.append(
                .progress(
                    label: "Weekly", used: 25, limit: 100, format: .percent,
                    resetsAt: weekly, periodDurationMs: MetricPeriod.weekMs))
        }
        if let monthly {
            lines.append(
                .progress(
                    label: "Monthly", used: 20, limit: 100, format: .percent,
                    resetsAt: monthly, periodDurationMs: MetricPeriod.monthMs))
        }
        var snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: lines, refreshedAt: observedAt,
            liveQuotaObservedAt: observedAt, liveQuotaAccountKey: key, codexResetClaimBinding: binding)
        snapshot.codexSwitchIdentity = workspace
        return TestProviderRuntime(
            provider: provider, descriptors: CodexProvider(provider: provider).widgetDescriptors, snapshot: snapshot)
    }

    private func marker() throws -> TestProviderRuntime {
        try reading(
            profileID: UUID().uuidString, subject: "independent-fixture-user", observedAt: now,
            monthly: now.addingTimeInterval(14 * 86_400))
    }

    private func requests(for runtime: TestProviderRuntime) -> [ScheduledReminder] {
        QuotaResetReminders.reminders(
            for: runtime.snapshot, descriptors: runtime.widgetDescriptors, account: "Codex", now: now,
            accountIdentity: runtime.snapshot.liveQuotaAccountKey)
    }

    private func observe(
        _ observer: QuotaResetReminders, store: WidgetDataStore, settings: NotificationSettingsStore,
        enablement: ProviderEnablementStore
    ) {
        store.onQuotaInvalidated = { [weak observer] ids in observer?.invalidate(ids) }
        store.onFreshSnapshot = { [weak observer] snapshot, _, _ in observer?.receivedSnapshot(snapshot) }
        store.onRefreshOutcome = { [weak observer] id, outcome, category, _, _ in
            if outcome == .failed { observer?.refreshFailed(for: id, category: category) }
        }
        enablement.onChange = { [weak store] in store?.providerEnablementDidChange() }
        observer.observe(settings: settings, dataStore: store, enablement: enablement)
    }

    private func expectPending(
        _ items: [ScheduledReminder], in center: Center, line: UInt = #line
    ) {
        XCTAssertEqual(center.pending, Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) }), line: line)
    }

    private func waitForSubmission(
        of item: ScheduledReminder, in center: Center, after action: () async -> Void
    ) async {
        let submitted = expectation(description: "예약 제출 \(item.id)")
        center.didSubmit = { id in
            if id == item.id { submitted.fulfill() }
        }
        await action()
        await fulfillment(of: [submitted], timeout: 3)
        center.didSubmit = nil
    }

    private func waitForRemoval(
        of items: [ScheduledReminder], in center: Center, after action: () async -> Void
    ) async {
        let removed = expectation(description: "기존 예약 취소")
        var remaining = Set(items.map(\.id))
        center.didRemove = { ids in
            remaining.subtract(ids)
            if remaining.isEmpty { removed.fulfill() }
        }
        await action()
        await fulfillment(of: [removed], timeout: 3)
        center.didRemove = nil
    }

    func testRemovingLatestAliasKeepsNewestWindowsUntilRemainingCardRefreshes() async throws {
        try await checkLatestAliasRemoval(latestHasWeekly: true)
    }

    func testRemovingLatestAliasWithMissingWeeklyDoesNotReviveOlderWindow() async throws {
        try await checkLatestAliasRemoval(latestHasWeekly: false)
    }

    private func checkLatestAliasRemoval(latestHasWeekly: Bool) async throws {
        let defaults = try makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let enablement = ProviderEnablementStore(defaults: defaults)
        let old = try reading(observedAt: now.addingTimeInterval(-60), weekly: now.addingTimeInterval(2 * 86_400))
        let latest = try reading(
            profileID: UUID().uuidString, observedAt: now,
            weekly: latestHasWeekly ? now.addingTimeInterval(3 * 86_400) : nil,
            monthly: now.addingTimeInterval(8 * 86_400))
        let fresh = try reading(
            observedAt: now.addingTimeInterval(60), weekly: now.addingTimeInterval(4 * 86_400),
            monthly: now.addingTimeInterval(9 * 86_400))
        let witness = try marker()
        let providers = [old, latest, witness]
        let identities = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, workspace) })
        let store = WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false), defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) }, providerIdentityKeys: identities)
        for provider in providers {
            let outcome = await store.refresh(providerID: provider.provider.id, force: true)
            XCTAssertEqual(outcome, .refreshed)
        }

        XCTAssertEqual(old.snapshot.liveQuotaAccountKey, latest.snapshot.liveQuotaAccountKey)
        XCTAssertNotEqual(old.snapshot.liveQuotaAccountKey, witness.snapshot.liveQuotaAccountKey)
        enablement.setEnabled(false, for: witness.provider.id)
        let unrelated = ScheduledReminder(id: "other.expiry", date: now, title: "", subtitle: "", body: "")
        let center = Center([unrelated.id: unrelated])
        let observer = QuotaResetReminders(scheduler: center.scheduler(now: now), defaults: defaults)
        let latestRequests = requests(for: latest)
        XCTAssertEqual(latestRequests.count, latestHasWeekly ? 4 : 2)
        await waitForSubmission(of: try XCTUnwrap(latestRequests.last), in: center) {
            observe(observer, store: store, settings: settings, enablement: enablement)
        }
        expectPending([unrelated] + latestRequests, in: center)

        let witnesses = requests(for: witness)
        XCTAssertEqual(witnesses.count, 2)
        center.submitted.removeAll()
        center.removed.removeAll()
        // 다른 계정의 마지막 예약을 관측할 때까지 앞선 예약 변경도 적용됨.
        await waitForSubmission(of: try XCTUnwrap(witnesses.last), in: center) {
            store.replaceProviderCatalog(
                registry: WidgetRegistry.from([fresh, witness]), providers: [fresh, witness],
                identityKeys: [shared: workspace, witness.provider.id: workspace])
            enablement.setEnabled(true, for: witness.provider.id)
        }
        XCTAssertNil(store.localSnapshots[latest.provider.id])
        XCTAssertEqual(store.localSnapshots[shared]?.liveQuotaObservedAt, old.snapshot.liveQuotaObservedAt)
        expectPending([unrelated] + latestRequests + witnesses, in: center)
        XCTAssertEqual(center.submitted, witnesses.map(\.id))
        XCTAssertTrue(center.removed.isEmpty)

        await waitForRemoval(of: witnesses, in: center) { settings.weeklyMonthlyResetReminders = false }
        expectPending([unrelated], in: center)
        await waitForSubmission(of: try XCTUnwrap(witnesses.last), in: center) {
            settings.weeklyMonthlyResetReminders = true
        }
        expectPending([unrelated] + latestRequests + witnesses, in: center)

        await waitForRemoval(of: witnesses, in: center) {
            enablement.setEnabled(false, for: shared)
            enablement.setEnabled(false, for: witness.provider.id)
        }
        expectPending([unrelated], in: center)
        await waitForSubmission(of: try XCTUnwrap(witnesses.last), in: center) {
            enablement.setEnabled(true, for: shared)
            enablement.setEnabled(true, for: witness.provider.id)
        }
        expectPending([unrelated] + latestRequests + witnesses, in: center)

        let freshRequests = requests(for: fresh)
        XCTAssertEqual(freshRequests.count, 4)
        await waitForSubmission(of: try XCTUnwrap(freshRequests.last), in: center) {
            let outcome = await store.refresh(providerID: shared, force: true)
            XCTAssertEqual(outcome, .refreshed)
        }
        expectPending([unrelated] + freshRequests + witnesses, in: center)

        await waitForRemoval(of: freshRequests, in: center) {
            store.replaceProviderCatalog(
                registry: WidgetRegistry.from([witness]), providers: [witness],
                identityKeys: [witness.provider.id: workspace])
        }
        expectPending([unrelated] + witnesses, in: center)
        await waitForRemoval(of: witnesses, in: center) { settings.weeklyMonthlyResetReminders = false }
        expectPending([unrelated], in: center)
    }

    func testSettingsAndAccountChangesReconcileWithoutWaitingForScheduledRefresh() async throws {
        let defaults = try makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let initial = try reading(observedAt: now, weekly: now.addingTimeInterval(2 * 86_400))
        let witness = try marker()
        var stale = initial.snapshot
        stale.liveQuotaObservedAt = nil
        stale.quotaObservedAt = now
        stale.isDegraded = true
        let network = ProviderSnapshot.error(provider: initial.provider, message: "network", category: .network)
        let expired = ProviderSnapshot.error(provider: initial.provider, message: "signed out", category: .authExpired)
        let runtime = SequenceProviderRuntime(
            provider: initial.provider, descriptors: initial.widgetDescriptors,
            snapshots: [initial.snapshot, network, expired, stale, initial.snapshot])
        let providers: [any ProviderRuntime] = [runtime, witness]
        let store = WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false), defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) },
            providerIdentityKeys: [shared: workspace, witness.provider.id: workspace])
        let unrelated = ScheduledReminder(id: "other.expiry", date: now, title: "", subtitle: "", body: "")
        let center = Center([unrelated.id: unrelated])
        let scheduler = center.scheduler(now: now)
        var observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observe(observer, store: store, settings: settings, enablement: enablement)
        for provider in providers {
            let outcome = await store.refresh(providerID: provider.provider.id, force: true)
            XCTAssertEqual(outcome, .refreshed)
        }
        enablement.setEnabled(false, for: witness.provider.id)
        let original = requests(for: initial)
        let lastOriginal = try XCTUnwrap(original.last)
        XCTAssertEqual(original.count, 2)
        await waitForSubmission(of: lastOriginal, in: center) { settings.weeklyMonthlyResetReminders = true }
        expectPending([unrelated] + original, in: center)
        await waitForRemoval(of: original, in: center) { enablement.setEnabled(false, for: shared) }
        expectPending([unrelated], in: center)
        await waitForSubmission(of: lastOriginal, in: center) { enablement.setEnabled(true, for: shared) }
        expectPending([unrelated] + original, in: center)

        let witnesses = requests(for: witness)
        XCTAssertEqual(witnesses.count, 2)
        let lastWitness = try XCTUnwrap(witnesses.last)
        center.submitted.removeAll()
        center.removed.removeAll()
        await waitForSubmission(of: lastWitness, in: center) {
            let outcome = await store.refresh(providerID: shared, force: true)
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(store.refreshResults[shared]?.failure?.category, .network)
            enablement.setEnabled(true, for: witness.provider.id)
        }
        expectPending([unrelated] + original + witnesses, in: center)
        XCTAssertEqual(center.submitted, witnesses.map(\.id))
        XCTAssertTrue(center.removed.isEmpty)
        await waitForRemoval(of: witnesses, in: center) { enablement.setEnabled(false, for: witness.provider.id) }

        await waitForRemoval(of: original, in: center) {
            let outcome = await store.refresh(providerID: shared, force: true)
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(store.refreshResults[shared]?.failure?.category, .authExpired)
        }
        expectPending([unrelated], in: center)

        center.pending = Dictionary(uniqueKeysWithValues: ([unrelated] + original).map { ($0.id, $0) })
        await waitForRemoval(of: original, in: center) {
            observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
            observe(observer, store: store, settings: settings, enablement: enablement)
        }
        expectPending([unrelated], in: center)

        center.submitted.removeAll()
        center.removed.removeAll()
        await waitForSubmission(of: lastWitness, in: center) {
            let outcome = await store.refresh(providerID: shared, force: true)
            XCTAssertEqual(outcome, .refreshed)
            XCTAssertEqual(store.localSnapshots[shared]?.isDegraded, true)
            XCTAssertNil(store.localSnapshots[shared]?.liveQuotaObservedAt)
            enablement.setEnabled(true, for: witness.provider.id)
        }
        expectPending([unrelated] + witnesses, in: center)
        XCTAssertEqual(center.submitted, witnesses.map(\.id))
        XCTAssertTrue(center.removed.isEmpty)
        await waitForRemoval(of: witnesses, in: center) { enablement.setEnabled(false, for: witness.provider.id) }

        await waitForSubmission(of: lastOriginal, in: center) {
            let outcome = await store.refresh(providerID: shared, force: true)
            XCTAssertEqual(outcome, .refreshed)
        }
        expectPending([unrelated] + original, in: center)
        await waitForRemoval(of: original, in: center) { settings.weeklyMonthlyResetReminders = false }
        expectPending([unrelated], in: center)
    }
}
