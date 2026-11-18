import XCTest
@testable import Egasu

@MainActor
final class LayoutBootstrapTests: XCTestCase {
    func testFreshInstallUsesCurrentDefaults() {
        let (persistence, _) = makePersistence("Fresh")

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session", "claude.weekly"])
        XCTAssertFalse(state.disabledMetricIDs.contains("claude.session"))
        XCTAssertFalse(state.disabledMetricIDs.contains("claude.weekly"))
        XCTAssertTrue(state.disabledMetricIDs.contains("claude.extra"))
        XCTAssertTrue(state.shouldPersistVisibility)
        XCTAssertFalse(state.shouldClearOnDemandState, "새 설치에는 옛 캐럿 키가 없음")
    }

    func testSavedOnDemandSplitFlattensOnceIntoTheShownOrder() {
        // 옛 화면 순서(항상 표시 → On Demand)를 그대로 평탄한 순서로 저장, 켜면 On Demand로 갈 꺼진 지표도 뒤로.
        let (persistence, defaults) = makePersistence("FlattenOnDemand")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session"), PlacedWidget(descriptorID: "claude.weekly")])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.extra", "claude.session"]])
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")
        defaults.set(["claude.extra"], forKey: "layout.expandOnEnable")
        defaults.set(["claude"], forKey: "layout.expandedProviders")

        let state = LayoutBootstrap.load(registry: .mock, persistence: persistence, defaults: makeDefaultSet())

        let order = state.metricOrderByProvider["claude"] ?? []
        XCTAssertEqual(order.first, "claude.session", "옛 항상 표시 행이 앞")
        XCTAssertEqual(Array(order.suffix(2)), ["claude.weekly", "claude.extra"], "옛 On Demand 행은 상대 순서를 지켜 뒤로")
        XCTAssertTrue(state.shouldPersistMetricOrder)
        XCTAssertTrue(state.shouldClearOnDemandState)
    }

    func testExistingLayoutUsesLegacyBaselineWithoutRestoringRemovedMetric() {
        let (persistence, _) = makePersistence("ExistingBaseline")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertTrue(state.disabledMetricIDs.contains("claude.weekly"))
        XCTAssertTrue(state.shouldPersistVisibility)
    }

    func testPreviouslySeededMetricStaysOffWhenUserDisabledIt() {
        let (persistence, _) = makePersistence("UserDisabled")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])

        let state = LayoutBootstrap.load(
            registry: .mock,
            persistence: persistence,
            defaults: makeDefaultSet()
        )

        XCTAssertEqual(state.placed.map(\.descriptorID), ["claude.session"])
        XCTAssertTrue(state.disabledMetricIDs.contains("claude.weekly"))
        XCTAssertTrue(state.shouldPersistVisibility)
    }

    private func makeDefaultSet() -> LayoutDefaultSet {
        LayoutDefaultSet(
            metricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )
    }

    private func makePersistence(_ name: String) -> (LayoutPersistence, UserDefaults) {
        let suite = "EgasuTests.LayoutBootstrap.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (LayoutPersistence(defaults: defaults, storageKey: "layout"), defaults)
    }
}
