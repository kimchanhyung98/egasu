import XCTest
@testable import Egasu

@MainActor
final class AccountRecommendationSettingsStoreTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func defaults() throws -> UserDefaults {
        let suite = "EgasuTests.AccountRecommendationSettings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func profiles(_ family: String = "claude") -> [AccountProfile] {
        ["current", "target"].map {
            AccountProfile(id: $0, family: family, label: $0, identityKey: $0, createdAt: now)
        }
    }

    private func recommendation(
        _ settings: AccountRecommendationSettingsStore, family: String = "claude", at date: Date? = nil,
        current: Double = 95, candidate: Double = 20
    ) -> AccountSwitchRecommendation? {
        let accounts = profiles(family)
        return settings.recommendation(current: accounts[0], profiles: accounts, at: date ?? now) { profile in
            .init(
                windows: [
                    .weekly: .init(
                        percent: profile.id == "current" ? current : candidate, reset: self.now.addingTimeInterval(7200)
                    )
                ],
                codexAccountKey: family == "codex" ? profile.id : nil)
        }
    }

    func testFreshAndExistingInstallDefaultsRequireExplicitOptIn() throws {
        let values = try defaults()
        values.set("existing-install", forKey: "fixture.existing")
        let store = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.triggerPercent, 95)
        XCTAssertEqual(store.candidateLimitPercent, 90)
        XCTAssertNil(recommendation(store))
    }

    func testBetaOffClearsOptInAndKeepsValuesAcrossRestart() throws {
        let values = try defaults()
        let store = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        store.enabled = true
        store.triggerPercent = 83
        store.candidateLimitPercent = 72
        store.setLabsAvailable(false)
        store.enabled = true
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.isActive)
        store.setLabsAvailable(true)
        XCTAssertFalse(store.enabled)

        let restored = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        XCTAssertFalse(restored.enabled)
        XCTAssertEqual(restored.triggerPercent, 83)
        XCTAssertEqual(restored.candidateLimitPercent, 72)
        restored.enabled = true
    }

    func testStartingWithoutLabsRevokesPreviouslyEnabledRecommendation() throws {
        let values = try defaults()
        let previous = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        previous.enabled = true
        XCTAssertTrue(previous.isActive)
        let disabled = AccountRecommendationSettingsStore(defaults: values, labsAvailable: false)
        XCTAssertFalse(disabled.enabled)
        XCTAssertFalse(AccountRecommendationSettingsStore(defaults: values, labsAvailable: true).enabled)
    }

    func testPercentageInputsAreIndependentAndSurviveRestart() throws {
        let values = try defaults()
        let store = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        for (input, expected) in [("1", 1), ("100", 100), (" 83\n", 83)] {
            XCTAssertTrue(store.setTrigger(from: input))
            XCTAssertTrue(store.setCandidateLimit(from: input))
            XCTAssertEqual(store.triggerPercent, expected)
            XCTAssertEqual(store.candidateLimitPercent, expected)
        }
        XCTAssertTrue(store.setTrigger(from: "40"))
        XCTAssertTrue(store.setCandidateLimit(from: "80"))
        let restored = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        XCTAssertEqual(restored.triggerPercent, 40)
        XCTAssertEqual(restored.candidateLimitPercent, 80)
    }

    func testInvalidPercentageInputPreservesBothSavedValues() throws {
        let values = try defaults()
        let store = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        store.triggerPercent = 81
        store.candidateLimitPercent = 67
        for text in ["", " ", "word", "90%", "90.5", "0", "-1", "101", "1e2", "9999999999999999999999"] {
            XCTAssertFalse(store.setTrigger(from: text), text)
            XCTAssertFalse(store.setCandidateLimit(from: text), text)
            XCTAssertEqual(store.triggerPercent, 81)
            XCTAssertEqual(store.candidateLimitPercent, 67)
            let restored = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
            XCTAssertEqual(restored.triggerPercent, 81)
            XCTAssertEqual(restored.candidateLimitPercent, 67)
        }
    }

    func testMalformedStoredValuesUseDefaultsAndNumericBoundsAreClamped() throws {
        let values = try defaults()
        values.set("bad", forKey: "openusage.accountRecommendations.triggerPercent.v1")
        values.set("bad", forKey: "openusage.accountRecommendations.candidateLimitPercent.v1")
        let malformed = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        XCTAssertEqual(malformed.triggerPercent, 95)
        XCTAssertEqual(malformed.candidateLimitPercent, 90)
        malformed.triggerPercent = 0
        malformed.candidateLimitPercent = 101
        let bounded = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
        XCTAssertEqual(bounded.triggerPercent, 1)
        XCTAssertEqual(bounded.candidateLimitPercent, 100)
    }

    func testConfiguredThresholdIncludesTriggerAndExcludesCandidateBoundaryWithoutRounding() throws {
        let store = AccountRecommendationSettingsStore(defaults: try defaults(), labsAvailable: true)
        store.enabled = true
        store.triggerPercent = 80
        store.candidateLimitPercent = 50
        XCTAssertNil(recommendation(store, current: 79.999, candidate: 10))
        XCTAssertNotNil(recommendation(store, current: 80, candidate: 49.999))
        XCTAssertNil(recommendation(store, current: 80, candidate: 50))
        store.triggerPercent = 40
        store.candidateLimitPercent = 80
        XCTAssertNotNil(recommendation(store, current: 50, candidate: 70))
    }

    func testEveryApplicableCandidateWindowMustBeBelowTheConfiguredLimit() throws {
        let store = AccountRecommendationSettingsStore(defaults: try defaults(), labsAvailable: true)
        store.enabled = true
        store.candidateLimitPercent = 50
        let accounts = profiles()
        let choice = store.recommendation(current: accounts[0], profiles: accounts, at: now) { profile in
            .init(windows: [
                .session: .init(percent: profile.id == "current" ? 95 : 20, reset: self.now.addingTimeInterval(60)),
                .monthly: .init(percent: profile.id == "current" ? 0 : 50, reset: nil)
            ])
        }
        XCTAssertNil(choice)
    }

}
