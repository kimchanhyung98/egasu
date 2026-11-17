import XCTest
@testable import Egasu

@MainActor
final class AccountMetricReorderTests: XCTestCase {
    func testAccountOrderKeepsLegacyExpansionUndoAndRelaunch() throws {
        let name = "EgasuTests.AccountMetricOrder.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let registry = WidgetRegistry(
            providers: [provider],
            descriptors: ["first", "second"].map {
                WidgetDescriptor.percent(id: "test." + $0, provider: provider, title: $0)
            })
        let store = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout", defaultExpandedMetricIDs: ["test.second"]
        )
        let originalOrder = store.orderedSupportedMetrics(for: "test").map(\.id)
        let expanded = store.expandedMetricIDs
        let pending = store.defaultExpandedOnEnableIDs
        XCTAssertTrue(store.isExpandedMetric("test.second"))
        XCTAssertFalse(store.isExpandedMetric("test.first"))

        XCTAssertTrue(
            store.reorderMetric(
                dragged: "test.second", target: "test.first", in: "test", preservingExpandedMembership: true
            ))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "test").map(\.id), ["test.second", "test.first"])
        XCTAssertEqual(store.expandedMetricIDs, expanded)
        XCTAssertEqual(store.defaultExpandedOnEnableIDs, pending)
        let restored = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(restored.orderedSupportedMetrics(for: "test").map(\.id), ["test.second", "test.first"])
        XCTAssertEqual(restored.expandedMetricIDs, expanded)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedSupportedMetrics(for: "test").map(\.id), originalOrder)
        XCTAssertEqual(store.expandedMetricIDs, expanded)
        XCTAssertEqual(store.defaultExpandedOnEnableIDs, pending)
    }
}
