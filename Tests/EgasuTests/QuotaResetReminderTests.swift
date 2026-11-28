import Foundation
import XCTest
@testable import Egasu

@MainActor
final class QuotaResetReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reminders(
        id: String = "codex", label: String = "Weekly", used: Double = 0,
        duration: Int? = MetricPeriod.weekMs, remainingHours: Int? = 48
    ) -> [ScheduledReminder] {
        let provider = CodexProvider.makeProvider(id: id)
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil,
            lines: [
                .progress(
                    label: label, used: used, limit: 100, format: .percent,
                    resetsAt: remainingHours.map { now.addingTimeInterval(Double($0 * 3600)) },
                    periodDurationMs: duration)
            ], refreshedAt: now)
        return QuotaResetReminders.reminders(
            for: snapshot, descriptors: CodexProvider(provider: provider).widgetDescriptors,
            account: "Account A", now: now, accountIdentity: id)
    }

    func testEachEligibleAccountAndLimitReceivesTwoSpecificFutureReminders() {
        L10n.withLanguage(.english) {
            let weekly = reminders()
            let monthly = reminders(label: "Monthly", used: 100, duration: 31 * MetricPeriod.dayMs)
            XCTAssertEqual(weekly.map(\.date), [now.addingTimeInterval(24 * 3600), now.addingTimeInterval(36 * 3600)])
            XCTAssertEqual(monthly.map(\.date), weekly.map(\.date))
            XCTAssertEqual(weekly.map(\.body), ["This limit resets in 24 hours.", "This limit resets in 12 hours."])
            XCTAssertTrue(weekly.allSatisfy { $0.title == "Weekly Limit Reset" && $0.subtitle == "Account A Weekly" })
            XCTAssertTrue(
                monthly.allSatisfy { $0.title == "Monthly Limit Reset" && $0.subtitle == "Account A Monthly" })
            XCTAssertEqual(Set((weekly + monthly + reminders(id: "codex@second")).map(\.id)).count, 6)
            XCTAssertTrue(reminders(label: "Session", duration: MetricPeriod.sessionMs).isEmpty)
            XCTAssertTrue(reminders(duration: 2 * MetricPeriod.dayMs).isEmpty)
            XCTAssertTrue(reminders(duration: MetricPeriod.weekMs - 3_600_000).isEmpty)
            XCTAssertTrue(reminders(duration: nil).isEmpty)
            XCTAssertTrue(reminders(remainingHours: nil).isEmpty)
            XCTAssertTrue(reminders(remainingHours: 12).isEmpty)
            XCTAssertEqual(reminders(remainingHours: 20).count, 1)
        }
    }

    func testFailedReservationsRetryWithoutRepostingAnUnchangedSecondAccount() async {
        let a = reminders(id: "codex")
        let b = reminders(id: "codex@profile-b")
        var pending: [String: ScheduledReminder] = [:]
        var writes: [String: Int] = [:]
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, now: { self.now }, pending: { Array(pending.values) },
            schedule: { item, isCurrent in
                guard isCurrent() else { return }
                writes[item.id, default: 0] += 1
                if writes[item.id] == 1 && a.contains(item) { return }
                pending[item.id] = item
            },
            remove: { for id in $0 { pending[id] = nil } })
        await scheduler.reconcile(a + b).value
        XCTAssertEqual(Set(pending.keys), Set(b.map(\.id)))
        await scheduler.reconcile(a + b).value
        XCTAssertEqual(Set(pending.keys), Set((a + b).map(\.id)))
        for item in a { XCTAssertEqual(writes[item.id], 2) }
        for item in b { XCTAssertEqual(writes[item.id], 1) }
        await scheduler.reconcile(b).value
        XCTAssertEqual(Set(pending.keys), Set(b.map(\.id)))
    }

    func testCursorRequiresTheReadingAccountForRemindersIncludingAfterRelaunch() throws {
        let runtime = CursorProvider()
        var reading = ProviderSnapshot.make(
            provider: runtime.provider, plan: nil,
            lines: [
                .progress(
                    label: "Total usage", used: 3, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval(48 * 3600), periodDurationMs: MetricPeriod.monthMs)
            ], refreshedAt: now)
        func scheduled(_ snapshot: ProviderSnapshot) -> [ScheduledReminder] {
            QuotaResetReminders.reminders(
                for: snapshot, descriptors: runtime.widgetDescriptors, account: "Cursor", now: now,
                accountIdentity: "account-a")
        }
        XCTAssertTrue(scheduled(reading).isEmpty)
        reading.producedByIdentityKey = "account-b"
        XCTAssertTrue(scheduled(reading).isEmpty)
        reading.producedByIdentityKey = "account-a"
        XCTAssertEqual(scheduled(reading).count, 2)

        let suite = "QuotaResetReminderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let writer = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        writer.store(reading, producedByIdentityKey: "account-a")

        func relaunch(identity: String?) -> ProviderSnapshot? {
            let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
            let store = WidgetDataStore(
                registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: reader, defaults: defaults,
                providerIdentityKeys: identity.map { ["cursor": $0] } ?? [:])
            return store.localSnapshots["cursor"]
        }
        XCTAssertNil(relaunch(identity: nil))
        XCTAssertNil(relaunch(identity: "account-b"))
        XCTAssertEqual(scheduled(try XCTUnwrap(relaunch(identity: "account-a"))).count, 2)
        XCTAssertEqual(reminders().count, 2)
    }

    func testCursorRequestFallbackRemindsOncePerLeadTime() throws {
        let runtime = CursorProvider()
        let mapped = try CursorUsageSummaryMapper.map(
            summary: nil,
            requestUsage: [
                "startOfMonth": now.addingTimeInterval(-28 * 86_400).ISO8601Format(),
                "gpt-4": ["maxRequestUsage": 100, "numRequests": 2]
            ],
            planName: nil, unavailableMessage: "")
        XCTAssertNotNil(mapped.lines.first { $0.label == "Total usage" })
        XCTAssertNotNil(mapped.lines.first { $0.label == "Requests" })
        var snapshot = ProviderSnapshot.make(
            provider: runtime.provider, plan: nil, lines: mapped.lines, refreshedAt: now)
        snapshot.producedByIdentityKey = "account-a"
        let requests = QuotaResetReminders.reminders(
            for: snapshot, descriptors: runtime.widgetDescriptors, account: "A", now: now, accountIdentity: "account-a")
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.id.hasPrefix("openusage.quota-reset.cursor.requests.") })
    }

    func testUnknownCodexAccountCancelsCachedRemindersOnLaunch() async throws {
        try await checkCachedCodexRemindersCancelled(catalogIdentity: nil)
    }

    func testRegisteredCodexWorkspaceCancelsCachedRemindersWithoutLiveUserOnLaunch() async throws {
        try await checkCachedCodexRemindersCancelled(catalogIdentity: "previous")
    }

    private func checkCachedCodexRemindersCancelled(catalogIdentity: String?) async throws {
        let suite = "QuotaResetReminderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let runtime = CodexProvider()
        let now = Date.now
        let reset = now.addingTimeInterval(172_800)
        var snapshot = ProviderSnapshot.make(
            provider: runtime.provider, plan: nil,
            lines: [
                .progress(
                    label: "Weekly", used: 3, limit: 100, format: .percent, resetsAt: reset,
                    periodDurationMs: MetricPeriod.weekMs)
            ], refreshedAt: now, liveQuotaObservedAt: now, liveQuotaAccountKey: "verified-user")
        snapshot.codexSwitchIdentity = "previous"
        let writer = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        writer.store(snapshot, producedByIdentityKey: "previous")
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: reader, defaults: defaults,
            providerIdentityKeys: catalogIdentity.map { ["codex": $0] } ?? [:])
        XCTAssertNotNil(store.localSnapshots["codex"])
        XCTAssertNil(store.localSnapshots["codex"]?.liveQuotaAccountKey)
        let pending = QuotaResetReminders.reminders(
            for: snapshot, descriptors: runtime.widgetDescriptors, account: "Codex", now: now,
            accountIdentity: "previous")
        XCTAssertEqual(pending.count, 2)
        let cancelled = expectation(description: "이전 계정의 예약 취소")
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, pending: { pending },
            schedule: { _, _ in XCTFail("이전 계정의 알림을 예약했습니다.") },
            remove: { ids in
                XCTAssertEqual(Set(ids), Set(pending.map(\.id)))
                cancelled.fulfill()
            })
        let observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer.observe(settings: settings, dataStore: store, enablement: ProviderEnablementStore(defaults: defaults))
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testScheduleChangeDoesNotReviveElapsedLeadTimeAfterRelaunch() async throws {
        try await checkLeadTimesAfterRelaunch(earlyReset: false)
    }

    func testEarlyResetRearmsLeadTimesAfterRelaunch() async throws {
        try await checkLeadTimesAfterRelaunch(earlyReset: true)
    }

    private func checkLeadTimesAfterRelaunch(earlyReset: Bool) async throws {
        let suite = "QuotaResetReminderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let enablement = ProviderEnablementStore(defaults: defaults)
        let now = Date.now
        let oldReset = now.addingTimeInterval(86_100)
        let newReset = earlyReset ? now.addingTimeInterval(7 * 86_400) : oldReset.addingTimeInterval(600)
        let provider = CodexProvider.makeProvider()
        func snapshot(reset: Date, used: Double) -> ProviderSnapshot {
            var snapshot = ProviderSnapshot.make(
                provider: provider, plan: nil,
                lines: [
                    .progress(
                        label: "Weekly", used: used, limit: 100, format: .percent, resetsAt: reset,
                        periodDurationMs: MetricPeriod.weekMs)
                ], refreshedAt: now, liveQuotaObservedAt: now, liveQuotaAccountKey: "verified-account-a")
            snapshot.codexSwitchIdentity = "account-a"
            return snapshot
        }
        let first = snapshot(reset: oldReset, used: 40)
        let second = snapshot(reset: newReset, used: earlyReset ? 0 : 40)
        let runtime = TogglingProviderRuntime(
            provider: provider, descriptors: CodexProvider(provider: provider).widgetDescriptors,
            first: first, second: second)
        let cache = ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache, defaults: defaults,
            providerIdentityKeys: ["codex": "account-a"])
        var pending: [String: ScheduledReminder] = [:]
        var attempts: [ScheduledReminder] = []
        let firstScheduled = expectation(description: "기존 12시간 전 예약")
        let secondScheduled = expectation(description: "연장된 12시간 전 예약")
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, pending: { Array(pending.values) },
            schedule: { item, isCurrent in
                guard isCurrent() else { return }
                pending[item.id] = item
                attempts.append(item)
                if abs(item.date.timeIntervalSince(oldReset.addingTimeInterval(-43_200))) < 1 {
                    firstScheduled.fulfill()
                }
                if abs(item.date.timeIntervalSince(newReset.addingTimeInterval(-43_200))) < 1 {
                    secondScheduled.fulfill()
                }
            },
            remove: { ids in ids.forEach { pending[$0] = nil } })
        var observer: QuotaResetReminders? = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer?.observe(settings: settings, dataStore: store, enablement: enablement)
        await store.refresh(providerID: "codex", force: true)
        await fulfillment(of: [firstScheduled], timeout: 3)

        observer = nil
        observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer?.observe(settings: settings, dataStore: store, enablement: enablement)
        await store.refresh(providerID: "codex", force: true)
        await fulfillment(of: [secondScheduled], timeout: 3)
        XCTAssertEqual(attempts.count, earlyReset ? 3 : 2)
        XCTAssertEqual(pending.count, earlyReset ? 2 : 1)
    }

    func testAccountSwitchKeepsTheSamePendingReminderIdentifier() async throws {
        try await checkReminderAfterAccountSwitch(sameResetOnFirstRefresh: true)
    }

    func testAccountSwitchPreservesElapsedLeadTimesWhenResetMoves() async throws {
        try await checkReminderAfterAccountSwitch(sameResetOnFirstRefresh: false)
    }

    private func checkReminderAfterAccountSwitch(sameResetOnFirstRefresh: Bool) async throws {
        let suite = "QuotaResetReminderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let enablement = ProviderEnablementStore(defaults: defaults)
        let now = Date.now
        let oldReset = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 86_100)
        let extendedReset = oldReset.addingTimeInterval(600)
        let shared = CodexProvider.makeProvider()
        let saved = CodexProvider.makeProvider(id: "codex@profile-a")

        func snapshot(_ provider: Provider, _ reset: Date, workspace: String) -> ProviderSnapshot {
            let payload = Data(#"{"sub":"fixture-user"}"#.utf8).base64EncodedString()
            let auth = CodexAuth(tokens: CodexTokens(accessToken: "e30.\(payload).signature", accountID: workspace))
            let source: CodexAuthState.Source = provider.id == saved.id ? .accountSnapshot(profileID: "a") : .keychain
            let binding = CodexResetClaimBinding(authState: CodexAuthState(auth: auth, source: source))
            var snapshot = ProviderSnapshot.make(
                provider: provider, plan: nil,
                lines: [
                    .progress(
                        label: "Weekly", used: 40, limit: 100, format: .percent, resetsAt: reset,
                        periodDurationMs: MetricPeriod.weekMs)
                ], refreshedAt: now, liveQuotaObservedAt: now, liveQuotaAccountKey: binding?.verifiedAccountKey,
                codexResetClaimBinding: binding)
            snapshot.codexSwitchIdentity = workspace
            return snapshot
        }
        let sharedDescriptors = CodexProvider(provider: shared).widgetDescriptors
        let accountA = TestProviderRuntime(
            provider: shared, descriptors: sharedDescriptors,
            snapshot: snapshot(shared, oldReset, workspace: "account-a"))
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([accountA]), providers: [accountA],
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false),
            defaults: defaults, providerIdentityKeys: [shared.id: "account-a"],
            resolveDisplayName: { _ in "Shared A" })
        let savedA = TogglingProviderRuntime(
            provider: saved, descriptors: CodexProvider(provider: saved).widgetDescriptors,
            first: snapshot(saved, sameResetOnFirstRefresh ? oldReset : extendedReset, workspace: "account-a"),
            second: snapshot(saved, extendedReset, workspace: "account-a"))
        let sharedB = TestProviderRuntime(
            provider: shared, descriptors: sharedDescriptors,
            snapshot: snapshot(shared, extendedReset, workspace: "account-b"))

        var pending: [String: ScheduledReminder] = [:]
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, pending: { Array(pending.values) },
            schedule: { item, isCurrent in if isCurrent() { pending[item.id] = item } },
            remove: { ids in ids.forEach { pending[$0] = nil } })
        let observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer.observe(settings: settings, dataStore: store, enablement: enablement)
        store.onFreshSnapshot = { [weak observer] snapshot, _, _ in observer?.receivedSnapshot(snapshot) }
        store.onQuotaInvalidated = { [weak observer] ids in observer?.invalidate(ids) }

        func requests(for label: String) -> [ScheduledReminder] {
            pending.values.filter { $0.subtitle.contains(label) }
        }
        func waitFor(_ condition: () -> Bool, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while !condition() && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertTrue(condition(), line: line)
        }

        await store.refresh(providerID: shared.id, force: true)
        await waitFor { requests(for: "Codex").count == 1 }
        let oldReminder = try XCTUnwrap(requests(for: "Codex").first)

        store.resolveDisplayName = { $0 == saved.id ? "Saved A" : "Shared B" }
        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([sharedB, savedA]), providers: [sharedB, savedA],
            identityKeys: [shared.id: "account-b", saved.id: "account-a"])
        await store.refresh(providerID: saved.id, force: true)
        if sameResetOnFirstRefresh {
            await waitFor { requests(for: "Saved A").count == 1 }
            XCTAssertEqual(requests(for: "Saved A").map(\.id), [oldReminder.id])
            await store.refresh(providerID: saved.id, force: true)
        }
        await store.refresh(providerID: shared.id, force: true)
        let updatedFire = extendedReset.addingTimeInterval(-43_200)
        await waitFor {
            requests(for: "Saved A").contains { $0.date == updatedFire }
                && requests(for: "Codex").count == 2
        }
        XCTAssertEqual(requests(for: "Saved A").map(\.date), [updatedFire])
        XCTAssertEqual(
            Set(requests(for: "Codex").map(\.date)), [extendedReset.addingTimeInterval(-86_400), updatedFire])
    }

    func testVerifiedMonthlyWindowCanOmitDurationAndEstimatedUsageIsIgnored() {
        let provider = CodexProvider.makeProvider()
        let line = MetricLine.progress(
            label: "Credits", used: 3, limit: 5, format: .percent, resetsAt: now.addingTimeInterval(100_000))
        let snapshot = ProviderSnapshot.make(provider: provider, plan: nil, lines: [line], refreshedAt: now)
        let verified = WidgetDescriptor.percent(id: "codex.credits", provider: provider, title: "Credits")
            .supportingSoftLimit(.monthly, acceptsMissingDuration: true)
        let projected = QuotaResetReminders.reminders(
            for: snapshot, descriptors: [verified.exportingLimit("credits", unit: "percent")], account: "A", now: now,
            accountIdentity: "account-a")
        XCTAssertEqual(projected.count, 2)
        XCTAssertTrue(
            QuotaResetReminders.reminders(
                for: snapshot, descriptors: [verified.exportingLimit("credits", unit: "percent", estimated: true)],
                account: "A", now: now, accountIdentity: "account-a"
            ).isEmpty)
    }

    func testRelaunchReusesPendingRequestsAndMovingResetOnlyUpdatesOwnedRequests() async {
        var requests: [String: ScheduledReminder] = [:]
        var writes = 0
        let unrelated = ScheduledReminder(
            id: "other.credit-reminder", date: now.addingTimeInterval(200_000), title: "", subtitle: "", body: "")
        requests[unrelated.id] = unrelated
        func scheduler() -> ScheduledReminders {
            ScheduledReminders(
                prefix: QuotaResetReminders.prefix, now: { self.now }, pending: { Array(requests.values) },
                schedule: { item, isCurrent in
                    if isCurrent() {
                        requests[item.id] = item
                        writes += 1
                    }
                },
                remove: { for id in $0 { requests[id] = nil } })
        }
        let previous = reminders()
        await scheduler().reconcile(previous).value
        let relaunched = scheduler()
        await relaunched.reconcile(previous).value
        XCTAssertEqual(writes, 2)
        let changed = reminders(remainingHours: 50)
        await relaunched.reconcile(changed).value
        XCTAssertEqual(writes, 4)
        XCTAssertEqual(Set(requests.keys), Set(changed.map(\.id) + [unrelated.id]))
        await relaunched.reconcile([]).value
        XCTAssertEqual(requests, [unrelated.id: unrelated])
    }

    func testQuotaReminderAndRemainingUsageSettingsPersistIndependently() throws {
        let name = "QuotaResetReminderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = NotificationSettingsStore(defaults: defaults)
        XCTAssertFalse(settings.weeklyMonthlyResetReminders)
        for quota in [false, true] {
            for unused in [true, false] {
                settings.weeklyMonthlyResetReminders = quota
                settings.useItOrLoseIt = unused
                let restored = NotificationSettingsStore(defaults: defaults)
                XCTAssertEqual(restored.weeklyMonthlyResetReminders, quota)
                XCTAssertEqual(restored.useItOrLoseIt, unused)
                XCTAssertEqual(restored.anyEnabled, quota || unused)
            }
        }
    }
}
