import Foundation
import XCTest
@testable import Egasu

@MainActor
final class NotificationReminderIntegrationTests: XCTestCase {
    @MainActor
    private final class Center {
        var requests: [String: ScheduledReminder] = [:]
        var reads: [String: Int] = [:]
        var writes: [String: Int] = [:]
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))

        func scheduler(prefix: String) -> ScheduledReminders {
            ScheduledReminders(
                prefix: prefix, now: { self.now },
                pending: {
                    self.reads[prefix, default: 0] += 1
                    return Array(self.requests.values)
                },
                schedule: { item, isCurrent in
                    guard isCurrent() else { return }
                    self.writes[prefix, default: 0] += 1
                    self.requests[item.id] = item
                },
                remove: { ids in ids.forEach { self.requests[$0] = nil } })
        }

        func pending(prefix: String) -> [String: ScheduledReminder] {
            requests.filter { $0.key.hasPrefix(prefix) }
        }
    }

    private let quotaPrefix = QuotaResetReminders.prefix
    private let creditPrefix = CodexCreditExpiryReminders.prefix

    func testBothTogglesReconcileIndependentlyAcrossAllRestartConfigurations() async throws {
        for quota in [false, true] {
            for credit in [false, true] {
                try await checkRestart(quota: quota, credit: credit)
            }
        }
    }

    func testConfirmedCreditCancellationPreservesActualQuotaReservations() async throws {
        let center = Center()
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = try reading(at: center.now)
        let (store, settings) = launch(reading: reading, defaults: defaults, suite: suite, center: center)
        settings.weeklyMonthlyResetReminders = true
        settings.codexCreditExpiry = true
        let outcome = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(outcome, .refreshed)
        await waitFor { center.requests.count == 4 }
        let quotaRequests = center.pending(prefix: quotaPrefix)
        let quotaWrites = center.writes[quotaPrefix]
        XCTAssertEqual(quotaRequests.count, 2)
        let binding = try XCTUnwrap(reading.codexResetClaimBinding)
        store.codexCreditsUnavailable(
            cardID: "codex", credits: .expiry(binding: binding, date: center.now.addingTimeInterval(3 * 86_400)))
        await waitFor { center.pending(prefix: creditPrefix).isEmpty }
        XCTAssertEqual(center.requests, quotaRequests)
        XCTAssertEqual(center.writes[quotaPrefix], quotaWrites)
        XCTAssertTrue(settings.weeklyMonthlyResetReminders)
        XCTAssertTrue(settings.codexCreditExpiry)
    }

    private func checkRestart(quota: Bool, credit: Bool) async throws {
        let center = Center()
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = try reading(at: center.now)
        let unrelated = ScheduledReminder(
            id: "other.notification", date: center.now.addingTimeInterval(345_600), title: "", subtitle: "", body: "")
        center.requests[unrelated.id] = unrelated

        let beforeRestart: [String: ScheduledReminder]
        do {
            let (store, settings) = launch(reading: reading, defaults: defaults, suite: suite, center: center)
            XCTAssertFalse(settings.anyEnabled)
            XCTAssertFalse(settings.weeklyMonthlyResetReminders)
            XCTAssertFalse(settings.codexCreditExpiry)
            settings.weeklyMonthlyResetReminders = true
            settings.codexCreditExpiry = true
            let outcome = await store.refresh(providerID: "codex", force: true)
            XCTAssertEqual(outcome, .refreshed)
            await waitFor { center.requests.count == 5 }

            let creditRequests = center.pending(prefix: creditPrefix)
            let creditWrites = center.writes[creditPrefix]
            XCTAssertEqual(creditRequests.count, 2)
            settings.weeklyMonthlyResetReminders = quota
            if !quota { await waitFor { center.pending(prefix: quotaPrefix).isEmpty } }
            XCTAssertEqual(center.pending(prefix: creditPrefix), creditRequests)
            XCTAssertEqual(center.writes[creditPrefix], creditWrites)

            let quotaRequests = center.pending(prefix: quotaPrefix)
            let quotaWrites = center.writes[quotaPrefix]
            XCTAssertEqual(quotaRequests.count, quota ? 2 : 0)
            settings.codexCreditExpiry = credit
            if !credit { await waitFor { center.pending(prefix: creditPrefix).isEmpty } }
            XCTAssertEqual(center.pending(prefix: quotaPrefix), quotaRequests)
            XCTAssertEqual(center.writes[quotaPrefix], quotaWrites)
            XCTAssertEqual(center.requests[unrelated.id], unrelated)
            beforeRestart = center.requests
        }

        let reads = center.reads
        let (relaunched, restoredSettings) = launch(reading: reading, defaults: defaults, suite: suite, center: center)
        XCTAssertEqual(restoredSettings.weeklyMonthlyResetReminders, quota)
        XCTAssertEqual(restoredSettings.codexCreditExpiry, credit)
        XCTAssertEqual(restoredSettings.anyEnabled, quota || credit)
        let cache = try XCTUnwrap(relaunched.localSnapshots["codex"])
        XCTAssertNil(cache.liveQuotaAccountKey)
        await waitFor {
            center.reads[self.quotaPrefix, default: 0] > reads[self.quotaPrefix, default: 0]
                && center.reads[self.creditPrefix, default: 0] > reads[self.creditPrefix, default: 0]
                && center.requests == [unrelated.id: unrelated]
        }

        let outcome = await relaunched.refresh(providerID: "codex", force: true)
        XCTAssertEqual(outcome, .refreshed)
        await waitFor { center.requests == beforeRestart }
        let deadlines = center.requests.values.filter { $0.id != unrelated.id }.map(\.date).sorted()
        let quotaDates = quota ? [24.0, 36].map { center.now.addingTimeInterval($0 * 3600) } : []
        let creditDates = credit ? [48.0, 60].map { center.now.addingTimeInterval($0 * 3600) } : []
        XCTAssertEqual(deadlines, quotaDates + creditDates)
    }

    private func launch(
        reading: ProviderSnapshot, defaults: UserDefaults, suite: String, center: Center
    ) -> (WidgetDataStore, NotificationSettingsStore) {
        let settings = NotificationSettingsStore(defaults: defaults)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let runtime = TestProviderRuntime(
            provider: CodexProvider.makeProvider(), descriptors: CodexProvider().widgetDescriptors, snapshot: reading)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { center.now }),
            defaults: defaults, isProviderEnabled: { enablement.isEnabled($0) },
            now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: ["codex": "workspace"])
        let quota = QuotaResetReminders(scheduler: center.scheduler(prefix: quotaPrefix), defaults: defaults)
        store.onQuotaInvalidated = { quota.invalidate($0) }
        store.onFreshSnapshot = { snapshot, _, _ in quota.receivedSnapshot(snapshot) }
        store.onRefreshOutcome = { id, outcome, category, _, _ in
            if outcome == .failed { quota.refreshFailed(for: id, category: category) }
        }
        quota.observe(settings: settings, dataStore: store, enablement: enablement)
        store.configureCodexCreditReminders(scheduler: center.scheduler(prefix: creditPrefix))
        return (store, settings)
    }

    private func reading(at now: Date) throws -> ProviderSnapshot {
        let payload = Data(#"{"sub":"fixture-user"}"#.utf8).base64EncodedString()
        let auth = CodexAuth(tokens: CodexTokens(accessToken: "e30.\(payload).signature", accountID: "workspace"))
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(auth: auth, source: .keychain)))
        var reading = ProviderSnapshot.make(
            provider: CodexProvider.makeProvider(), plan: nil,
            lines: [
                .progress(
                    label: "Weekly", used: 20, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval(2 * 86_400), periodDurationMs: MetricPeriod.weekMs),
                .values(
                    label: "Rate Limit Resets", values: [MetricValue(number: 1, kind: .count)],
                    expiriesAt: [now.addingTimeInterval(3 * 86_400)])
            ], refreshedAt: now, liveQuotaObservedAt: now,
            liveQuotaAccountKey: try XCTUnwrap(binding.verifiedAccountKey),
            codexResetClaimBinding: binding)
        reading.codexSwitchIdentity = try XCTUnwrap(DefaultAccountObserver.codexIdentity(for: auth)?.identityKey)
        return reading
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), line: line)
    }
}
