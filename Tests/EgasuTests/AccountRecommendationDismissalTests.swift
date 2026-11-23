import XCTest
@testable import Egasu

@MainActor
final class AccountRecommendationDismissalTests: XCTestCase {
    @MainActor
    private final class Fixture {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let values: UserDefaults
        let suite = "EgasuTests.RecommendationDismissal.\(UUID().uuidString)"
        var settings: AccountRecommendationSettingsStore
        var profiles: [AccountProfile]
        var quotas: [String: AccountSwitchQuota] = [:]
        var now: Date

        init(family: String = "claude") throws {
            values = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = AccountRecommendationSettingsStore(defaults: values, labsAvailable: true)
            settings.enabled = true
            now = start
            let instant = start
            profiles = ["A", "B", "C", "D"].map {
                AccountProfile(id: $0, family: family, label: $0, identityKey: "\($0)|org", createdAt: instant)
            }
            for (index, profile) in profiles.enumerated() {
                quotas[profile.id] = .init(
                    windows: [
                        .session: .init(
                            percent: index.isMultiple(of: 2) ? 96 : 20,
                            reset: start.addingTimeInterval(Double(index + 1) * 900)),
                        .weekly: .init(
                            percent: index.isMultiple(of: 2) ? 96 : 20,
                            reset: start.addingTimeInterval(604_800))
                    ], codexAccountKey: family == "codex" ? profile.id : nil)
            }
        }

        func cleanup() { values.removePersistentDomain(forName: suite) }

        func recommendation(_ id: String) -> AccountSwitchRecommendation? {
            guard let current = profiles.first(where: { $0.id == id }) else { return nil }
            return settings.recommendation(current: current, profiles: profiles, at: now) { quotas[$0.id] }
        }

        func dismiss(_ id: String) throws {
            let suggestion = try XCTUnwrap(recommendation(id))
            XCTAssertTrue(settings.dismiss(suggestion, at: now) { quotas[$0.id] })
        }

        func observe(_ id: String, at seconds: TimeInterval, used: Double, reset: TimeInterval?) throws {
            now = start.addingTimeInterval(seconds)
            quotas[id]?.windows[.session] = .init(percent: used, reset: reset.map(start.addingTimeInterval))
            settings.observeSession(
                for: try XCTUnwrap(profiles.first { $0.id == id }), quota: try XCTUnwrap(quotas[id]),
                observedAt: now, at: now)
        }
    }

    func testDismissalHidesEverySuggestionOnDepartureAndOnlyTheTargetAfterSwitching() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        XCTAssertEqual(f.recommendation("A")?.target.id, "B")
        try f.dismiss("A")
        XCTAssertNil(f.recommendation("A"))
        XCTAssertEqual(f.recommendation("C")?.target.id, "D")
        f.now.addTimeInterval(86_400)
        f.quotas["B"]?.windows[.session]?.reset = f.now.addingTimeInterval(900)
        XCTAssertNil(f.recommendation("A"), "Elapsed time alone must not remove a dismissal")
    }

    func testEitherOriginalSessionResetReleasesTheDismissal() throws {
        for id in ["A", "B"] {
            let f = try Fixture()
            defer { f.cleanup() }
            try f.dismiss("A")
            try f.observe(id, at: id == "A" ? 900 : 1800, used: 0, reset: id == "A" ? 2700 : 3000)
            XCTAssertEqual(f.recommendation("A")?.target.id, "B", id)
        }
    }

    func testWeeklyResetAndThirdAccountResetDoNotReleaseTheOriginalPair() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.dismiss("A")
        f.quotas["B"]?.windows[.weekly] = .init(percent: 0, reset: f.start.addingTimeInterval(700_000))
        try f.observe("B", at: 100, used: 20, reset: 1800)
        try f.observe("C", at: 2700, used: 0, reset: 4500)
        XCTAssertNil(f.recommendation("A"))
        XCTAssertEqual(f.recommendation("C")?.target.id, "D")
    }

    func testMissingSessionAndOutOfOrderOrFutureObservationsKeepTheDismissal() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.dismiss("A")
        let a = try XCTUnwrap(f.profiles.first)
        var missing = try XCTUnwrap(f.quotas["A"])
        missing.windows[.session] = nil
        f.settings.observeSession(
            for: a, quota: missing, observedAt: f.start.addingTimeInterval(1000),
            at: f.start.addingTimeInterval(1000))
        var reset = try XCTUnwrap(f.quotas["A"])
        reset.windows[.session] = .init(percent: 0, reset: nil)
        for (observed, current) in [(-1.0, 1000.0), (1000, 100)] {
            f.settings.observeSession(
                for: a, quota: reset, observedAt: f.start.addingTimeInterval(observed),
                at: f.start.addingTimeInterval(current))
        }
        XCTAssertNil(f.recommendation("A"))
    }

    func testFirstSessionStartOnlyLearnsTheResetAndSurvivesRestartAndFeatureToggles() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.quotas["A"]?.windows[.session] = .init(percent: 0, reset: nil)
        try f.dismiss("A")
        f.settings.enabled = false
        try f.observe("A", at: 100, used: 0, reset: 18_100)
        f.settings = AccountRecommendationSettingsStore(defaults: f.values, labsAvailable: true)
        f.settings.setLabsAvailable(false)
        f.settings.setLabsAvailable(true)
        f.settings.enabled = true
        XCTAssertNil(f.recommendation("A"), "A newly started first session is not a reset")
        try f.observe("A", at: 18_100, used: 0, reset: nil)
        f.quotas["B"]?.windows[.session] = .init(percent: 20, reset: f.now.addingTimeInterval(600))
        XCTAssertEqual(f.recommendation("A")?.target.id, "B")
    }

    func testIndependentDismissalsReleaseOnlyTheirOwnPairs() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        try f.dismiss("A")
        try f.dismiss("C")
        XCTAssertNil(f.recommendation("C"))
        try f.observe("C", at: 2700, used: 0, reset: 4500)
        XCTAssertEqual(f.recommendation("C")?.target.id, "D")
        XCTAssertNil(f.recommendation("A"))
    }

    func testAliasesOfTheSameTargetAreAlsoExcludedAndDifferentCodexMembersStayIndependent() throws {
        for family in ["claude", "codex"] {
            let f = try Fixture(family: family)
            defer { f.cleanup() }
            try f.dismiss("A")
            var alias = try XCTUnwrap(f.profiles.first { $0.id == "B" })
            alias.id = "alias"
            f.profiles.append(alias)
            f.quotas[alias.id] = f.quotas["B"]
            XCTAssertEqual(f.recommendation("C")?.target.id, "D", family)
            if family == "codex" {
                f.quotas["B"]?.codexAccountKey = "other-member"
                try f.observe("B", at: 1800, used: 0, reset: 3000)
                XCTAssertNil(f.recommendation("A"))
                XCTAssertEqual(f.recommendation("C")?.target.id, "B")
                f.quotas["B"]?.codexAccountKey = "B"
                XCTAssertEqual(f.recommendation("C")?.target.id, "D")
            }
        }
    }

    func testUnstartedSessionNeverBypassesTheWeeklyCandidateLimit() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.profiles = Array(f.profiles.prefix(2))
        f.quotas["B"]?.windows[.session] = .init(percent: 0, reset: nil)
        for percent in [95.0, 90] {
            f.quotas["B"]?.windows[.weekly]?.percent = percent
            XCTAssertNil(f.recommendation("A"))
        }
        f.quotas["B"]?.windows[.weekly]?.percent = 89.999
        XCTAssertEqual(f.recommendation("A")?.target.id, "B")
    }

    func testCodexUnstartedMovingResetNeverReleasesTheDismissal() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        f.quotas["B"]?.windows[.session]?.percent = 0
        try f.dismiss("A")
        try f.observe("B", at: 900, used: 0, reset: 2700)
        try f.observe("B", at: 2700, used: 0, reset: 4500)
        XCTAssertNil(f.recommendation("A"))
    }

    func testConfirmedCodexSessionCanResetBeforeItsScheduledDeadline() throws {
        for initiallyUsed in [0.0, 20] {
            let f = try Fixture(family: "codex")
            defer { f.cleanup() }
            f.quotas["B"]?.windows[.session]?.percent = initiallyUsed
            try f.dismiss("A")
            if initiallyUsed == 0 { try f.observe("B", at: 70, used: 0, reset: 1800) }
            try f.observe("B", at: 100, used: 0, reset: 2000)
            XCTAssertEqual(f.recommendation("A")?.target.id, "B")
        }
    }

    func testSmallResetTimestampDriftDoesNotReleaseTheDismissal() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        try f.dismiss("A")
        try f.observe("B", at: 100, used: 20, reset: 1830)
        XCTAssertNil(f.recommendation("A"))
    }

    func testMissingCodexResetDoesNotReleaseAConfirmedZeroUsageSession() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        f.quotas["B"]?.windows[.session]?.percent = 0
        try f.dismiss("A")
        try f.observe("B", at: 70, used: 0, reset: 1800)
        try f.observe("B", at: 100, used: 0, reset: nil)
        XCTAssertNil(f.recommendation("A"))
    }

    func testTemporaryMissingResetPreservesThePreviouslyKnownSession() throws {
        for family in ["claude", "codex"] {
            let f = try Fixture(family: family)
            defer { f.cleanup() }
            try f.dismiss("A")
            try f.observe("B", at: 100, used: 25, reset: nil)
            try f.observe("B", at: 1800, used: 5, reset: 4000)
            XCTAssertNotNil(f.recommendation("A"), family)
        }
    }

    func testExpiredCodexTimestampCannotConfirmTheStartOfAnUnusedSession() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        f.quotas["B"]?.windows[.session]?.percent = 0
        try f.dismiss("A")
        try f.observe("B", at: 1801, used: 0, reset: 1800)
        try f.observe("B", at: 1900, used: 0, reset: 19_900)
        XCTAssertNil(f.recommendation("A"))
    }

    func testFirstUsedCodexObservationWithoutResetDiscardsTheUnstartedDeadline() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        f.quotas["B"]?.windows[.session]?.percent = 0
        try f.dismiss("A")
        try f.observe("B", at: 1810, used: 1, reset: nil)
        try f.observe("B", at: 1820, used: 2, reset: 19_810)
        XCTAssertNil(f.recommendation("A"))
    }

    func testMissingTimestampPreservesUsageEvidenceForAnEarlyReset() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        try f.dismiss("A")
        try f.observe("B", at: 100, used: 1, reset: nil)
        try f.observe("B", at: 200, used: 1, reset: 18_200)
        XCTAssertNotNil(f.recommendation("A"))
    }

    func testEarlyUsageResetWithTheSameFutureDeadlineReleasesTheDismissal() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        try f.dismiss("A")
        try f.observe("B", at: 100, used: 0, reset: 1800)
        XCTAssertEqual(f.recommendation("A")?.target.id, "B")
    }

    func testStartedZeroUsageSessionKeepsAnIncreaseWhenTheTimestampIsMissing() throws {
        let f = try Fixture(family: "codex")
        defer { f.cleanup() }
        f.quotas["B"]?.windows[.session]?.percent = 0
        try f.dismiss("A")
        try f.observe("B", at: 70, used: 0, reset: 1800)
        try f.observe("B", at: 100, used: 5, reset: nil)
        try f.observe("B", at: 110, used: 0, reset: 1800)
        XCTAssertEqual(f.recommendation("A")?.target.id, "B")
    }

    func testExpiredPositiveCodexUsageCannotConfirmTheStartOfAnUnusedSession() throws {
        for initiallyExpired in [false, true] {
            let f = try Fixture(family: "codex")
            defer { f.cleanup() }
            f.quotas["A"]?.windows[.session] = .init(
                percent: initiallyExpired ? 20 : 0, reset: initiallyExpired ? f.start.addingTimeInterval(-10) : nil)
            try f.dismiss("A")
            if !initiallyExpired { try f.observe("A", at: 10, used: 20, reset: 5) }
            try f.observe("A", at: 100, used: 0, reset: 18_100)
            try f.observe("A", at: 200, used: 0, reset: 18_200)
            XCTAssertNil(f.recommendation("A"))
        }
    }

    func testReadingRecommendationsDoesNotWritePreferencesAndLegacyDelayIsRemoved() throws {
        let f = try Fixture()
        defer { f.cleanup() }
        f.values.set(60, forKey: "openusage.accountRecommendations.reappearanceMinutes.v1")
        f.values.set(["claude": f.start], forKey: "openusage.accountRecommendations.dismissedAt.v1")
        f.settings = AccountRecommendationSettingsStore(defaults: f.values, labsAvailable: true)
        XCTAssertNil(f.values.object(forKey: "openusage.accountRecommendations.reappearanceMinutes.v1"))
        XCTAssertNil(f.values.object(forKey: "openusage.accountRecommendations.dismissedAt.v1"))
        try f.dismiss("A")
        let before = NSDictionary(dictionary: f.values.dictionaryRepresentation())
        for _ in 0..<3 { XCTAssertNil(f.recommendation("A")) }
        XCTAssertEqual(before, NSDictionary(dictionary: f.values.dictionaryRepresentation()))
    }
}
