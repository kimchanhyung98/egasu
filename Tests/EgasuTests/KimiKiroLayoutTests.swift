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
        XCTAssertTrue(store.priorityPinIDs.isEmpty, "새 설치는 고정 없이 시작")

        let kimi = store.customizeGroups.first { $0.provider.id == "kimi" }
        XCTAssertEqual(kimi?.metrics.map(\.id), [
            "kimi.session", "kimi.weekly", "kimi.total", "kimi.extra", "kimi.extraBalance"
        ])

        let kiro = store.customizeGroups.first { $0.provider.id == "kiro" }
        XCTAssertEqual(kiro?.metrics.map(\.id), ["kiro.credits"])
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
        XCTAssertEqual(store.accountSettingsMetrics(for: "kimi").map(\.id), expectedOrder)
        XCTAssertEqual(store.placed.map(\.descriptorID), expectedOrder.filter { $0 != "kimi.weekly" })
        let relaunched = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(relaunched.accountSettingsMetrics(for: "kimi").map(\.id), expectedOrder)
        XCTAssertEqual(relaunched.placed.map(\.descriptorID), expectedOrder.filter { $0 != "kimi.weekly" })
        XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), ["kimi.weekly"])
    }
    func testRemovingCodeMetricPreservesOtherVisibilityOrderAndPinsAcrossRelaunch() {
        let suiteName = "EgasuTests.KimiKiroLayout.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = KimiProvider()
        let registry = WidgetRegistry.from([provider])
        var oldDescriptors = registry.descriptors.filter { $0.id != "kimi.monthlyCode" }
        oldDescriptors.insert(
            .values(id: "kimi.monthlyCode", provider: provider.provider, title: "Monthly Code", selection: .kind(.percent))
                .exportingLimit("monthlyCode", unit: "percent", source: .value(kind: .percent)),
            at: 3
        )
        let oldRegistry = WidgetRegistry(providers: registry.providers, descriptors: oldDescriptors)
        let store = LayoutStore(registry: oldRegistry, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(store.reorderMetric(dragged: "kimi.extraBalance", target: "kimi.total", in: "kimi"))
        store.setMetricEnabled("kimi.weekly", false)
        store.setMetric("kimi.total", pinned: true)
        store.setMetric("kimi.monthlyCode", pinned: true)
        let expectedOrder = store.accountSettingsMetrics(for: "kimi").map(\.id).filter { $0 != "kimi.monthlyCode" }

        store.replaceRegistry(registry)
        let relaunched = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        for current in [store, relaunched] {
            XCTAssertEqual(current.accountSettingsMetrics(for: "kimi").map(\.id), expectedOrder)
            XCTAssertEqual(current.placed.map(\.descriptorID), expectedOrder.filter { $0 != "kimi.weekly" })
            XCTAssertTrue(current.isMetricPinned("kimi.total"))
            XCTAssertFalse(current.isMetricPinned("kimi.monthlyCode"))
            XCTAssertFalse(current.isMetricEnabled("kimi.monthlyCode"))
        }
        XCTAssertEqual(defaults.stringArray(forKey: "layout.disabledMetrics"), ["kimi.weekly"])
    }
}
