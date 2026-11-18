import XCTest
@testable import Egasu

@MainActor
final class PriorityPinPersistenceTests: XCTestCase {
    func testFreshPinsAreEmptyAndSeveralShownMetricsCanBePinnedPerAccount() {
        let store = makeStore(defaults: makeDefaults(), catalog: catalog())
        XCTAssertTrue(store.priorityPinIDs.isEmpty)
        for suffix in ["session", "weekly", "credits"] {
            let id = "codex.\(suffix)"
            XCTAssertTrue(store.isMetricEnabled(id))
            store.setMetric(id, pinned: true)
            XCTAssertTrue(store.isMetricPinned(id))
        }
        XCTAssertEqual(store.priorityPinIDs.count, 3, "고정 개수는 이전 프로바이더별 2개 제한과 독립")
    }

    func testMenuBarDisplayPreferencesKeepTheExistingStyleAndPersistNewChoices() {
        let defaults = makeDefaults()
        defaults.set(MenuBarStyle.bars.rawValue, forKey: "openusage.layout.v1.menuBarStyle")
        let settings = DisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(settings.menuBarStyle, .bars, "기존 표시 방식 저장 키 유지")
        settings.menuBarStyle = .text
        settings.menuBarLimit = .upToFive
        settings.menuBarSelection = .pinnedOnly
        settings.showsMenuBarExtras = false
        let relaunched = DisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(relaunched.menuBarStyle, .text)
        XCTAssertEqual(relaunched.menuBarLimit, .upToFive)
        XCTAssertEqual(relaunched.menuBarSelection, .pinnedOnly)
        XCTAssertFalse(relaunched.showsMenuBarExtras)
    }

    func testPersonalPinsStaySeparateAndSharedPinsUseOneFamilySetting() {
        let store = makeStore(defaults: makeDefaults(), catalog: catalog())
        let work = card("work")
        store.setMetric("codex.weekly", pinned: true)
        XCTAssertTrue(store.isMetricPinned("codex.weekly"))
        XCTAssertFalse(store.isMetricPinned("\(work).weekly"))
        store.setMetric("\(work).today", pinned: true)
        XCTAssertTrue(store.isMetricPinned("codex.today"))
        XCTAssertTrue(store.isMetricPinned("\(work).today"))
        XCTAssertTrue(store.priorityPinIDs.contains("codex.today"))
        XCTAssertFalse(store.priorityPinIDs.contains("\(work).today"))
        store.setMetric("codex.today", pinned: false)
        XCTAssertFalse(store.isMetricPinned("\(work).today"))
        XCTAssertTrue(store.isMetricPinned("codex.weekly"))
    }

    func testHidingUnpinsOnlyThatScopeAndUndoRestoresVisibilityAndPin() {
        let store = makeStore(defaults: makeDefaults(), catalog: catalog())
        let work = card("work")
        store.setMetric("codex.weekly", pinned: true)
        store.setMetric("\(work).weekly", pinned: true)
        store.setMetricEnabled("\(work).weekly", false)
        XCTAssertFalse(store.isMetricPinned("\(work).weekly"))
        XCTAssertTrue(store.isMetricPinned("codex.weekly"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("\(work).weekly"))
        XCTAssertTrue(store.isMetricPinned("\(work).weekly"))
        store.setMetric("\(work).today", pinned: true)
        store.setMetricEnabled("\(work).today", false)
        XCTAssertFalse(store.isMetricPinned("codex.today"))
        XCTAssertFalse(store.isMetricEnabled("codex.today"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricPinned("codex.today"))
        XCTAssertTrue(store.isMetricEnabled("codex.today"))
    }

    func testHiddenUnknownAndChartMetricsCannotBeNewlyPinned() {
        let store = makeStore(defaults: makeDefaults(), catalog: catalog())
        store.setMetricEnabled("codex.weekly", false)
        for id in ["codex.weekly", "codex.trend", "missing.metric"] {
            store.setMetric(id, pinned: true)
            XCTAssertFalse(store.isMetricPinned(id), id)
        }
        XCTAssertTrue(store.priorityPinIDs.isEmpty)
    }

    func testPinsAndExplicitlyEmptyPinsPersistAcrossRelaunch() {
        let defaults = makeDefaults()
        var store = makeStore(defaults: defaults, catalog: catalog())
        store.setMetric("codex.weekly", pinned: true)
        store = makeStore(defaults: defaults, catalog: catalog())
        XCTAssertTrue(store.isMetricPinned("codex.weekly"))
        store.setMetric("codex.weekly", pinned: false)
        store = makeStore(defaults: defaults, catalog: catalog())
        XCTAssertTrue(store.priorityPinIDs.isEmpty)
        XCTAssertNil(store.migrateMenuBarStars())
        XCTAssertTrue(store.priorityPinIDs.isEmpty)
    }

    func testPinsFollowTheRegisteredProfilesAcrossRebindingAndRelaunch() {
        let defaults = makeDefaults()
        let personal = catalog()
        let work = card("work")
        let personalCard = card("personal")
        let store = makeStore(defaults: defaults, catalog: personal)
        store.setMetric("codex.weekly", pinned: true)
        store.setMetric("\(work).session", pinned: true)
        store.setMetric("\(work).today", pinned: true)
        let switched = catalog(selected: "work")
        store.replaceRegistry(switched.registry, profileIDsByCardID: switched.mapping)
        XCTAssertTrue(store.isMetricPinned("\(personalCard).weekly"))
        XCTAssertTrue(store.isMetricPinned("codex.session"))
        XCTAssertFalse(store.isMetricPinned("codex.weekly"))
        XCTAssertTrue(store.isMetricPinned("codex.today"))
        XCTAssertFalse(store.canUndo, "다른 프로필에 이전 카드 ID의 undo 적용 금지")
        let relaunched = makeStore(defaults: defaults, catalog: switched)
        XCTAssertEqual(relaunched.priorityPinIDs, store.priorityPinIDs)
        relaunched.replaceRegistry(personal.registry, profileIDsByCardID: personal.mapping)
        XCTAssertTrue(relaunched.isMetricPinned("codex.weekly"))
        XCTAssertTrue(relaunched.isMetricPinned("\(work).session"))
        XCTAssertTrue(relaunched.isMetricPinned("codex.today"))
        XCTAssertFalse(relaunched.isMetricPinned("\(work).weekly"))
    }

    func testTemporarilyUnavailableProfilesKeepTheirOwnPinsForTheirReturn() {
        let defaults = makeDefaults()
        let original = catalog(profileIDs: ["personal"])
        let store = makeStore(defaults: defaults, catalog: original)
        store.setMetric("codex.weekly", pinned: true)
        let other = catalog(selected: "work", profileIDs: ["work"])
        store.replaceRegistry(other.registry, profileIDsByCardID: other.mapping)
        XCTAssertFalse(store.isMetricPinned("codex.weekly"), "다른 계정에 고정 전달 금지")
        XCTAssertTrue(store.priorityPinIDs.contains("\(card("personal")).weekly"))
        let returned = makeStore(defaults: defaults, catalog: original)
        XCTAssertTrue(returned.isMetricPinned("codex.weekly"))
    }

    func testUnknownSavedPinsStayDormantUntilTheirMetricReturns() {
        let defaults = makeDefaults()
        LayoutPersistence(defaults: defaults, storageKey: "layout").savePriorityPins(["future.meter"])
        let fixture = catalog()
        let store = makeStore(defaults: defaults, catalog: fixture)
        XCTAssertTrue(store.priorityPinIDs.contains("future.meter"))
        XCTAssertFalse(store.isMetricPinned("future.meter"))
        let future = Provider(id: "future", displayName: "Future", icon: .providerMark("codex"))
        let registry = WidgetRegistry(
            providers: fixture.registry.providers + [future],
            descriptors: fixture.registry.descriptors + [
                WidgetDescriptor.percent(id: "future.meter", provider: future, title: "Meter")
            ])
        store.replaceRegistry(registry, profileIDsByCardID: fixture.mapping)
        XCTAssertTrue(store.isMetricPinned("future.meter"))
    }

    func testLegacyCustomStarsExpandOnceAndNeverPinChartsOrLaterAccounts() {
        let defaults = makeDefaults()
        LayoutPersistence(defaults: defaults, storageKey: "layout").savePins(["codex.weekly", "codex.trend"])
        let store = makeStore(defaults: defaults, catalog: catalog())
        XCTAssertEqual(store.migrateMenuBarStars(), 2)
        XCTAssertEqual(store.priorityPinIDs, ["codex.weekly", "\(card("work")).weekly"])
        let expanded = catalog(profileIDs: ["personal", "work", "later"])
        store.replaceRegistry(expanded.registry, profileIDsByCardID: expanded.mapping)
        XCTAssertNil(store.migrateMenuBarStars())
        XCTAssertFalse(store.isMetricPinned("\(card("later")).weekly"))
        XCTAssertFalse(store.isMetricPinned("codex.trend"))
    }

    func testSavedPriorityChoiceWinsOverOldStarsEvenWhenItIsEmpty() {
        for existing: Set<String> in [[], ["codex.session"]] {
            let defaults = makeDefaults()
            let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
            persistence.savePins(["codex.weekly"])
            persistence.savePriorityPins(existing)
            let store = makeStore(defaults: defaults, catalog: catalog())
            XCTAssertNil(store.migrateMenuBarStars())
            XCTAssertEqual(store.priorityPinIDs, existing)
        }
    }

    private func card(_ profile: String) -> String {
        AccountUsageCardPlanner.cardID(family: "codex", profileID: profile)
    }

    private func catalog(selected: String = "personal", profileIDs: [String] = ["personal", "work"])
        -> (registry: WidgetRegistry, mapping: [String: String])
    {
        let others = profileIDs.filter { $0 != selected }
        let providers = (["codex"] + others.map(card)).map { CodexProvider.makeProvider(id: $0) }
        var mapping = Dictionary(uniqueKeysWithValues: others.map { (card($0), $0) })
        mapping["codex"] = selected
        let descriptors = providers.flatMap { provider in
            ["session", "weekly", "credits"].map {
                WidgetDescriptor.percent(id: "\(provider.id).\($0)", provider: provider, title: $0)
            } + [
                WidgetDescriptor.values(
                    id: "\(provider.id).today", provider: provider, title: "Today", isUsagePeriod: true),
                WidgetDescriptor.usageTrend(provider: provider)
            ]
        }
        return (WidgetRegistry(providers: providers, descriptors: descriptors), mapping)
    }

    private func makeStore(defaults: UserDefaults, catalog: (registry: WidgetRegistry, mapping: [String: String]))
        -> LayoutStore
    {
        LayoutStore(
            registry: catalog.registry, defaults: defaults, storageKey: "layout",
            defaultPinnedMetricIDs: [], defaultExpandedMetricIDs: [], profileIDsByCardID: catalog.mapping)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "EgasuTests.PriorityPins.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }
}
