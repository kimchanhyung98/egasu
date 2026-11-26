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

    private func snapshot(count: Int, expiries: [Date], observed: Date? = nil, card: String = "codex")
        -> ProviderSnapshot
    {
        ProviderSnapshot(
            providerID: card, displayName: "Codex",
            lines: [
                .values(
                    label: "Rate Limit Resets", values: [MetricValue(number: Double(count), kind: .count)],
                    expiriesAt: expiries)
            ],
            quotaObservedAt: observed)
    }

    private func auth(
        subject: String, workspace: String = "workspace", source: CodexAuthState.Source, generation: Int = 1
    ) throws -> CodexAuthState {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject, "iat": generation])
        let tokens = CodexTokens(accessToken: "e30.\(payload.base64EncodedString()).fixture", accountID: workspace)
        return CodexAuthState(auth: CodexAuth(tokens: tokens), source: source)
    }

    private func verified(_ snapshot: ProviderSnapshot, using state: CodexAuthState) throws -> ProviderSnapshot {
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: state))
        var reading = snapshot
        reading.codexResetClaimBinding = binding
        reading.liveQuotaAccountKey = try XCTUnwrap(binding.verifiedAccountKey)
        reading.liveQuotaObservedAt = snapshot.quotaObservedAt ?? start
        reading.codexSwitchIdentity = try XCTUnwrap(DefaultAccountObserver.codexIdentity(for: state.auth)?.identityKey)
        return reading
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
        var account = ("one", "A", snapshot(count: 2, expiries: [expiry, expiry], observed: start))
        let scheduler = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: store)
        await scheduler.reconcile(accounts: [account], now: start).value
        scheduler.consumed(account: "one", expiry: expiry, creditID: "first", remaining: 1, at: start)
        account.2.refreshedAt = start.addingTimeInterval(1)
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

    func testTemporaryFailurePreservesKnownDateAndAuthFailurePersistsCancellation() async throws {
        let defaults = defaults()
        let center = Center(start)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let reading = try verified(
            snapshot(count: 1, expiries: [start.addingTimeInterval(172800)]),
            using: auth(subject: "user-a", workspace: "a", source: .keychain))
        let cache = ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false, now: { center.now })
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        let auth = ProviderSnapshot.error(provider: provider, message: "sign in", category: .authExpired)
        let runtime = SequenceProviderRuntime(
            provider: provider, descriptors: [], snapshots: [reading, transient, auth])
        func launch() -> WidgetDataStore {
            let store = WidgetDataStore(
                registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache,
                defaults: defaults, now: { center.now }, notificationSettings: { settings },
                providerIdentityKeys: ["codex": "a"])
            store.configureCodexCreditReminders(scheduler: center.scheduler())
            return store
        }
        let store = launch()
        _ = await store.refresh(providerID: "codex", force: true)
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

    func testAccountInvalidationCancelsUntilFreshProtectedIdentityIsReadAgain() async throws {
        let defaults = defaults()
        let center = Center(start)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let reading = try verified(
            snapshot(count: 1, expiries: [start.addingTimeInterval(172800)]),
            using: auth(subject: "user-a", workspace: "account-a", source: .keychain))
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

    func testUnknownLaunchIdentityDoesNotRestoreConsumedOrOtherCachedCredits() async throws {
        try await checkCachedCreditsOnLaunch(catalogIdentity: nil)
    }

    func testRegisteredWorkspaceCancelsCachedCreditsUntilTheCurrentUserIsRead() async throws {
        try await checkCachedCreditsOnLaunch(catalogIdentity: "workspace")
    }

    private func checkCachedCreditsOnLaunch(catalogIdentity: String?) async throws {
        let defaults = defaults()
        let center = Center(start)
        let expiry = start.addingTimeInterval(172_800)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let cached = try verified(
            snapshot(count: 2, expiries: [expiry, expiry], observed: start),
            using: auth(subject: "user-a", source: .keychain))
        let firstKey = try XCTUnwrap(cached.liveQuotaAccountKey)
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { center.now })
        cache.store(cached, producedByIdentityKey: "workspace")
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
        reminders.consumed(account: firstKey, expiry: expiry, creditID: "used", remaining: 1, at: start)
        await reminders.reconcile(accounts: [(firstKey, "A", cached)], now: start).value
        XCTAssertEqual(center.requests.count, 2)

        let provider = CodexProvider.makeProvider()
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        let fresh = try verified(
            snapshot(count: 1, expiries: [expiry], observed: start.addingTimeInterval(1)),
            using: auth(subject: "user-b", source: .keychain))
        let runtime = TogglingProviderRuntime(provider: provider, descriptors: [], first: transient, second: fresh)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { center.now }),
            defaults: defaults, now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: catalogIdentity.map { ["codex": $0] } ?? [:])
        let profiles = AccountProfilesStore(defaults: defaults)
        _ = try profiles.add(family: "codex", label: "Previous user", identityKey: "workspace")
        let cardProfiles = AppContainer.accountProfileIDsByCardID(
            assembly: ProviderAccountAssembly(identityKeysByCard: catalogIdentity.map { ["codex": $0] } ?? [:]),
            profiles: profiles)
        AppContainer.configureQuotaNotificationNames(
            dataStore: store, accounts: ProviderAccountsStore(defaults: defaults), profiles: profiles
        ) { cardProfiles[$0] }
        XCTAssertNotNil(store.localSnapshots["codex"])
        store.configureCodexCreditReminders(scheduler: center.scheduler())
        let failed = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(failed, .failed)
        XCTAssertTrue(center.requests.isEmpty)
        let recovered = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(recovered, .refreshed)
        let deadline = ContinuousClock.now + .seconds(2)
        while center.requests.count != 2 && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(center.requests.count, 2)
        XCTAssertEqual(Set(center.requests.values.map(\.subtitle)), ["Codex"])
        let beforeKnownAccount = Set(center.requests.keys)
        await reminders.reconcile(accounts: [(try XCTUnwrap(fresh.liveQuotaAccountKey), "Codex", fresh)], now: start)
            .value
        XCTAssertEqual(Set(center.requests.keys), beforeKnownAccount)
    }

    func testCreditReceiptsAndNamesStayWithTheUserWhenTheWorkspaceIsShared() async throws {
        let defaults = defaults()
        let center = Center(start)
        let expiry = start.addingTimeInterval(172_800)
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let profiles = AccountProfilesStore(defaults: defaults)
        let profile = try profiles.add(family: "codex", label: "Alice", identityKey: "workspace")
        let base = snapshot(count: 2, expiries: [expiry, expiry], observed: start)
        let first = try verified(base, using: auth(subject: "alice", source: .file(path: "/fixture/auth.json")))
        let rotated = try verified(base, using: auth(subject: "alice", source: .keychain, generation: 2))
        let second = try verified(base, using: auth(subject: "bob", source: .file(path: "/fixture/auth.json")))
        let keychain = try verified(base, using: auth(subject: "bob", source: .keychain))
        let runtime = SequenceProviderRuntime(
            provider: CodexProvider.makeProvider(), descriptors: [], snapshots: [first, rotated, second, keychain])
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false),
            defaults: defaults, now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: ["codex": "workspace"])
        AppContainer.configureQuotaNotificationNames(
            dataStore: store, accounts: ProviderAccountsStore(defaults: defaults), profiles: profiles
        ) { _ in profile.id }
        store.configureCodexCreditReminders(scheduler: center.scheduler())

        func checkCount(_ count: Int, line: UInt = #line) async {
            let deadline = ContinuousClock.now + .seconds(2)
            while center.requests.count != count && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(center.requests.count, count, line: line)
        }

        _ = await store.refresh(providerID: "codex", force: true)
        await checkCount(4)
        let aliceIDs = Set(center.requests.keys)
        store.codexCreditsUnavailable(
            cardID: "codex",
            credits: .credit(
                .init(
                    binding: try XCTUnwrap(first.codexResetClaimBinding), expiry: expiry, creditID: "used",
                    remainingAtExpiry: 1)))
        await checkCount(2)
        let remainingAliceIDs = Set(center.requests.keys)
        _ = await store.refresh(providerID: "codex", force: true)
        await checkCount(2)
        XCTAssertEqual(Set(center.requests.keys), remainingAliceIDs)
        _ = await store.refresh(providerID: "codex", force: true)
        await checkCount(4)
        let bobIDs = Set(center.requests.keys)
        XCTAssertTrue(bobIDs.isDisjoint(with: aliceIDs))
        XCTAssertEqual(Set(center.requests.values.map(\.subtitle)), ["Codex"])
        _ = await store.refresh(providerID: "codex", force: true)
        await checkCount(4)
        XCTAssertEqual(Set(center.requests.keys), bobIDs)
        XCTAssertEqual(Set(center.requests.values.map(\.subtitle)), ["Codex"])
    }

    func testUnavailableCreditCancelsOnlyConfirmedReservationsWhenUsageRefreshFails() async throws {
        let expiry = start.addingTimeInterval(172_800)
        let seconds = Int(expiry.timeIntervalSince1970)
        let two = Data(
            """
            {"available_count":2,"credits":[{"id":"one","expires_at":\(seconds)},{"id":"two","expires_at":\(seconds)}]}
            """.utf8)
        let partial = Data(
            """
            {"available_count":2,"credits":[{"id":"one","expires_at":\(seconds)}]}
            """.utf8)
        let undated = Data(
            """
            {"available_count":2,"credits":[{"id":"one","expires_at":\(seconds)},{"id":"two"}]}
            """.utf8)
        let empty = Data(#"{"available_count":0,"credits":[]}"#.utf8)
        let incomplete = Data(#"{"available_count":2,"credits":[]}"#.utf8)
        let profileID = UUID().uuidString
        let card = AccountUsageCardPlanner.cardID(family: "codex", profileID: profileID)
        let state = try auth(subject: "user-a", workspace: "account-a", source: .accountSnapshot(profileID: profileID))
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: state))
        let single = Data(
            """
            {"available_count":1,"credits":[{"id":"one","expires_at":\(seconds)}]}
            """.utf8)
        let cases = [
            (empty, 200, 0), (single, 200, 0), (two, 200, 1), (partial, 200, 1),
            (undated, 200, 1), (incomplete, 200, 2), (empty, 503, 2)
        ]
        for (body, status, remaining) in cases {
            let defaults = defaults()
            let center = Center(start)
            let settings = NotificationSettingsStore(defaults: defaults)
            settings.codexCreditExpiry = true
            let provider = CodexProvider.makeProvider(id: card)
            let reading = try verified(
                snapshot(count: 2, expiries: [expiry, expiry], observed: start, card: card), using: state)
            let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
            let runtime = TogglingProviderRuntime(
                provider: provider, descriptors: [], first: reading, second: transient)
            let store = WidgetDataStore(
                registry: WidgetRegistry.from([runtime]), providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false),
                defaults: defaults, now: { center.now }, notificationSettings: { settings },
                providerIdentityKeys: [card: "account-a"])
            let profiles = AccountProfilesStore(defaults: defaults)
            let profile = try profiles.add(
                family: "codex", label: "Current user", identityKey: "account-a", id: profileID)
            AppContainer.configureQuotaNotificationNames(
                dataStore: store, accounts: ProviderAccountsStore(defaults: defaults), profiles: profiles
            ) { _ in profile.id }
            store.configureCodexCreditReminders(scheduler: center.scheduler())
            _ = await store.refresh(providerID: card, force: true)
            let deadline = ContinuousClock.now + .seconds(2)
            while center.requests.count != 4 && ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertEqual(center.requests.count, 4)
            let name = L10n.metrics("%@ — %@", "Codex", profile.label)
            XCTAssertEqual(Set(center.requests.values.map(\.subtitle)), [name])
            let http = RoutingHTTPClient { request in
                request.method == "POST"
                    ? HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"no_credit"}"#.utf8))
                    : HTTPResponse(statusCode: status, headers: [:], body: body)
            }
            let service = CodexResetClaimService(
                usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in state },
                refreshAfterClaim: { _ in
                    let result = await store.refresh(providerID: card, force: true)
                    XCTAssertEqual(result, .failed)
                })
            service.onUnavailable = { store.codexCreditsUnavailable(cardID: card, credits: $0) }
            let result = await service.claim(creditExpiringAt: expiry, redeemRequestID: "selection", binding: binding)
            XCTAssertEqual(result, remaining == 2 ? .failed : .noCredit)
            XCTAssertEqual(center.requests.count, remaining * 2)
            let restarted = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
            await restarted.reconcile(
                accounts: [(try XCTUnwrap(binding.verifiedAccountKey), "A", reading), ("account-b", "B", reading)],
                now: start
            ).value
            XCTAssertEqual(center.requests.values.filter { $0.subtitle == "A" }.count, remaining * 2)
            XCTAssertEqual(center.requests.values.filter { $0.subtitle == "B" }.count, 4)
        }
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
