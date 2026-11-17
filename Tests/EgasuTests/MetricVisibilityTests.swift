import XCTest
@testable import Egasu

@MainActor
final class MetricVisibilityTests: XCTestCase {
    func testFreshInstallEnablesEveryRegisteredMetricWithoutWritingEnabledList() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)

        XCTAssertEqual(Set(store.placed.map(\.descriptorID)), Set(WidgetRegistry.mock.descriptors.map(\.id)))
        XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), [])
        XCTAssertNil(defaults.data(forKey: "layout"))
    }

    func testHideShowAndUndoPersistOnlyDisabledMetrics() {
        let defaults = makeDefaults()
        let store = makeStore(defaults)
        store.setMetricEnabled("claude.weekly", false)
        XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), ["claude.weekly"])
        XCTAssertFalse(makeStore(defaults).isMetricEnabled("claude.weekly"))

        store.setMetricEnabled("claude.weekly", true)
        XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), [])
        XCTAssertTrue(store.undo())
        XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), ["claude.weekly"])
        XCTAssertNil(defaults.data(forKey: "layout"))
    }

    func testLegacyEnabledListPreservesEveryHiddenMetricAndOrder() throws {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.session", "claude.extra", "claude.today"]])
        persistence.savePriorityPins(["claude.session"])
        let legacy = defaults.data(forKey: "layout")

        let store = makeStore(defaults)

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))
        XCTAssertEqual(Array(store.metricOrder(for: "claude").prefix(2)), ["claude.weekly", "claude.session"])
        store.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(defaults.data(forKey: "layout"), legacy, "이전 켜짐 목록은 읽기 호환용으로만 유지")
        XCTAssertTrue(makeStore(defaults).isMetricEnabled("claude.extra"))
        XCTAssertFalse(makeStore(defaults).isMetricEnabled("claude.weekly"))
    }

    func testExplicitlyEmptyLegacyLayoutStaysEmpty() {
        let defaults = makeDefaults()
        LayoutPersistence(defaults: defaults, storageKey: "layout").savePlaced([])

        XCTAssertTrue(makeStore(defaults).placed.isEmpty)
        XCTAssertTrue(makeStore(defaults).placed.isEmpty)
        XCTAssertEqual(
            Set(defaults.stringArray(forKey: "layout.disabledMetrics") ?? []),
            Set(WidgetRegistry.mock.descriptors.map(\.id)))
    }

    func testEmptyDisabledListOverridesStaleLegacyLayout() {
        let defaults = makeDefaults()
        LayoutPersistence(defaults: defaults, storageKey: "layout").savePlaced([])
        defaults.set([String](), forKey: "layout.disabledMetrics")

        XCTAssertEqual(makeStore(defaults).placed.count, WidgetRegistry.mock.descriptors.count)
    }

    func testNewMetricStartsEnabledWithoutRestoringHiddenMetrics() {
        let defaults = makeDefaults()
        let originalRegistry = WidgetRegistry(
            providers: WidgetRegistry.mock.providers,
            descriptors: WidgetRegistry.mock.descriptors.filter { $0.id != "claude.extra" }
        )
        let original = makeStore(defaults, registry: originalRegistry)
        original.setMetricEnabled("claude.weekly", false)

        original.replaceRegistry(.mock)

        XCTAssertTrue(original.isMetricEnabled("claude.extra"))
        XCTAssertFalse(original.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(makeStore(defaults).isMetricEnabled("claude.extra"))
        XCTAssertFalse(makeStore(defaults).isMetricEnabled("claude.weekly"))
    }

    func testUnavailableProvidersDisabledMetricSurvivesOtherEdits() {
        let defaults = makeDefaults()
        defaults.set(["claude.weekly"], forKey: "layout.disabledMetrics")
        let registry = WidgetRegistry(
            providers: WidgetRegistry.mock.providers.filter { $0.id != "claude" },
            descriptors: WidgetRegistry.mock.descriptors.filter { $0.providerID != "claude" }
        )
        let store = makeStore(defaults, registry: registry)
        store.setMetricEnabled("cursor.credits", false)

        store.replaceRegistry(.mock)

        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
    }

    func testUnreadableVisibilityDoesNotBecomeAnAllEnabledInstallation() {
        for key in ["layout", "layout.disabledMetrics"] {
            let defaults = makeDefaults()
            defaults.set("invalid visibility", forKey: key)

            let store = makeStore(defaults)
            XCTAssertTrue(store.placed.isEmpty)
            store.setMetricEnabled("claude.session", true)

            XCTAssertEqual(defaults.string(forKey: key), "invalid visibility")
            if key == "layout" { XCTAssertNil(defaults.object(forKey: "layout.disabledMetrics")) }
        }
    }

    func testExplicitGlobalResetRecoversUnreadableVisibilityWithoutOverwritingLegacyData() {
        for key in ["layout", "layout.disabledMetrics"] {
            let defaults = makeDefaults()
            defaults.set("invalid visibility", forKey: key)
            let store = makeStore(defaults)
            XCTAssertTrue(store.placed.isEmpty)

            store.resetToDefault()

            XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), [])
            XCTAssertEqual(
                Set(makeStore(defaults).placed.map(\.descriptorID)), Set(WidgetRegistry.mock.descriptors.map(\.id)))
            if key == "layout" { XCTAssertEqual(defaults.string(forKey: key), "invalid visibility") }
        }
    }

    private func makeStore(_ defaults: UserDefaults, registry: WidgetRegistry = .mock) -> LayoutStore {
        LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "EgasuTests.MetricVisibility.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
