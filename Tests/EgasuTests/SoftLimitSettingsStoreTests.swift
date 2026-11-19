import XCTest
@testable import Egasu

@MainActor
final class SoftLimitSettingsStoreTests: XCTestCase {
    func testWindowLabelsMatchSettingsCopy() {
        XCTAssertEqual(SoftLimitWindowSelection.allCases.map(\.label), ["Weekly and Monthly", "Weekly", "Monthly"])
    }

    func testDefaultsAreOffForBothPeriodsAtNinetyPercent() {
        let defaults = makeDefaults("defaults")

        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)

        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.window, .all)
        XCTAssertEqual(store.thresholdPercent, 90)
        store.enabled = true
        XCTAssertEqual(store.thresholdPercent, 90)
    }

    func testChoicesPersistAcrossStoreInstances() {
        let defaults = makeDefaults("persistence")
        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)

        store.enabled = true
        store.window = .monthly
        store.thresholdPercent = 75

        let reloaded = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        XCTAssertTrue(reloaded.enabled)
        XCTAssertEqual(reloaded.window, .monthly)
        XCTAssertEqual(reloaded.thresholdPercent, 75)
        reloaded.enabled = false
        reloaded.enabled = true
        XCTAssertEqual(reloaded.thresholdPercent, 75)
    }

    func testStartingOutsideLabsClearsConsentAndKeepsThresholdAndWindow() {
        let defaults = makeDefaults("labs-consent")
        let previous = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        previous.enabled = true
        previous.window = .monthly
        previous.thresholdPercent = 83

        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: false)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(store.isActive)
        XCTAssertEqual(store.window, .monthly)
        XCTAssertEqual(store.thresholdPercent, 83)
        store.enabled = true
        store.setLabsAvailable(true)
        XCTAssertFalse(store.enabled)
        XCTAssertFalse(SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).enabled)
        store.enabled = true
        XCTAssertTrue(store.isActive)
    }

    func testLegacyGuideEnablementDoesNotAuthorizeCancellation() {
        let defaults = makeDefaults("legacy-guide")
        defaults.set(true, forKey: "openusage.softLimit.enabled.v1")
        defaults.set(94, forKey: "openusage.softLimit.thresholdPercent.v1")
        defaults.set("fiveHours", forKey: "openusage.softLimit.window.v1")

        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)

        XCTAssertFalse(store.enabled)
        XCTAssertEqual(store.thresholdPercent, 94)
        XCTAssertEqual(store.window, .all)
        XCTAssertTrue(defaults.bool(forKey: "openusage.softLimit.enabled.v1"))
        store.enabled = true
        XCTAssertTrue(SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).enabled)
    }

    func testThresholdAssignmentsSupportTheFullPercentageRange() {
        let store = SoftLimitSettingsStore(defaults: makeDefaults("assignment-range"), labsAvailable: true)

        for percent in [1, 50, 75, 89, 90, 95, 96, 100] {
            store.thresholdPercent = percent
            XCTAssertEqual(store.thresholdPercent, percent)
        }

        store.thresholdPercent = 0
        XCTAssertEqual(store.thresholdPercent, 1)
        store.thresholdPercent = 101
        XCTAssertEqual(store.thresholdPercent, 100)
    }

    func testPersistedThresholdIsClampedAndMalformedValuesUseDefault() {
        let low = makeDefaults("persisted-low")
        low.set(0, forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: low, labsAvailable: true).thresholdPercent, 1)

        let high = makeDefaults("persisted-high")
        high.set(101, forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: high, labsAvailable: true).thresholdPercent, 100)

        let malformed = makeDefaults("persisted-malformed")
        malformed.set("95", forKey: "openusage.softLimit.thresholdPercent.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: malformed, labsAvailable: true).thresholdPercent, 90)
    }

    func testExistingThresholdSurvivesFirstEnableWithTheNewDefault() {
        let defaults = makeDefaults("existing-threshold")
        defaults.set(95, forKey: "openusage.softLimit.thresholdPercent.v1")
        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)

        XCTAssertFalse(store.enabled)
        store.enabled = true
        XCTAssertEqual(store.thresholdPercent, 95)
    }

    func testDirectInputAcceptsAndPersistsWholePercentages() {
        let defaults = makeDefaults("direct-input")
        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)

        for (text, percent) in [("1", 1), ("50", 50), ("75", 75), ("96", 96), ("100", 100), (" 89\n", 89)] {
            XCTAssertTrue(store.setThreshold(from: text))
            XCTAssertEqual(store.thresholdPercent, percent)
            XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).thresholdPercent, percent)
        }
    }

    func testInvalidDirectInputPreservesTheLastSavedThreshold() {
        let defaults = makeDefaults("invalid-input")
        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        XCTAssertTrue(store.setThreshold(from: "75"))

        for text in ["", " ", "word", "90%", "90.5", "-1", "0", "101", "1e2", "999999999999999999999999"] {
            XCTAssertFalse(store.setThreshold(from: text), text)
            XCTAssertEqual(store.thresholdPercent, 75, text)
            XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).thresholdPercent, 75, text)
        }
    }

    func testRemovedSessionMigratesWithoutChangingConsentOrThreshold() {
        let defaults = makeDefaults("migrate-session")
        defaults.set("fiveHours", forKey: "openusage.softLimit.window.v1")
        defaults.set(true, forKey: "openusage.softLimit.cancellationEnabled.v2")
        defaults.set(84, forKey: "openusage.softLimit.thresholdPercent.v1")

        let store = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        XCTAssertTrue(store.isActive)
        XCTAssertEqual(store.thresholdPercent, 84)
        XCTAssertEqual(store.window, .all)
        XCTAssertEqual(defaults.string(forKey: "openusage.softLimit.window.v1"), "all")

        defaults.set("weekly", forKey: "openusage.softLimit.window.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).window, .weekly)
        defaults.set("invalid", forKey: "openusage.softLimit.window.v1")
        XCTAssertEqual(SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).window, .all)
    }

    func testUsageGuideRequiresTheSelectedPeriodAndReportedDuration() {
        let store = SoftLimitSettingsStore(defaults: makeDefaults("window-policy"), labsAvailable: true)
        let meter = WidgetDescriptor.percent(id: "fixture.quota", provider: MockData.codex, title: "Quota")
        let both = meter.supportingSoftLimit(.weekly, .monthly)
        let monthly = meter.supportingSoftLimit(.monthly, acceptsMissingDuration: true)
        XCTAssertNil(store.usedFraction(for: both, periodDurationMs: MetricPeriod.weekMs))

        store.enabled = true
        for days in [7, 28, 29, 30, 31] {
            XCTAssertEqual(store.usedFraction(for: both, periodDurationMs: days * MetricPeriod.dayMs), 0.90)
        }
        for days in [1, 14, 27, 32, 90] {
            XCTAssertNil(store.usedFraction(for: both, periodDurationMs: days * MetricPeriod.dayMs))
        }
        let calendar = meter.supportingSoftLimit(.weekly, .monthly, allowsDSTOffset: true)
        XCTAssertEqual(store.usedFraction(for: calendar, periodDurationMs: MetricPeriod.weekMs - 3_600_000), 0.90)
        XCTAssertEqual(store.usedFraction(for: calendar, periodDurationMs: MetricPeriod.weekMs + 3_600_000), 0.90)
        XCTAssertNil(store.usedFraction(for: calendar, periodDurationMs: MetricPeriod.weekMs - 7_200_000))
        XCTAssertEqual(store.usedFraction(for: calendar, periodDurationMs: 28 * MetricPeriod.dayMs - 3_600_000), 0.90)
        XCTAssertEqual(store.usedFraction(for: calendar, periodDurationMs: 31 * MetricPeriod.dayMs + 3_600_000), 0.90)
        XCTAssertNil(store.usedFraction(for: both, periodDurationMs: MetricPeriod.weekMs - 3_600_000))
        XCTAssertNil(store.usedFraction(for: both, periodDurationMs: nil))
        XCTAssertEqual(store.usedFraction(for: monthly, periodDurationMs: nil), 0.90)
        XCTAssertNil(store.usedFraction(for: monthly, periodDurationMs: MetricPeriod.sessionMs))
        XCTAssertNil(store.usedFraction(for: meter, periodDurationMs: MetricPeriod.monthMs))

        store.window = .weekly
        XCTAssertNil(store.usedFraction(for: both, periodDurationMs: MetricPeriod.monthMs))
        XCTAssertNil(store.usedFraction(for: monthly, periodDurationMs: nil))
        store.window = .monthly
        XCTAssertNil(store.usedFraction(for: both, periodDurationMs: MetricPeriod.weekMs))
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.SoftLimit.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
