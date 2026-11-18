import XCTest
@testable import Egasu

@MainActor
final class LegacyOnDemandMigrationTests: XCTestCase {
    func testGroupingFlattensOnceAndSubsequentMetricOrderPersists() throws {
        let defaults = try makeDefaults()
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")
        defaults.set(["claude"], forKey: "layout.expandedProviders")
        defaults.set(["claude.weekly"], forKey: "layout.expandOnEnable")
        try saveOrder(["claude": ["claude.weekly", "claude.session"]], in: defaults)
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let registry = WidgetRegistry(
            providers: [provider],
            descriptors: [
                .percent(id: "claude.session", provider: provider, title: "Session"),
                .percent(id: "claude.weekly", provider: provider, title: "Weekly")
            ])
        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.displayGroups.first?.widgets.map(\.descriptorID), ["claude.session", "claude.weekly"])
        for suffix in ["expandedMetrics", "expandedProviders", "expandOnEnable"] {
            XCTAssertNil(defaults.object(forKey: "layout." + suffix))
        }
        XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))

        let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(reloaded.displayGroups.first?.widgets.map(\.descriptorID), ["claude.weekly", "claude.session"])
    }

    func testCardOnlySharedHistoryGroupingIsPromotedBeforeClearing() throws {
        let defaults = try makeDefaults()
        let card = "claude@profile-work"
        defaults.set([card + ".trend"], forKey: "layout.expandedMetrics")
        try saveOrder(["claude": ["claude.trend", "claude.session"]], in: defaults)
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let extra = Provider(id: card, displayName: "Work", icon: .providerMark("claude"))
        let registry = WidgetRegistry(
            providers: [provider, extra],
            descriptors: [
                .usageTrend(provider: provider),
                .percent(id: "claude.session", provider: provider, title: "Session"),
                .percent(id: card + ".session", provider: extra, title: "Session")
            ])

        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.metricOrder(for: "claude"), ["claude.session", "claude.trend"])
        XCTAssertTrue(store.isMetricEnabled("claude.trend"))
        XCTAssertTrue(store.isMetricEnabled(card + ".session"))
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
    }

    private func makeDefaults() throws -> UserDefaults {
        let suite = "EgasuTests.LegacyOnDemand.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func saveOrder(_ order: [String: [String]], in defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(order), forKey: "layout.metricOrderByProvider")
    }
}
