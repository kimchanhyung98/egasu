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

    func testFlatOrderSavedWithPriorityPinsSurvivesRemovingOnDemandState() throws {
        let defaults = try makeDefaults()
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")
        defaults.set([String](), forKey: "layout.priorityPins")
        let savedOrder = ["claude.weekly", "claude.session"]
        try saveOrder(["claude": savedOrder], in: defaults)
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let registry = WidgetRegistry(
            providers: [provider],
            descriptors: [
                .percent(id: "claude.session", provider: provider, title: "Session"),
                .percent(id: "claude.weekly", provider: provider, title: "Weekly")
            ])

        let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.metricOrder(for: "claude"), savedOrder)
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
        let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(reloaded.metricOrder(for: "claude"), savedOrder)
    }

    func testQueueOnlyOnDemandStateKeepsHiddenMetricAtEnd() throws {
        let defaults = try makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([
            PlacedWidget(descriptorID: "claude.session"),
            PlacedWidget(descriptorID: "claude.weekly")
        ])
        try saveOrder(["claude": ["claude.extra", "claude.weekly", "claude.session"]], in: defaults)
        defaults.set(["claude.extra"], forKey: "layout.expandOnEnable")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("claude.extra"))
        XCTAssertEqual(store.metricOrder(for: "claude").last, "claude.extra")
        XCTAssertNil(defaults.object(forKey: "layout.expandOnEnable"))

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        reloaded.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(
            reloaded.displayGroups.first?.widgets.map(\.descriptorID),
            [
                "claude.weekly", "claude.session", "claude.extra"
            ])
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
