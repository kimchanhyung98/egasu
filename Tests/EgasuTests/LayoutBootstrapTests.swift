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

    func testFreshMonthlyMetricsFollowEachProvidersWeeklyMetric() throws {
        let (_, defaults) = makePersistence("MonthlyDefaults")
        let registry = WidgetRegistry.from([CodexProvider(), GrokProvider(), ZAIProvider()])
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        for (card, weekly, monthly) in [
            ("codex", "weekly", "monthly"), ("codex", "sparkWeekly", "sparkMonthly"),
            ("grok", "weekly", "monthly"), ("zai", "weekly", "monthly")
        ] {
            let ids = AppContainer.dashboardMetricDescriptors(for: card, in: layout).map(\.id)
            let index = try XCTUnwrap(ids.firstIndex(of: "\(card).\(weekly)"))
            XCTAssertEqual(ids.dropFirst(index + 1).first, "\(card).\(monthly)")
        }
    }

    func testUpgradeInsertsOnlyMissingMonthlyMetricsAndKeepsLaterEdits() {
        let (persistence, defaults) = makePersistence("MonthlyExisting")
        let card = "codex@profile-work"
        let registry = WidgetRegistry.from([
            CodexProvider(), CodexProvider(provider: CodexProvider.makeProvider(id: card)),
            GrokProvider(), ZAIProvider()
        ])
        persistence.saveDisabledMetrics(["\(card).session", "grok.payAsYouGo"])
        persistence.savePriorityPins(["codex.weekly", "\(card).sparkWeekly"])
        persistence.saveMetricOrder([
            "codex": ["codex.sparkWeekly", "codex.trend", "codex.weekly", "codex.session"],
            card: ["\(card).weekly", "\(card).session", "\(card).sparkWeekly", "\(card).credits"],
            "grok": ["grok.weekly", "grok.today", "grok.payAsYouGo"],
            "zai": ["zai.weekly", "zai.webSearches", "zai.monthly"]
        ])

        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(
            Array(layout.metricOrder(for: "codex").prefix(6)),
            [
                "codex.sparkWeekly", "codex.sparkMonthly", "codex.trend", "codex.weekly", "codex.monthly",
                "codex.session"
            ])
        XCTAssertEqual(
            Array(layout.metricOrder(for: card).prefix(6)),
            ["weekly", "monthly", "session", "sparkWeekly", "sparkMonthly", "credits"].map { "\(card).\($0)" })
        XCTAssertEqual(
            Array(layout.metricOrder(for: "grok").prefix(4)),
            ["grok.weekly", "grok.monthly", "grok.today", "grok.payAsYouGo"])
        XCTAssertEqual(
            Array(layout.metricOrder(for: "zai").prefix(3)), ["zai.weekly", "zai.webSearches", "zai.monthly"])
        XCTAssertEqual(
            AppContainer.dashboardMetricDescriptors(for: card, in: layout).prefix(4).map(\.id),
            ["weekly", "monthly", "sparkWeekly", "sparkMonthly"].map { "\(card).\($0)" })
        XCTAssertTrue(layout.reorderMetric(dragged: "\(card).monthly", target: "\(card).credits", in: card))
        layout.setMetricEnabled("codex.monthly", false)

        let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(
            Array(reloaded.metricOrder(for: card).prefix(6)),
            ["weekly", "session", "sparkWeekly", "sparkMonthly", "credits", "monthly"].map { "\(card).\($0)" })
        XCTAssertFalse(reloaded.isMetricEnabled("codex.monthly"))
        XCTAssertFalse(reloaded.isMetricEnabled("\(card).session"))
        XCTAssertFalse(reloaded.isMetricEnabled("grok.payAsYouGo"))
        XCTAssertTrue(reloaded.isMetricEnabled("\(card).monthly"))
        XCTAssertEqual(reloaded.priorityPinIDs, ["codex.weekly", "\(card).sparkWeekly"])
    }

    func testLegacyOnDemandWeeklyKeepsItsNewMonthlyMetricOnEveryCard() {
        let (persistence, defaults) = makePersistence("MonthlyLegacy")
        let card = "codex@profile-work"
        let registry = WidgetRegistry.from([
            CodexProvider(), CodexProvider(provider: CodexProvider.makeProvider(id: card))
        ])
        persistence.savePlaced([
            PlacedWidget(descriptorID: "codex.weekly"), PlacedWidget(descriptorID: "codex.sparkWeekly")
        ])
        persistence.saveMetricOrder(["codex": ["codex.weekly", "codex.credits", "codex.sparkWeekly"]])
        defaults.set(["codex.weekly"], forKey: "layout.expandedMetrics")

        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        for id in ["codex", card] {
            XCTAssertEqual(
                AppContainer.dashboardMetricDescriptors(for: id, in: layout).map(\.id),
                ["sparkWeekly", "sparkMonthly", "weekly", "monthly"].map { "\(id).\($0)" })
            XCTAssertFalse(layout.isMetricEnabled("\(id).credits"))
        }
        XCTAssertFalse(persistence.hasOnDemandState)
    }

    func testUpgradeAfterAnAccountSwitchInsertsMonthlyBeforeSharedHistory() {
        let (persistence, defaults) = makePersistence("MonthlyAccountSwitch")
        let work = AccountUsageCardPlanner.cardID(family: "codex", profileID: "work")
        let personal = AccountUsageCardPlanner.cardID(family: "codex", profileID: "personal")
        let old = WidgetRegistry.from([CodexProvider(), CodexProvider(provider: CodexProvider.makeProvider(id: work))])
        persistence.reconcileAccountProfiles(["codex": "personal", work: "work"], registry: old)
        persistence.saveDisabledMetrics([])
        persistence.saveMetricOrder([
            "codex": ["codex.weekly", "codex.trend", "codex.credits"],
            work: ["\(work).weekly", "\(work).credits"]
        ])
        let current = WidgetRegistry.from([
            CodexProvider(), CodexProvider(provider: CodexProvider.makeProvider(id: personal))
        ])

        let layout = LayoutStore(
            registry: current, defaults: defaults, storageKey: "layout",
            profileIDsByCardID: ["codex": "work", personal: "personal"])

        XCTAssertEqual(
            AppContainer.dashboardMetricDescriptors(for: "codex", in: layout).prefix(4).map(\.id),
            ["codex.weekly", "codex.monthly", "codex.trend", "codex.credits"])
        XCTAssertEqual(
            AppContainer.dashboardMetricDescriptors(for: personal, in: layout).prefix(3).map(\.id),
            ["weekly", "monthly", "credits"].map { "\(personal).\($0)" })
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
