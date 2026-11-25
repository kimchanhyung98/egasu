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
            account: "Account A", now: now)
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
            XCTAssertEqual(Set((weekly + monthly + reminders(id: "codex:/second")).map(\.id)).count, 6)
            XCTAssertTrue(reminders(label: "Session", duration: MetricPeriod.sessionMs).isEmpty)
            XCTAssertTrue(reminders(duration: 2 * MetricPeriod.dayMs).isEmpty)
            XCTAssertTrue(reminders(duration: nil).isEmpty)
            XCTAssertTrue(reminders(remainingHours: nil).isEmpty)
            XCTAssertTrue(reminders(remainingHours: 12).isEmpty)
            XCTAssertEqual(reminders(remainingHours: 20).count, 1)
        }
    }

    func testGrokDeclaredBillingPeriodMustAgreeWithItsCalendarDates() throws {
        let runtime = GrokProvider()
        func requests(type: String, duration: TimeInterval) throws -> [ScheduledReminder] {
            let reset = now.addingTimeInterval(48 * 3600)
            let body = GrokCreditsFixtures.responseBody(
                periodType: type, start: reset.addingTimeInterval(-duration).ISO8601Format(), end: reset.ISO8601Format()
            )
            let response = HTTPResponse(statusCode: 200, headers: [:], body: body)
            let usage = try GrokUsageMapper.mapCreditsConfig(response)
            let snapshot = ProviderSnapshot.make(
                provider: runtime.provider, plan: nil, lines: usage.lines, refreshedAt: now)
            return QuotaResetReminders.reminders(
                for: snapshot, descriptors: runtime.widgetDescriptors, account: "Grok", now: now)
        }
        let week = 7.0 * 86_400
        let month = 31.0 * 86_400
        XCTAssertTrue(try requests(type: GrokCreditsConfigDecoder.monthlyPeriodType, duration: week).isEmpty)
        XCTAssertTrue(try requests(type: GrokCreditsConfigDecoder.weeklyPeriodType, duration: month).isEmpty)
        XCTAssertEqual(try requests(type: GrokCreditsConfigDecoder.weeklyPeriodType, duration: week - 3600).count, 2)
        XCTAssertEqual(try requests(type: GrokCreditsConfigDecoder.monthlyPeriodType, duration: month + 3600).count, 2)
        XCTAssertTrue(reminders(duration: MetricPeriod.weekMs - 3_600_000).isEmpty)
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
                for: snapshot, descriptors: runtime.widgetDescriptors, account: "Cursor", now: now)
        }
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

    func testVerifiedMonthlyWindowCanOmitDurationAndEstimatedUsageIsIgnored() {
        let provider = CodexProvider.makeProvider()
        let line = MetricLine.progress(
            label: "Credits", used: 3, limit: 5, format: .percent, resetsAt: now.addingTimeInterval(100_000))
        let snapshot = ProviderSnapshot.make(provider: provider, plan: nil, lines: [line], refreshedAt: now)
        let verified = WidgetDescriptor.percent(id: "p.credits", provider: provider, title: "Credits")
            .supportingSoftLimit(.monthly, acceptsMissingDuration: true)
        let projected = QuotaResetReminders.reminders(
            for: snapshot, descriptors: [verified.exportingLimit("credits", unit: "percent")], account: "A", now: now)
        XCTAssertEqual(projected.count, 2)
        XCTAssertTrue(
            QuotaResetReminders.reminders(
                for: snapshot, descriptors: [verified.exportingLimit("credits", unit: "percent", estimated: true)],
                account: "A", now: now
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

    func testSettingsAndAccountChangesReconcileWithoutWaitingForScheduledRefresh() async throws {
        let name = "QuotaResetReminderTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = NotificationSettingsStore(defaults: defaults)
        let clock = Date.now
        let runtime = CodexProvider()
        let card = runtime.provider.id
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let snapshot = ProviderSnapshot.make(
            provider: runtime.provider, plan: nil,
            lines: [
                .progress(
                    label: "Weekly", used: 0, limit: 100, format: .percent,
                    resetsAt: clock.addingTimeInterval(172_800), periodDurationMs: MetricPeriod.weekMs)
            ], refreshedAt: clock, liveQuotaObservedAt: clock)
        cache.store(snapshot)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache, defaults: defaults,
            orderedDescriptors: { [] }, resolveDisplayName: { _ in "Account A" })
        let enabled = ProviderEnablementStore(defaults: defaults)
        enabled.setEnabled(true, for: card)
        let unrelated = ScheduledReminder(
            id: "other.expiry", date: now.addingTimeInterval(200_000), title: "", subtitle: "", body: "")
        var requests = [unrelated.id: unrelated]
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, now: { clock }, pending: { Array(requests.values) },
            schedule: { item, isCurrent in if isCurrent() { requests[item.id] = item } },
            remove: { for id in $0 { requests[id] = nil } })
        var observer: QuotaResetReminders? = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer?.observe(settings: settings, dataStore: store, enablement: enabled)
        func expectPending(_ count: Int, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(3)
            while requests.count != count && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(requests.count, count, line: line)
            XCTAssertEqual(requests[unrelated.id], unrelated, line: line)
        }
        settings.weeklyMonthlyResetReminders = true
        await expectPending(3)
        enabled.setEnabled(false, for: card)
        await expectPending(1)
        enabled.setEnabled(true, for: card)
        await expectPending(3)
        observer?.refreshFailed(for: card, category: .network)
        await expectPending(3)
        let beforeInvalidation = requests
        observer?.refreshFailed(for: card, category: .authExpired)
        await expectPending(1)

        observer = nil
        requests = beforeInvalidation
        observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer?.observe(settings: settings, dataStore: store, enablement: enabled)
        await expectPending(1)
        var stale = snapshot
        stale.liveQuotaObservedAt = nil
        stale.quotaObservedAt = clock
        stale.isDegraded = true
        observer?.receivedSnapshot(stale)
        await expectPending(1)
        observer?.receivedSnapshot(snapshot)
        await expectPending(3)
        settings.weeklyMonthlyResetReminders = false
        await expectPending(1)
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
