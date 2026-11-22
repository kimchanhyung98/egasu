import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class AccountSwitchRecommendationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ id: String) -> AccountProfile {
        AccountProfile(id: id, family: "codex", label: id, identityKey: id, createdAt: now)
    }

    private func window(_ percent: Double, in seconds: TimeInterval?) -> AccountSwitchQuota.Window {
        .init(percent: percent, reset: seconds.map(now.addingTimeInterval))
    }

    func testAnySingleBasePeriodAtExactly95TriggersWithoutRounding() {
        for period in [AccountSwitchQuota.Period.session, .weekly, .monthly] {
            var quota = AccountSwitchQuota(windows: [period: window(94.99, in: 100)])
            XCTAssertFalse(quota.needsSwitch(at: now))
            quota.windows[period] = window(95, in: 100)
            XCTAssertTrue(quota.needsSwitch(at: now))
            XCTAssertFalse(quota.needsSwitch(at: now.addingTimeInterval(100)))
        }
    }

    func testAnyPeriodAt90ExcludesCandidateAndMonthlyResetDoesNotRankIt() {
        for period in [AccountSwitchQuota.Period.session, .weekly, .monthly] {
            var quota = AccountSwitchQuota(windows: [.session: window(30, in: 7200)])
            quota.windows[period] = window(90, in: 100)
            XCTAssertNil(quota.nextCandidateReset(at: now))
            quota.windows[period] = window(89.99, in: 100)
            XCTAssertEqual(quota.nextCandidateReset(at: now), now.addingTimeInterval(period == .monthly ? 7200 : 100))
        }
        for reset in [nil, 0, -1] as [TimeInterval?] {
            let quota = AccountSwitchQuota(windows: [.session: window(10, in: reset), .monthly: window(20, in: 30)])
            XCTAssertNil(quota.nextCandidateReset(at: now))
        }
    }

    func testCandidateWithEarliestWeeklyOrSessionResetWinsThenDisplayOrderBreaksTies() {
        let current = profile("current")
        let first = profile("first")
        let second = profile("second")
        let profiles = [current, first, second]
        var quotas = [
            current.id: AccountSwitchQuota(windows: [.monthly: window(95, in: nil)]),
            first.id: AccountSwitchQuota(windows: [.session: window(30, in: 7200)]),
            second.id: AccountSwitchQuota(windows: [.session: window(0, in: 18000)])
        ]
        func choice() -> AccountProfile? {
            AccountSwitchRecommendation.choose(current: current, profiles: profiles, at: now) { quotas[$0.id] }?.target
        }
        XCTAssertEqual(choice(), first)
        quotas[second.id]?.windows[.weekly] = window(45, in: 3600)
        XCTAssertEqual(choice(), second)
        quotas[second.id]?.windows[.weekly] = window(45, in: 7200)
        XCTAssertEqual(choice(), first)
        quotas[first.id]?.windows[.weekly] = window(90, in: nil)
        XCTAssertEqual(choice(), second)
        quotas[second.id]?.windows[.monthly] = window(90, in: nil)
        XCTAssertNil(choice())
    }

    func testAliasesArchivedProfilesAndOtherProvidersAreExcluded() {
        let current = profile("a")
        var alias = profile("alias")
        alias.identityKey = current.identityKey
        var archived = profile("archived")
        archived.isArchived = true
        var other = profile("other")
        other.family = "claude"
        for profiles in [[current], [current, alias, archived, other]] {
            XCTAssertNil(
                AccountSwitchRecommendation.choose(current: current, profiles: profiles, at: now) { account in
                    AccountSwitchQuota(windows: [.weekly: window(account == current ? 99 : 12, in: 100)])
                })
        }
    }

    func testClaudeOnlyUsesSessionAndWeekly() {
        let lines: [MetricLine] = ["Session", "Weekly", "Sonnet", "Fable"].map { label in
            .progress(
                label: label, used: ["Session", "Weekly"].contains(label) ? 15 : 100, limit: 100,
                format: .percent, resetsAt: now.addingTimeInterval(30))
        }
        let quota = AccountSwitchQuota.claude(lines: lines)
        XCTAssertFalse(quota.needsSwitch(at: now))
        XCTAssertEqual(quota.nextCandidateReset(at: now), now.addingTimeInterval(30))
    }

    func testCodexBasePeriodsIgnoreSparkAndRejectIncompleteOrAmbiguousWindows() throws {
        let session = ["limit_window_seconds": 18000, "reset_after_seconds": 45, "used_percent": 20]
        let monthly = ["limit_window_seconds": 2_592_000, "used_percent": 95]
        func quota(_ secondary: Any?, headers: [String: String] = [:]) throws -> AccountSwitchQuota {
            var base: [String: Any] = ["primary_window": session]
            base["secondary_window"] = secondary
            let json: [String: Any] = [
                "rate_limit": base,
                "additional_rate_limits": [["limit_name": "Spark", "rate_limit": ["primary_window": monthly]]]
            ]
            let response = HTTPResponse(
                statusCode: 200, headers: headers, body: try JSONSerialization.data(withJSONObject: json))
            return try CodexUsageMapper.mapUsageResponse(response, now: now).switchQuota
        }
        XCTAssertFalse(try quota(nil).needsSwitch(at: now))
        XCTAssertEqual(try quota(nil).nextCandidateReset(at: now), now.addingTimeInterval(45))
        XCTAssertTrue(try quota(monthly).needsSwitch(at: now))
        XCTAssertNil(try quota(monthly).nextCandidateReset(at: now))
        XCTAssertNil(try quota(session).nextCandidateReset(at: now))
        XCTAssertNil(try quota(["limit_window_seconds": 604800]).nextCandidateReset(at: now))
        XCTAssertNil(try quota(nil, headers: ["x-codex-secondary-used-percent": "30"]).nextCandidateReset(at: now))
    }

    func testLiveCardRequiresFreshObservationAndMatchingIdentity() async {
        let suite = "AccountSwitchRecommendationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = profile("selected")
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let quota = AccountSwitchQuota(windows: [.session: window(95, in: 1000)])
        var snapshot = ProviderSnapshot(
            providerID: provider.id, displayName: provider.displayName, lines: [],
            refreshedAt: now, liveQuotaObservedAt: now, liveQuotaAccountKey: "verified")
        snapshot.codexSwitchIdentity = account.identityKey
        snapshot.codexSwitchQuota = quota
        let runtime = TestProviderRuntime(provider: provider, descriptors: [], snapshot: snapshot)
        func store(for identity: String) -> WidgetDataStore {
            WidgetDataStore(
                registry: WidgetRegistry.from([runtime]), providers: [runtime], cache: cache,
                defaults: defaults, now: { self.now }, providerIdentityKeys: [provider.id: identity])
        }
        let storeA = store(for: account.identityKey)
        await storeA.refresh(providerID: provider.id, force: true)
        XCTAssertEqual(storeA.recommendationQuota(for: account, cardID: provider.id, at: now), quota)
        XCTAssertNil(storeA.recommendationQuota(for: account, cardID: provider.id, at: now.addingTimeInterval(300)))
        XCTAssertNil(storeA.recommendationQuota(for: account, cardID: provider.id, at: now.addingTimeInterval(-1)))
        XCTAssertNil(store(for: account.identityKey).recommendationQuota(for: account, cardID: provider.id, at: now))
        let other = profile("replacement")
        let storeB = store(for: other.identityKey)
        await storeB.refresh(providerID: provider.id, force: true)
        XCTAssertNil(storeB.recommendationQuota(for: other, cardID: provider.id, at: now))
        storeA.invalidateAuthentication(for: provider.id)
        XCTAssertNil(storeA.recommendationQuota(for: account, cardID: provider.id, at: now))
    }

    func testChangedTargetInvalidatesConfirmationEvenWhenDepartureStillMatches() {
        let current = profile("current")
        let pending = AccountSwitchRecommendation(current: current, target: profile("first"))
        let updated = AccountSwitchRecommendation(current: current, target: profile("second"))
        XCTAssertThrowsError(try pending.validate(departure: current.identityKey, latest: updated))
    }

    func testRecommendationTimelineIncludesResetsAndObservationExpiryWithoutPolling() {
        let sessionReset = now.addingTimeInterval(7)
        let weeklyReset = now.addingTimeInterval(915)
        let lines: [MetricLine] = [
            .progress(label: "Session", used: 96, limit: 100, format: .percent, resetsAt: sessionReset),
            .progress(label: "Weekly", used: 10, limit: 100, format: .percent, resetsAt: weeklyReset)
        ]
        var snapshot = ProviderSnapshot(
            providerID: "claude@profile-a", displayName: "Claude", lines: lines, refreshedAt: now,
            liveQuotaObservedAt: now, liveQuotaAccountKey: "a")
        let expiry = now.addingTimeInterval(900)
        XCTAssertEqual(
            snapshot.recommendationDeadlines(after: now.addingTimeInterval(-1)).sorted(), [now, sessionReset, expiry])
        XCTAssertEqual(snapshot.recommendationDeadlines(after: now).sorted(), [sessionReset, expiry])
        XCTAssertEqual(snapshot.recommendationDeadlines(after: sessionReset), [expiry])
        XCTAssertTrue(snapshot.recommendationDeadlines(after: expiry).isEmpty)
        snapshot.liveQuotaAccountKey = nil
        XCTAssertTrue(snapshot.recommendationDeadlines(after: now).isEmpty)
    }

    func testCodexRecommendationChecksSharedLoginAfterReadingTargetCredentials() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let current = try fixture.store.add(family: "codex", label: "Current", identityKey: "current", id: "codex-a")
        let target = try fixture.store.add(family: "codex", label: "Target", identityKey: "target", id: "codex-b")
        func entry(_ id: String) -> AccountCredentialVault.Entry {
            .init(credential: #"{"tokens":{"access_token":"fixture","account_id":"\#(id)"}}"#, claudeOAuthAccount: nil)
        }
        try fixture.switcher.saveSnapshot(entry("target"), for: target)
        try fixture.switcher.applySharedAuthentication(entry("current"), family: "codex")

        let pending = AccountSwitchRecommendation(current: current, target: target)
        let path = fixture.root.appendingPathComponent(".codex/auth.json")
        let external = entry("external")
        let service = AccountCredentialVault.service(family: "codex", profileID: target.id)
        fixture.keychain.beforeRead = { name in
            if name == service { try Data(external.credential.utf8).write(to: path, options: .atomic) }
        }
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: target, in: fixture.store) { identity in
                XCTAssertEqual(identity, "external")
                try pending.validate(departure: identity, latest: pending)
            }
            XCTFail("The external login must remain active")
        } catch is AccountSwitchRecommendation.NoLongerAvailable {}
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), current.id)

        fixture.keychain.beforeRead = nil
        try fixture.switcher.applySharedAuthentication(entry("current"), family: "codex")
        try await fixture.selectionSwitcher.switchAuthentication(to: target, in: fixture.store) { identity in
            try pending.validate(departure: identity, latest: pending)
        }
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), entry("target"))
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), target.id)
    }

    func testClaudeExpiredRecommendationStopsBeforeJournalAndSharedLoginWrite() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let quota = AccountSwitchQuota(windows: [.weekly: window(95, in: 1)])
        XCTAssertTrue(quota.needsSwitch(at: now))
        let pending = AccountSwitchRecommendation(current: fixture.a, target: fixture.b)
        let targetService = AccountCredentialVault.service(family: "claude", profileID: fixture.b.id)
        let readsBefore = fixture.keychain.nativeReads.filter { $0.service == targetService }.count
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store) { identity in
                XCTAssertEqual(identity, fixture.a.identityKey)
                XCTAssertGreaterThan(
                    fixture.keychain.nativeReads.filter { $0.service == targetService }.count, readsBefore)
                try pending.validate(
                    departure: identity, latest: quota.needsSwitch(at: self.now.addingTimeInterval(1)) ? pending : nil)
            }
            XCTFail("Expired usage must cancel the switch")
        } catch is AccountSwitchRecommendation.NoLongerAvailable {}
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store) { identity in
            try pending.validate(departure: identity, latest: pending)
        }
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
    }

    func testRecommendationLeavesInterruptedClaudeSwitchForRecovery() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store) { _ in
                XCTFail("Recommendations must not retry interrupted switches")
            }
            XCTFail("Recovery is required")
        } catch AccountCredentialSwitcher.Error.switchRecoveryRequired {}
        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
    }

    func testLongNameFitsSameSingleRowAsShortNameInEachLanguage() throws {
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                @MainActor func render(_ name: String) throws -> CGImage {
                    let controls = AccountRecommendationControls(name: name, select: {}, dismiss: {})
                    let image = ImageRenderer(content: controls.frame(width: 280)).cgImage
                    return try XCTUnwrap(image)
                }
                let short = try render("Work")
                let long = try render(String(repeating: "가나다", count: 20))
                XCTAssertEqual(long.width, 280)
                XCTAssertEqual(long.height, short.height)
            }
        }
    }
}
