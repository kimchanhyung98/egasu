import XCTest
@testable import Egasu

@MainActor
final class AccountRecommendationDismissalIntegrationTests: XCTestCase {
    func testOnlyFreshBoundSavedAccountObservationsReleaseTheDismissal() async throws {
        for variant in [
            "valid", "preferred-saved", "shared-other-login", "cached", "stale", "wrong-account", "wrong-binding",
            "authentication-error"
        ] {
            let suite = "EgasuTests.RecommendationDismissal.Integration.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let profiles = AccountProfilesStore(defaults: defaults)
            let a = try profiles.add(family: "claude", label: "A", identityKey: "A|org", id: "A")
            let b = try profiles.add(family: "claude", label: "B", identityKey: "B|org", id: "B")
            profiles.setPreferred(family: "claude", profileID: a.id)
            let settings = AccountRecommendationSettingsStore(defaults: defaults, labsAvailable: true)
            settings.enabled = true
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            var now = start
            func quota(_ profile: AccountProfile) -> AccountSwitchQuota? {
                .init(windows: [
                    .session: .init(percent: profile.id == a.id ? 96 : 20, reset: now.addingTimeInterval(900)),
                    .weekly: .init(percent: profile.id == a.id ? 96 : 20, reset: now.addingTimeInterval(604_800))
                ])
            }
            let pending = try XCTUnwrap(settings.recommendation(current: a, profiles: [a, b], at: now, quota: quota))
            XCTAssertTrue(settings.dismiss(pending, at: now, quota: quota))
            now = start.addingTimeInterval(2000)
            let observedProfile = variant == "preferred-saved" ? a : b
            let card =
                variant == "shared-other-login"
                ? "claude"
                : AccountUsageCardPlanner.cardID(family: observedProfile.family, profileID: observedProfile.id)
            var snapshot = ProviderSnapshot(
                providerID: card, displayName: "Claude",
                lines: [
                    .progress(
                        label: "Session", used: 0, limit: 100, format: .percent,
                        resetsAt: now.addingTimeInterval(18_000)),
                    .progress(
                        label: "Weekly", used: 20, limit: 100, format: .percent,
                        resetsAt: now.addingTimeInterval(604_800))
                ], refreshedAt: now, liveQuotaObservedAt: now,
                liveQuotaAccountKey: UsageTimerObservation.accountKey(
                    family: observedProfile.family, identity: observedProfile.identityKey))
            if variant == "cached" { snapshot.liveQuotaObservedAt = nil }
            if variant == "stale" { snapshot.liveQuotaObservedAt = now.addingTimeInterval(-900) }
            if variant == "wrong-account" {
                snapshot.liveQuotaAccountKey = UsageTimerObservation.accountKey(
                    family: a.family, identity: a.identityKey)
            }
            if variant == "authentication-error" { snapshot.authenticationIssue = .signInNeeded }
            let runtime = TestProviderRuntime(
                provider: Provider(id: card, displayName: "Claude", icon: .providerMark("claude")),
                descriptors: [], snapshot: snapshot)
            let store = WidgetDataStore(
                registry: .from([runtime]), providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults),
                defaults: defaults, now: { snapshot.refreshedAt },
                providerIdentityKeys: [card: variant == "wrong-binding" ? a.identityKey : observedProfile.identityKey])
            store.onFreshSnapshot = { received, _, _ in
                AppContainer.observeAccountRecommendationSession(
                    received, profiles: profiles, dataStore: store, settings: settings, at: now)
            }
            await store.refresh(providerID: card, force: true)
            XCTAssertEqual(
                settings.recommendation(current: a, profiles: [a, b], at: now, quota: quota)?.target.id,
                ["valid", "preferred-saved", "shared-other-login"].contains(variant) ? b.id : nil, variant)
            store.onFreshSnapshot = nil
        }
    }
}
