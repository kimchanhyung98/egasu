import XCTest
@testable import Egasu

@MainActor
final class KimiKiroLayoutTests: XCTestCase {
    func testFreshDefaultsMatchOwnerApprovedPlacement() {
        let suiteName = "EgasuTests.KimiKiroLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let registry = WidgetRegistry.from([KimiProvider(), KiroProvider()])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "kimi.session", "kimi.weekly", "kimi.total", "kimi.extra", "kimi.extraBalance", "kiro.credits"
        ])
        XCTAssertEqual(store.pinnedMetricIDs, [
            "kimi.weekly", "kiro.credits"
        ])

        let kimi = store.customizeGroups.first { $0.provider.id == "kimi" }
        XCTAssertEqual(
            kimi?.alwaysShownMetrics.map(\.id),
            [
                "kimi.session", "kimi.weekly", "kimi.total", "kimi.extra", "kimi.extraBalance"
        ])
        XCTAssertTrue(kimi?.expandedMetrics.isEmpty == true)

        let kiro = store.customizeGroups.first { $0.provider.id == "kiro" }
        XCTAssertEqual(kiro?.alwaysShownMetrics.map(\.id), ["kiro.credits"])
        XCTAssertTrue(kiro?.expandedMetrics.isEmpty == true)
    }

    func testAddingKimiMetricsKeepsExistingHiddenMetricAndOrderAcrossRelaunch() {
        let suiteName = "EgasuTests.KimiKiroLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let registry = WidgetRegistry.from([KimiProvider()])
        let originalRegistry = WidgetRegistry(
            providers: registry.providers,
            descriptors: registry.descriptors.filter { ["kimi.session", "kimi.weekly"].contains($0.id) }
        )
        let store = LayoutStore(registry: originalRegistry, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.reorderMetric(dragged: "kimi.weekly", target: "kimi.session", in: "kimi"))
        store.setMetricEnabled("kimi.weekly", false)

        store.replaceRegistry(registry)

        let expectedOrder = ["kimi.weekly", "kimi.session", "kimi.total", "kimi.extra", "kimi.extraBalance"]
        let relaunched = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        for current in [store, relaunched] {
            XCTAssertEqual(current.customizeGroups.first { $0.provider.id == "kimi" }?.metrics.map(\.id), expectedOrder)
            XCTAssertEqual(current.placed.map(\.descriptorID), expectedOrder.filter { $0 != "kimi.weekly" })
            XCTAssertEqual(current.pinnedMetricIDs, ["kimi.weekly"])
        }
    }
}
