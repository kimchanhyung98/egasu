import UserNotifications
import XCTest
@testable import Egasu

@MainActor
final class CodexCreditExpiryReminderTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private final class Center {
        var now: Date
        var requests: [String: ScheduledReminder] = [:]
        var attempts = 0
        var capacity = Int.max
        init(_ now: Date) { self.now = now }

        func scheduler() -> ScheduledReminders {
            ScheduledReminders(
                prefix: CodexCreditExpiryReminders.prefix, now: { self.now }, pending: { Array(self.requests.values) },
                schedule: { reminder, current in
                    guard current() else { return }
                    self.attempts += 1
                    if self.requests.count < self.capacity { self.requests[reminder.id] = reminder }
                }, remove: { ids in ids.forEach { self.requests.removeValue(forKey: $0) } })
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "EgasuTests.CreditExpiry.\(UUID())"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func snapshot(count: Int, expiries: [Date], observed: Date? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: "codex", displayName: "Codex",
            lines: [
                .values(
                    label: "Rate Limit Resets", values: [MetricValue(number: Double(count), kind: .count)],
                    expiriesAt: expiries)
            ],
            quotaObservedAt: observed)
    }

    func testFreshAndRelaunchedSchedulesRecognizeEqualExpiriesAndSeparateAccounts() async {
        let store = defaults()
        let center = Center(start)
        let expiry = start.addingTimeInterval(48 * 3600)
        let first = ("one", "A", snapshot(count: 3, expiries: [expiry, expiry]))
        let second = ("two", "B", snapshot(count: 1, expiries: [expiry]))
        let scheduler = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: store)
        await scheduler.reconcile(accounts: [first, second], now: start).value
        XCTAssertEqual(center.requests.count, 6)
        XCTAssertEqual(center.requests.values.filter { $0.subtitle == "A" }.count, 4)
        XCTAssertEqual(
            Set(center.requests.values.map(\.date)),
            [expiry.addingTimeInterval(-86400), expiry.addingTimeInterval(-43200)])
        await scheduler.reconcile(accounts: [second, first], now: start).value
        let relaunched = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: store)
        await relaunched.reconcile(accounts: [first, second], now: start).value
        XCTAssertEqual(center.attempts, 6)

        let other = ScheduledReminder(id: "quota-reset.other", date: expiry, title: "", subtitle: "", body: "")
        center.requests[other.id] = other
        center.now = expiry.addingTimeInterval(-20 * 3600)
        center.requests = center.requests.filter { $0.value.date > center.now }
        await relaunched.reconcile(accounts: [second], now: center.now).value
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(center.attempts, 6)
        await relaunched.reconcile(accounts: [], now: center.now).value
        XCTAssertEqual(center.requests, [other.id: other])
    }

    func testClaimCancelsOneEqualExpiryEvenWhenPostClaimRefreshFailsOrAppRestarts() async {
        let store = defaults()
        let center = Center(start)
        let expiry = start.addingTimeInterval(48 * 3600)
        let account = ("one", "A", snapshot(count: 2, expiries: [expiry, expiry], observed: start))
        let scheduler = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: store)
        await scheduler.reconcile(accounts: [account], now: start).value
        scheduler.consumed(account: "one", expiry: expiry, creditID: "first", remaining: 1, at: start)
        await scheduler.reconcile(accounts: [account], now: start).value
        XCTAssertEqual(center.requests.count, 2)
        let relaunched = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: store)
        await relaunched.reconcile(accounts: [account], now: start).value
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(center.attempts, 4)
        relaunched.consumed(account: "one", expiry: expiry, creditID: "first", remaining: 1, at: start)
        await relaunched.reconcile(accounts: [account], now: start).value
        XCTAssertEqual(center.requests.count, 2)
        relaunched.consumed(account: "one", expiry: expiry, creditID: "second", remaining: 1, at: start)
        await relaunched.reconcile(accounts: [account], now: start).value
        XCTAssertTrue(center.requests.isEmpty)
        let fresh = ("one", "A", snapshot(count: 2, expiries: [expiry, expiry], observed: start.addingTimeInterval(1)))
        await relaunched.reconcile(accounts: [fresh], now: start).value
        XCTAssertEqual(center.requests.count, 4)
    }

    func testDisablingWhileSubmissionIsPendingKeepsOtherNotifications() async {
        let center = Center(start)
        let expiry = start.addingTimeInterval(48 * 3600)
        let other = ScheduledReminder(id: "quota-reset.other", date: expiry, title: "", subtitle: "", body: "")
        center.requests[other.id] = other
        let submitting = expectation(description: "시스템에 예약 요청")
        var resume: CheckedContinuation<Void, Never>?
        let scheduler = ScheduledReminders(
            prefix: CodexCreditExpiryReminders.prefix, now: { center.now }, pending: { Array(center.requests.values) },
            schedule: { request, current in
                await withCheckedContinuation {
                    resume = $0
                    submitting.fulfill()
                }
                if current() { center.requests[request.id] = request }
            }, remove: { ids in ids.forEach { center.requests.removeValue(forKey: $0) } })
        let reminders = CodexCreditExpiryReminders(scheduler: scheduler, defaults: defaults())
        let account = ("a", "A", snapshot(count: 1, expiries: [expiry]))
        let active = reminders.reconcile(accounts: [account], now: start)
        await fulfillment(of: [submitting], timeout: 3)
        let disabled = reminders.reconcile(accounts: [], now: start)
        resume?.resume()
        await active.value
        await disabled.value
        XCTAssertEqual(center.requests, [other.id: other])
    }

    func testUnknownExpiryZeroInventoryAndPastThresholdsAreSkipped() async {
        let center = Center(start)
        let scheduler = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults())
        let shortly = start.addingTimeInterval(2 * 3600)
        let accounts = [
            ("no-dates", "A", snapshot(count: 2, expiries: [])),
            ("used", "B", snapshot(count: 0, expiries: [start.addingTimeInterval(172800)])),
            ("soon", "C", snapshot(count: 3, expiries: [start, shortly, start.addingTimeInterval(13 * 3600)]))
        ]
        await scheduler.reconcile(accounts: accounts, now: start).value
        XCTAssertEqual(center.requests.count, 1)
        XCTAssertEqual(center.requests.values.first?.date, start.addingTimeInterval(3600))
    }

    func testSystemRequestUsesTheExactAbsoluteDateAndTapGroup() throws {
        let reminder = ScheduledReminder(id: "demo", date: start, title: "Expiry", subtitle: "A", body: "12h")
        let request = reminder.request
        let trigger = try XCTUnwrap(request.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.timeZone, TimeZone.gmt)
        XCTAssertEqual(trigger.dateComponents.date, start)
        XCTAssertEqual(request.identifier, "demo")
        XCTAssertEqual(request.content.title, "Expiry")
        XCTAssertEqual(request.content.subtitle, "A")
        XCTAssertEqual(request.content.body, "12h")
        XCTAssertEqual(request.content.threadIdentifier, "openusage")
    }

    func testRejectedReservationCanBeRetriedAndSoonestIsSubmittedFirst() async {
        let center = Center(start)
        center.capacity = 1
        let scheduler = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults())
        let expiry = start.addingTimeInterval(48 * 3600)
        let account = ("one", "A", snapshot(count: 1, expiries: [expiry]))
        await scheduler.reconcile(accounts: [account], now: start).value
        XCTAssertEqual(center.requests.values.first?.date, expiry.addingTimeInterval(-86400))
        center.capacity = 2
        await scheduler.reconcile(accounts: [account], now: start).value
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(center.attempts, 3)
    }

    func testTemporaryFailurePreservesKnownDateAndAuthFailurePersistsCancellation() async {
        let defaults = defaults()
        let center = Center(start)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var reading = snapshot(count: 1, expiries: [start.addingTimeInterval(172800)])
        reading.liveQuotaObservedAt = start
        let cache = ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false, now: { center.now })
        cache.store(reading, producedByIdentityKey: "a")
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        let auth = ProviderSnapshot.error(provider: provider, message: "sign in", category: .authExpired)
        let runtime = TogglingProviderRuntime(provider: provider, descriptors: [], first: transient, second: auth)
        func launch() -> WidgetDataStore {
            let store = WidgetDataStore(
                registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache,
                defaults: defaults, now: { center.now }, notificationSettings: { settings },
                providerIdentityKeys: ["codex": "a"])
            store.configureCodexCreditReminders(scheduler: center.scheduler())
            return store
        }
        let store = launch()
        let firstFailure = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(firstFailure, .failed)
        XCTAssertEqual(center.requests.count, 2)
        let secondFailure = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(secondFailure, .failed)
        let reloaded = launch()
        // 생명주기 콜백이 생성한 예약 작업의 현재 결과 확인.
        await reloaded.refreshAll(force: true)
        XCTAssertTrue(center.requests.isEmpty)
        XCTAssertEqual(center.attempts, 2)
    }

    func testAccountInvalidationCancelsUntilFreshProtectedIdentityIsReadAgain() async {
        let defaults = defaults()
        let center = Center(start)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var reading = snapshot(count: 1, expiries: [start.addingTimeInterval(172800)])
        reading.liveQuotaObservedAt = start
        var second = reading
        second.liveQuotaObservedAt = start.addingTimeInterval(60)
        let runtime = TogglingProviderRuntime(provider: provider, descriptors: [], first: reading, second: second)
        let cache = ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false, now: { center.now })
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache,
            defaults: defaults, now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: ["codex": "account-a"])
        let firstSchedule = expectation(description: "첫 예약")
        let restored = expectation(description: "계정 재확인 후 복구")
        var didSchedule = false
        let cancelled = expectation(description: "해당 계정의 기존 두 예약 취소")
        let scheduler = ScheduledReminders(
            prefix: CodexCreditExpiryReminders.prefix, now: { center.now }, pending: { Array(center.requests.values) },
            schedule: { request, current in
                guard current() else { return }
                center.requests[request.id] = request
                if center.requests.count == 2 {
                    if didSchedule { restored.fulfill() } else { firstSchedule.fulfill() }
                    didSchedule = true
                }
            },
            remove: { ids in
                ids.forEach { center.requests.removeValue(forKey: $0) }
                if center.requests.isEmpty { cancelled.fulfill() }
            })
        store.configureCodexCreditReminders(scheduler: scheduler)
        _ = await store.refresh(providerID: "codex", force: true)
        await fulfillment(of: [firstSchedule], timeout: 3)
        XCTAssertEqual(center.requests.count, 2)
        store.invalidateAuthentication(for: "codex")
        await fulfillment(of: [cancelled], timeout: 3)
        XCTAssertTrue(center.requests.isEmpty)
        center.now = start.addingTimeInterval(60)
        _ = await store.refresh(providerID: "codex", force: true)
        await fulfillment(of: [restored], timeout: 3)
        XCTAssertEqual(center.requests.count, 2)
    }

    func testSettingDefaultsOffPersistsAndIsIndependentOfResetWatch() {
        let store = defaults()
        let settings = NotificationSettingsStore(defaults: store)
        XCTAssertFalse(settings.codexCreditExpiry)
        var callbacks = 0
        settings.onCodexCreditExpiryChange = { callbacks += 1 }
        settings.codexCreditExpiry = true
        XCTAssertTrue(settings.anyEnabled)
        XCTAssertFalse(settings.codexResetWatch)
        XCTAssertTrue(NotificationSettingsStore(defaults: store).codexCreditExpiry)
        settings.codexCreditExpiry = false
        XCTAssertFalse(settings.anyEnabled)
        XCTAssertEqual(callbacks, 2)
    }
}
