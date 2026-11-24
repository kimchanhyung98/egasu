import XCTest
@testable import Egasu

@MainActor
final class DesktopWidgetAccountBindingTests: XCTestCase {
    private func profile(_ family: String, identity: String) -> AccountProfile {
        AccountProfile(id: "fixture", family: family, label: "Work", identityKey: identity, createdAt: .distantPast)
    }

    private func snapshot(_ family: String) -> ProviderSnapshot {
        ProviderSnapshot(providerID: family, displayName: family, lines: [], refreshedAt: .distantPast)
    }

    func testSharedCardRejectsAnotherOrUnresolvedBinding() {
        let profile = profile("codex", identity: "fixture-a")
        var reading = snapshot("codex")
        reading.codexSwitchIdentity = profile.identityKey
        for binding: WidgetDataStore.ClaimRefreshBinding? in [.account("fixture-b"), .unresolvedCatalog(1), nil] {
            XCTAssertFalse(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
        }
    }

    func testCodexReadingMustMatchBoundProfileWhenItCarriesALiveIdentity() {
        let profile = profile("codex", identity: "fixture-a")
        let binding = WidgetDataStore.ClaimRefreshBinding.account(profile.identityKey)
        var reading = snapshot("codex")
        reading.codexSwitchIdentity = "fixture-b"
        XCTAssertFalse(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
        reading.codexSwitchIdentity = profile.identityKey
        XCTAssertTrue(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
    }

    func testClaudeReadingSeparatesOrganizationsOfTheSameAccount() {
        let profile = profile("claude", identity: "fixture-a|org-a")
        let binding = WidgetDataStore.ClaimRefreshBinding.account(profile.identityKey)
        var reading = snapshot("claude")
        reading.liveQuotaAccountKey = UsageTimerObservation.accountKey(family: "claude", identity: "fixture-a|org-b")
        XCTAssertFalse(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
        reading.liveQuotaAccountKey = UsageTimerObservation.accountKey(family: "claude", identity: profile.identityKey)
        XCTAssertTrue(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
    }

    func testLegacyClaudeRequiresBoundAccountPrefixAndVerifiedOrganizationHash() {
        let profile = profile("claude", identity: "fixture-a")
        let binding = WidgetDataStore.ClaimRefreshBinding.account(profile.identityKey)
        var reading = snapshot("claude")
        let verified = "fixture-a|org-b"
        reading.legacyClaudeSwitchIdentity = .init(identityKey: verified, accessToken: "synthetic")
        reading.liveQuotaAccountKey = UsageTimerObservation.accountKey(family: "claude", identity: verified)
        XCTAssertTrue(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))

        reading.liveQuotaAccountKey = UsageTimerObservation.accountKey(family: "claude", identity: "fixture-a|org-c")
        XCTAssertFalse(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
        let differentAccount = "fixture-ab|org-b"
        reading.legacyClaudeSwitchIdentity = .init(identityKey: differentAccount, accessToken: "synthetic")
        reading.liveQuotaAccountKey = UsageTimerObservation.accountKey(family: "claude", identity: differentAccount)
        XCTAssertFalse(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: reading))
    }

    func testBoundManagedProfilesPermitValidatedCacheWithoutLiveMetadata() throws {
        for profile in [profile("claude", identity: "fixture-a|org-a"), profile("codex", identity: "fixture-b")] {
            let binding = WidgetDataStore.ClaimRefreshBinding.account(profile.identityKey)
            var reading = snapshot(profile.family)
            if profile.family == "claude" {
                reading.liveQuotaAccountKey = UsageTimerObservation.accountKey(
                    family: profile.family, identity: profile.identityKey)
            } else {
                reading.codexSwitchIdentity = profile.identityKey
            }
            let cached = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(reading))
            XCTAssertNil(cached.liveQuotaAccountKey)
            XCTAssertNil(cached.codexSwitchIdentity)
            XCTAssertTrue(DesktopWidgetProjection.permitsReading(profile: profile, binding: binding, local: cached))
        }
    }

    func testProviderWithoutManagedProfilePermitsProviderReading() {
        XCTAssertTrue(DesktopWidgetProjection.permitsReading(profile: nil, binding: nil, local: snapshot("grok")))
    }
}
