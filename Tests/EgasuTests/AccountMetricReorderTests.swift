import XCTest
@testable import Egasu

@MainActor
final class AccountMetricReorderTests: XCTestCase {
    func testAccountMetricOrderSupportsUndoAndRelaunch() throws {
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
            registry: registry, defaults: defaults, storageKey: "layout"
        )
        let originalOrder = store.orderedSupportedMetrics(for: "test").map(\.id)

        XCTAssertTrue(
            store.reorderMetric(
                dragged: "test.second", target: "test.first", in: "test"
            ))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "test").map(\.id), ["test.second", "test.first"])
        let restored = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(restored.orderedSupportedMetrics(for: "test").map(\.id), ["test.second", "test.first"])

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedSupportedMetrics(for: "test").map(\.id), originalOrder)
    }
}
