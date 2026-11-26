import Foundation
import XCTest
@testable import Egasu

@MainActor
final class QuotaResetReminderScopeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let unsupported = [
        "kiro", "qwencloud", "devin", "grok", "kimi", "zai", "copilot", "antigravity", "opencode"
    ]

    func testSupportedProviderFamiliesRequireAVerifiedAccount() {
        let reset = now.addingTimeInterval(172_800)
        for id in ["claude", "claude@profile", "codex", "codex@profile", "cursor"] {
            let runtime = runtime(id: id, now: now, reset: reset)
            var snapshot = runtime.snapshot
            snapshot.producedByIdentityKey = "verified-account"
            func reminders(identity: String?) -> [ScheduledReminder] {
                QuotaResetReminders.reminders(
                    for: snapshot, descriptors: runtime.widgetDescriptors, account: id, now: now,
                    accountIdentity: identity)
            }
            XCTAssertTrue(reminders(identity: nil).isEmpty, id)
            XCTAssertEqual(reminders(identity: "verified-account").count, 4, id)
        }
    }

    func testUnsupportedProvidersNeverScheduleWeeklyOrMonthlyReminders() {
        let reset = now.addingTimeInterval(172_800)
        for id in unsupported {
            let runtime = runtime(id: id, now: now, reset: reset)
            let requests = QuotaResetReminders.reminders(
                for: runtime.snapshot, descriptors: runtime.widgetDescriptors, account: id, now: now,
                accountIdentity: "verified-account")
            XCTAssertTrue(requests.isEmpty, id)
        }
    }

    func testStartupCancelsUnsupportedPendingRemindersWithCachedQuota() async throws {
        let suite = "QuotaResetReminderScopeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let now = Date.now
        let reset = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let providers = unsupported.map { runtime(id: $0, now: now, reset: reset) }
        let identity = "fixture-account"
        let writer = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        for runtime in providers {
            writer.store(runtime.snapshot, producedByIdentityKey: identity)
        }
        let store = WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite), defaults: defaults,
            providerIdentityKeys: Dictionary(uniqueKeysWithValues: unsupported.map { ($0, identity) }))
        XCTAssertEqual(Set(store.localSnapshots.keys), Set(unsupported).subtracting(["opencode"]))

        let oldRequests = providers.flatMap { runtime in
            runtime.widgetDescriptors.flatMap { descriptor in
                [24, 12].map { hours in
                    ScheduledReminder(
                        id: "openusage.quota-reset.\(descriptor.id).\(Int(reset.timeIntervalSince1970)).\(hours)",
                        date: reset.addingTimeInterval(-Double(hours * 3600)),
                        title: "", subtitle: "", body: "")
                }
            }
        }
        let credit = ScheduledReminder(
            id: "egasu.codex-credit-expiry.test", date: reset, title: "", subtitle: "", body: "")
        let cancelled = expectation(description: "지원 범위에 없는 한도의 시작 예약 취소")
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, now: { now }, pending: { oldRequests + [credit] },
            schedule: { item, _ in XCTFail("지원 범위에 없는 알림을 예약했습니다. \(item.id)") },
            remove: { ids in
                XCTAssertEqual(Set(ids), Set(oldRequests.map(\.id)))
                cancelled.fulfill()
            })
        let enablement = ProviderEnablementStore(defaults: defaults)
        let observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer.observe(settings: settings, dataStore: store, enablement: enablement)
        await fulfillment(of: [cancelled], timeout: 3)
    }

    func testClaudeRegistrationKeepsElapsedReminderForTheSameAccount() async throws {
        let identity = "account-a|organization-a"
        try await checkRemindersAfterIdentityChange(
            family: "claude", identity: identity,
            liveKey: UsageTimerObservation.accountKey(family: "claude", identity: identity))
    }

    func testCodexRegistrationKeepsElapsedReminderForTheSameAccount() async throws {
        let user = try codexUser(subject: "user-a")
        try await checkRemindersAfterIdentityChange(
            family: "codex", identity: user.workspace, liveKey: user.key, codexBinding: user.binding)
    }

    func testDifferentCodexUsersInSameWorkspaceHaveIndependentReminders() async throws {
        let first = try codexUser(subject: "user-a")
        let second = try codexUser(subject: "user-b")
        XCTAssertEqual(first.workspace, second.workspace)
        XCTAssertNotEqual(first.key, second.key)
        try await checkRemindersAfterIdentityChange(
            family: "codex", identity: first.workspace, liveKey: first.key, codexBinding: first.binding,
            replacementBinding: second.binding)
    }

    func testSharedCodexReadingsUseProviderNameWithAnotherUsersRegisteredLabel() async throws {
        for source in [CodexAuthState.Source.file(path: "/fixture/auth.json"), .keychain, nil] {
            try await checkCodexReminderName(card: "codex", subject: "user-b", source: source, name: "Codex")
        }
    }

    func testSavedCodexReadingKeepsTheProvenProfilesName() async throws {
        let card = AccountUsageCardPlanner.cardID(family: "codex", profileID: "alice")
        try await checkCodexReminderName(
            card: card, subject: "user-a", source: .accountSnapshot(profileID: "alice"), name: "Codex — Alice")
    }

    private func checkCodexReminderName(
        card: String, subject: String, source: CodexAuthState.Source?, name: String
    ) async throws {
        let suite = "QuotaResetReminderScopeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let enablement = ProviderEnablementStore(defaults: defaults)
        let now = Date.now
        let user = try codexUser(subject: subject, source: source ?? .keychain)
        let fixture = runtime(id: card, now: now, reset: now.addingTimeInterval(172_800))
        let weekly = try XCTUnwrap(fixture.widgetDescriptors.first)
        var snapshot = fixture.snapshot
        snapshot.displayName = "Codex"
        snapshot.liveQuotaAccountKey = user.key
        snapshot.liveQuotaObservedAt = now
        snapshot.codexResetClaimBinding = source == nil ? nil : user.binding
        snapshot.codexSwitchIdentity = user.workspace
        let runtime = TestProviderRuntime(provider: fixture.provider, descriptors: [weekly], snapshot: snapshot)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime]), providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false), defaults: defaults,
            providerIdentityKeys: [card: user.workspace], resolveDisplayName: { _ in "Codex — Alice" })
        let scheduled = expectation(description: "Codex의 두 알림 부제")
        scheduled.expectedFulfillmentCount = 2
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, now: { now }, pending: { [] },
            schedule: { item, isCurrent in
                guard isCurrent() else { return }
                XCTAssertEqual(item.subtitle, L10n.metrics("%@ %@", name, weekly.sample.localizedTitle))
                scheduled.fulfill()
            },
            remove: { _ in })
        let observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer.observe(settings: settings, dataStore: store, enablement: enablement)
        await store.refresh(providerID: card, force: true)
        await fulfillment(of: [scheduled], timeout: 3)
    }

    private func codexUser(
        subject: String, source: CodexAuthState.Source = .keychain
    ) throws -> (workspace: String, key: String, binding: CodexResetClaimBinding) {
        let json = try JSONSerialization.data(withJSONObject: ["sub": subject])
        let auth = CodexAuth(
            tokens: CodexTokens(accessToken: "e30.\(json.base64EncodedString()).signature", accountID: "workspace-a"))
        let workspace = try XCTUnwrap(DefaultAccountObserver.codexIdentity(for: auth)?.identityKey)
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(auth: auth, source: source)))
        return (workspace, try XCTUnwrap(binding.verifiedAccountKey), binding)
    }

    private func checkRemindersAfterIdentityChange(
        family: String, identity: String, liveKey: String, codexBinding: CodexResetClaimBinding? = nil,
        replacementBinding: CodexResetClaimBinding? = nil
    ) async throws {
        let suite = "QuotaResetReminderScopeTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.weeklyMonthlyResetReminders = true
        let enablement = ProviderEnablementStore(defaults: defaults)
        let now = Date.now
        let firstReset = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 86_100)
        let extendedReset = firstReset.addingTimeInterval(600)
        let switchesUser = replacementBinding != nil
        let updatedKey = try replacementBinding.map { try XCTUnwrap($0.verifiedAccountKey) } ?? liveKey
        func provider(reset: Date, key: String, binding: CodexResetClaimBinding?) -> TestProviderRuntime {
            let fixture = runtime(id: family, now: now, reset: reset)
            var snapshot = fixture.snapshot
            snapshot.liveQuotaAccountKey = key
            snapshot.liveQuotaObservedAt = now
            snapshot.codexResetClaimBinding = binding
            snapshot.codexSwitchIdentity = binding == nil ? nil : identity
            return TestProviderRuntime(
                provider: fixture.provider, descriptors: Array(fixture.widgetDescriptors.prefix(1)), snapshot: snapshot)
        }

        let first = provider(reset: firstReset, key: liveKey, binding: codexBinding)
        let next = provider(reset: extendedReset, key: updatedKey, binding: replacementBinding ?? codexBinding)
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([first]), providers: [first],
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false), defaults: defaults,
            providerIdentityKeys: switchesUser ? [family: identity] : [:])
        let initial = expectation(description: "계정 변경 전 12시간 예약")
        let updated = expectation(description: "계정 변경 후 연장된 12시간 예약")
        var pending: [String: ScheduledReminder] = [:]
        let scheduler = ScheduledReminders(
            prefix: QuotaResetReminders.prefix, now: { now }, pending: { Array(pending.values) },
            schedule: { item, isCurrent in
                guard isCurrent() else { return }
                pending[item.id] = item
                switch item.date {
                case firstReset.addingTimeInterval(-43_200): initial.fulfill()
                case extendedReset.addingTimeInterval(-43_200): updated.fulfill()
                case extendedReset.addingTimeInterval(-86_400) where switchesUser: break
                default: XCTFail("같은 계정의 지난 24시간 알림을 다시 예약했습니다.")
                }
            },
            remove: { ids in ids.forEach { pending[$0] = nil } })
        let observer = QuotaResetReminders(scheduler: scheduler, defaults: defaults)
        observer.observe(settings: settings, dataStore: store, enablement: enablement)
        store.onFreshSnapshot = { [weak observer] snapshot, _, _ in observer?.receivedSnapshot(snapshot) }
        store.onQuotaInvalidated = { [weak observer] ids in observer?.invalidate(ids) }
        await store.refresh(providerID: family, force: true)
        await fulfillment(of: [initial], timeout: 3)
        let previous = try XCTUnwrap(pending.values.first)
        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([next]), providers: [next], identityKeys: [family: identity])
        await store.refresh(providerID: family, force: true)
        await fulfillment(of: [updated], timeout: 3)
        let expectedLeadTimes = switchesUser ? [86_400.0, 43_200] : [43_200.0]
        XCTAssertEqual(
            pending.values.map(\.date).sorted(), expectedLeadTimes.map { extendedReset.addingTimeInterval(-$0) })
        let firstKey = previous.id.split(separator: ".").dropLast(2)
        let updatedKeys = Set(pending.keys.map { $0.split(separator: ".").dropLast(2) })
        if switchesUser {
            XCTAssertEqual(updatedKeys.count, 1)
            XCTAssertFalse(updatedKeys.contains(firstKey))
        } else {
            XCTAssertEqual(updatedKeys, [firstKey])
        }
    }

    private func runtime(id: String, now: Date, reset: Date) -> TestProviderRuntime {
        let provider = Provider(id: id, displayName: id, icon: .providerMark(id))
        let windows: [(String, Int)] = [("Weekly", MetricPeriod.weekMs), ("Monthly", MetricPeriod.monthMs)]
        let descriptors = windows.map { label, _ in
            WidgetDescriptor.percent(id: "\(id).\(label.lowercased())", provider: provider, title: label)
                .exportingLimit(label.lowercased(), unit: "percent")
        }
        let lines = windows.map { label, duration in
            MetricLine.progress(
                label: label, used: 20, limit: 100, format: .percent, resetsAt: reset, periodDurationMs: duration)
        }
        let snapshot = ProviderSnapshot.make(provider: provider, plan: nil, lines: lines, refreshedAt: now)
        return TestProviderRuntime(provider: provider, descriptors: descriptors, snapshot: snapshot)
    }
}
