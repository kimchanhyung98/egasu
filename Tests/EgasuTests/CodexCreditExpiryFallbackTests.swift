import XCTest
@testable import Egasu

@MainActor
final class CodexCreditExpiryFallbackTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private var expiry: Date { start.addingTimeInterval(48 * 3600) }

    private typealias Account = (key: String, name: String, snapshot: ProviderSnapshot)

    @MainActor
    private final class Center {
        var now: Date
        var requests: [String: ScheduledReminder] = [:]
        var submissions = 0
        var nextPendingRead: XCTestExpectation?
        var posted: XCTestExpectation?

        init(now: Date) {
            self.now = now
        }

        var creditRequests: [String: ScheduledReminder] {
            requests.filter { $0.key.hasPrefix(CodexCreditExpiryReminders.prefix) }
        }

        func scheduler() -> ScheduledReminders {
            ScheduledReminders(
                prefix: CodexCreditExpiryReminders.prefix,
                now: { self.now },
                pending: {
                    let expectation = self.nextPendingRead
                    self.nextPendingRead = nil
                    expectation?.fulfill()
                    return Array(self.requests.values)
                },
                schedule: { reminder, isCurrent in
                    guard isCurrent() else { return }
                    self.requests[reminder.id] = reminder
                    self.submissions += 1
                    self.posted?.fulfill()
                },
                remove: { ids in
                    for id in ids { self.requests.removeValue(forKey: id) }
                }
            )
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "EgasuTests.CreditExpiryFallback.\(UUID())"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func account(
        count: Int?, expiries: [Date]? = nil, observedAt: Date, subject: String = "user-a", card: String = "codex"
    ) throws -> Account {
        var usageBody: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 25]]]
        if let count { usageBody["rate_limit_reset_credits"] = ["available_count": count] }
        let usage = HTTPResponse(
            statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: usageBody)
        )
        let dedicated: HTTPResponse
        if let expiries, let count {
            let body: [String: Any] = [
                "available_count": count,
                "credits": expiries.map { ["expires_at": Int($0.timeIntervalSince1970)] }
            ]
            dedicated = HTTPResponse(
                statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body)
            )
        } else {
            dedicated = HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let mapped = try CodexUsageMapper.mapUsageResponse(usage, resetCredits: dedicated, now: observedAt)
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject])
        let tokens = CodexTokens(accessToken: "e30.\(payload.base64EncodedString()).fixture", accountID: "workspace")
        let auth = CodexAuthState(auth: CodexAuth(tokens: tokens), source: .keychain)
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: auth))
        let key = try XCTUnwrap(binding.verifiedAccountKey)
        var snapshot = ProviderSnapshot(
            providerID: card, displayName: "Codex", lines: mapped.lines, refreshedAt: observedAt,
            isDegraded: expiries == nil ? true : nil, liveQuotaObservedAt: observedAt, liveQuotaAccountKey: key,
            quotaObservedAt: observedAt, codexResetClaimBinding: binding
        )
        snapshot.codexSwitchIdentity = try XCTUnwrap(DefaultAccountObserver.codexIdentity(for: auth.auth)?.identityKey)
        return (key, "Codex", snapshot)
    }

    func testCountOnlyFallbackKeepsVerifiedUsersPendingReservations() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let full = try account(count: 1, expiries: [expiry], observedAt: start)
        await reminders.reconcile(accounts: [full], now: center.now).value
        let initial = center.creditRequests
        XCTAssertEqual(initial.count, 2)
        XCTAssertEqual(
            Set(initial.values.map(\.date)),
            [
                expiry.addingTimeInterval(-24 * 3600), expiry.addingTimeInterval(-12 * 3600)
            ])

        center.now = start.addingTimeInterval(60)
        let fallback = try account(count: 1, observedAt: center.now)
        XCTAssertEqual(fallback.key, full.key)
        XCTAssertEqual(
            fallback.snapshot.line(label: "Rate Limit Resets"),
            .values(
                label: "Rate Limit Resets", values: [MetricValue(number: 1, kind: .count, label: "available")]
            ))
        await reminders.reconcile(accounts: [fallback], now: center.now).value

        XCTAssertEqual(center.creditRequests, initial)
        XCTAssertEqual(center.submissions, 2)
    }

    func testRepeatedCountOnlyRefreshKeepsOnlyUnconsumedCreditAtSameExpiry() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let full = try account(count: 2, expiries: [expiry, expiry], observedAt: start)
        await reminders.reconcile(accounts: [full], now: center.now).value
        XCTAssertEqual(center.creditRequests.count, 4)

        center.now = start.addingTimeInterval(60)
        reminders.consumed(account: full.key, expiry: expiry, creditID: "used", remaining: nil, at: center.now)
        await reminders.reconcile(accounts: [full], now: center.now).value
        let unconsumed = center.creditRequests
        XCTAssertEqual(unconsumed.count, 2)

        // 개수만 이전 값으로 돌아와도 사용이 확인된 권은 다시 예약하지 않음.
        for count in [1, 1, 2] {
            center.now = center.now.addingTimeInterval(60)
            let fallback = try account(count: count, observedAt: center.now)
            await reminders.reconcile(accounts: [fallback], now: center.now).value
            XCTAssertEqual(center.creditRequests, unconsumed, "available_count=\(count)")
        }
        XCTAssertEqual(center.submissions, 4)
    }

    func testCountOnlyIncreaseDoesNotRestoreReducedReservationsAtSameExpiry() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let full = try account(count: 2, expiries: [expiry, expiry], observedAt: start)
        await reminders.reconcile(accounts: [full], now: center.now).value
        XCTAssertEqual(center.creditRequests.count, 4)

        center.now = start.addingTimeInterval(60)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        let reduced = center.creditRequests
        XCTAssertEqual(reduced.count, 2)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(
            accounts: [try account(count: 2, observedAt: center.now)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 2)
        XCTAssertEqual(center.creditRequests, reduced)
        XCTAssertEqual(center.submissions, 4)

        center.now = start.addingTimeInterval(180)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
    }

    func testConsumptionAfterCountOnlyReductionCancelsLastReservations() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let full = try account(count: 2, expiries: [expiry, expiry], observedAt: start)
        await reminders.reconcile(accounts: [full], now: center.now).value
        XCTAssertEqual(center.creditRequests.count, 4)

        center.now = start.addingTimeInterval(60)
        let reduced = try account(count: 1, observedAt: center.now)
        await reminders.reconcile(accounts: [reduced], now: center.now).value
        XCTAssertEqual(center.creditRequests.count, 2)

        for _ in 0..<2 {
            center.now = center.now.addingTimeInterval(60)
            reminders.consumed(
                account: full.key, expiry: expiry, creditID: "remaining-credit", remaining: nil, at: center.now
            )
            await reminders.reconcile(accounts: [reduced], now: center.now).value
            XCTAssertTrue(center.creditRequests.isEmpty)
            center.now = center.now.addingTimeInterval(60)
            await reminders.reconcile(
                accounts: [try account(count: 1, observedAt: center.now)], now: center.now
            ).value
            XCTAssertTrue(center.creditRequests.isEmpty)
        }
        XCTAssertEqual(center.submissions, 4)
    }

    func testExplicitRemainingInventoryClampsWithoutSubtractingAnExtraCredit() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let full = try account(count: 1, expiries: [expiry], observedAt: start)
        await reminders.reconcile(accounts: [full], now: center.now).value
        let initial = center.creditRequests
        XCTAssertEqual(initial.count, 2)

        center.now = start.addingTimeInterval(60)
        reminders.consumed(account: full.key, expiry: expiry, creditID: "used", remaining: 1, at: center.now)
        await reminders.reconcile(accounts: [full], now: center.now).value
        XCTAssertEqual(center.creditRequests, initial)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests, initial)
        XCTAssertEqual(center.submissions, 2)
    }

    func testConfirmedZeroPreventsRestoringReservationsFromLaterCountOnlyRefresh() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        await reminders.reconcile(
            accounts: [try account(count: 1, expiries: [expiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = start.addingTimeInterval(60)
        await reminders.reconcile(
            accounts: [try account(count: 0, expiries: [], observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 2)
    }

    func testSwitchingUsersWithinWorkspaceDiscardsPreviousUsersObservedDates() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let original = try account(count: 1, expiries: [expiry], observedAt: start)
        await reminders.reconcile(accounts: [original], now: center.now).value
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = start.addingTimeInterval(60)
        let other = try account(count: 1, observedAt: center.now, subject: "user-b")
        XCTAssertEqual(other.snapshot.providerID, original.snapshot.providerID)
        XCTAssertEqual(other.snapshot.codexSwitchIdentity, original.snapshot.codexSwitchIdentity)
        XCTAssertNotEqual(other.key, original.key)
        await reminders.reconcile(accounts: [other], now: center.now).value
        XCTAssertTrue(center.creditRequests.isEmpty)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 2)
    }

    func testRemovingAllAccountsDiscardsPreviouslyObservedDates() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        await reminders.reconcile(
            accounts: [try account(count: 1, expiries: [expiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 2)

        await reminders.reconcile(accounts: [], now: center.now).value
        XCTAssertTrue(center.creditRequests.isEmpty)

        center.now = start.addingTimeInterval(60)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 2)
    }

    func testNewInstanceDoesNotRestorePreviousRunsDatesFromCountOnlyRefresh() async throws {
        let center = Center(now: start)
        let defaults = makeDefaults()
        let original = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
        await original.reconcile(
            accounts: [try account(count: 1, expiries: [expiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = start.addingTimeInterval(60)
        let restarted = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
        await restarted.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 2)
    }

    func testCountOnlyFallbackKeepsOnlyTheRemainingTwelveHourReservation() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        await reminders.reconcile(
            accounts: [try account(count: 1, expiries: [expiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = expiry.addingTimeInterval(-20 * 3600)
        let future = center.creditRequests.filter { $0.value.date > center.now }
        XCTAssertEqual(future.values.map(\.date), [expiry.addingTimeInterval(-12 * 3600)])
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value

        XCTAssertEqual(center.creditRequests, future)
        XCTAssertEqual(center.submissions, 2)
    }

    func testReducedCountWithDifferentPossibleExpiriesDefersReservations() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let laterExpiry = expiry.addingTimeInterval(24 * 3600)
        await reminders.reconcile(
            accounts: [try account(count: 2, expiries: [expiry, laterExpiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 4)

        center.now = start.addingTimeInterval(60)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(
            accounts: [try account(count: 2, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 4)

        center.now = start.addingTimeInterval(180)
        await reminders.reconcile(
            accounts: [try account(count: 1, expiries: [laterExpiry], observedAt: center.now)], now: center.now
        ).value
        XCTAssertEqual(
            center.creditRequests.values.map(\.date).sorted(),
            [
                laterExpiry.addingTimeInterval(-24 * 3600), laterExpiry.addingTimeInterval(-12 * 3600)
            ])
    }

    func testAliasesUseOnlyLatestQuotaObservationRegardlessOfInputOrder() async throws {
        let laterExpiry = expiry.addingTimeInterval(24 * 3600)
        let catalogID = AccountUsageCardPlanner.cardID(family: "codex", profileID: UUID().uuidString)
        let currentObservation = start.addingTimeInterval(60)
        var old = try account(count: 2, expiries: [expiry, laterExpiry], observedAt: start, card: catalogID)
        old.snapshot.refreshedAt = currentObservation.addingTimeInterval(60)

        for dates in [[laterExpiry], []] {
            let newest = try account(count: dates.count, expiries: dates, observedAt: currentObservation)
            XCTAssertEqual(old.key, newest.key)
            XCTAssertNotEqual(old.snapshot.providerID, newest.snapshot.providerID)
            let expected = dates.flatMap { expiry in
                [expiry.addingTimeInterval(-24 * 3600), expiry.addingTimeInterval(-12 * 3600)]
            }
            for accounts in [[old, newest], [newest, old]] {
                let center = Center(now: old.snapshot.refreshedAt)
                let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
                await reminders.reconcile(accounts: accounts, now: center.now).value
                XCTAssertEqual(center.creditRequests.values.map(\.date).sorted(), expected)
            }
        }
    }

    func testRemovingLatestZeroCardDoesNotRestoreOlderAliasReservations() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let catalogID = AccountUsageCardPlanner.cardID(family: "codex", profileID: UUID().uuidString)
        let old = try account(count: 1, expiries: [expiry], observedAt: start, card: catalogID)
        await reminders.reconcile(accounts: [old], now: center.now).value
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = start.addingTimeInterval(60)
        let newest = try account(count: 0, expiries: [], observedAt: center.now)
        XCTAssertEqual(newest.key, old.key)
        await reminders.reconcile(accounts: [newest], now: center.now).value
        XCTAssertTrue(center.creditRequests.isEmpty)

        let sameTimeAlias = try account(count: 1, expiries: [expiry], observedAt: center.now, card: catalogID)
        await reminders.reconcile(accounts: [sameTimeAlias], now: center.now).value
        XCTAssertTrue(center.creditRequests.isEmpty)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(accounts: [old], now: center.now).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 2)
    }

    func testPartiallyDatedResponseSchedulesOnlyItsExplicitDate() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        let laterExpiry = expiry.addingTimeInterval(24 * 3600)
        await reminders.reconcile(
            accounts: [try account(count: 2, expiries: [expiry, laterExpiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 4)
        let explicitRequests = center.creditRequests.filter {
            $0.value.date == laterExpiry.addingTimeInterval(-24 * 3600)
                || $0.value.date == laterExpiry.addingTimeInterval(-12 * 3600)
        }

        center.now = start.addingTimeInterval(60)
        await reminders.reconcile(
            accounts: [try account(count: 2, expiries: [laterExpiry], observedAt: center.now)], now: center.now
        ).value

        XCTAssertEqual(explicitRequests.count, 2)
        XCTAssertEqual(center.creditRequests, explicitRequests)
        XCTAssertEqual(center.submissions, 4)

        center.now = start.addingTimeInterval(120)
        await reminders.reconcile(
            accounts: [try account(count: 1, observedAt: center.now)], now: center.now
        ).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 4)
    }

    func testRefreshWithoutCreditMetricCancelsPreviousReservations() async throws {
        let center = Center(now: start)
        let reminders = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: makeDefaults())
        await reminders.reconcile(
            accounts: [try account(count: 1, expiries: [expiry], observedAt: start)], now: center.now
        ).value
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = start.addingTimeInterval(60)
        let missing = try account(count: nil, observedAt: center.now)
        XCTAssertNil(missing.snapshot.line(label: "Rate Limit Resets"))
        await reminders.reconcile(accounts: [missing], now: center.now).value
        XCTAssertTrue(center.creditRequests.isEmpty)
        XCTAssertEqual(center.submissions, 2)
    }

    func testDisablingThenEnablingRemindersDoesNotRestoreCountOnlyReservations() async throws {
        let center = Center(now: start)
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let other = ScheduledReminder(id: "quota-reset.other", date: expiry, title: "", subtitle: "", body: "")
        center.requests[other.id] = other
        let fallbackDate = start.addingTimeInterval(60)
        let runtime = TogglingProviderRuntime(
            provider: CodexProvider.makeProvider(), descriptors: [],
            first: try account(count: 1, expiries: [expiry], observedAt: start).snapshot,
            second: try account(count: 1, observedAt: fallbackDate).snapshot
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false, now: { center.now }),
            defaults: defaults, now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: ["codex": "workspace"]
        )
        let startup = expectation(description: "시작 시 기존 예약 확인")
        center.nextPendingRead = startup
        store.configureCodexCreditReminders(scheduler: center.scheduler())
        await fulfillment(of: [startup], timeout: 2)

        let scheduled = expectation(description: "만료 알림 두 건 예약")
        scheduled.expectedFulfillmentCount = 2
        center.posted = scheduled
        let full = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(full, .refreshed)
        await fulfillment(of: [scheduled], timeout: 2)
        center.posted = nil
        let initial = center.requests
        XCTAssertEqual(center.creditRequests.count, 2)

        center.now = fallbackDate
        let degraded = expectation(description: "개수만 받은 사용량 갱신 뒤 기존 예약 확인")
        center.nextPendingRead = degraded
        let fallback = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(fallback, .refreshed)
        await fulfillment(of: [degraded], timeout: 2)
        XCTAssertEqual(center.requests, initial)

        let disabled = expectation(description: "만료 알림을 끈 뒤 기존 예약 확인")
        center.nextPendingRead = disabled
        settings.codexCreditExpiry = false
        await fulfillment(of: [disabled], timeout: 2)
        XCTAssertEqual(center.requests, [other.id: other])

        let enabled = expectation(description: "만료 알림을 다시 켠 뒤 기존 예약 확인")
        center.nextPendingRead = enabled
        settings.codexCreditExpiry = true
        await fulfillment(of: [enabled], timeout: 2)
        XCTAssertEqual(center.requests, [other.id: other])
        XCTAssertEqual(center.submissions, 2)
    }
}
