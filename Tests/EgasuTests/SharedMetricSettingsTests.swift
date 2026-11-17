import XCTest
@testable import Egasu

@MainActor
final class SharedMetricSettingsTests: XCTestCase {
    func testEachAccountUsesTheSameSharedSettingsAndKeepsQuotaSettingsSeparate() {
        for family in ["claude", "codex"] {
            let fixture = catalog(family: family)
            let store = makeStore(defaults: makeDefaults(), catalog: fixture)
            let workID = cardID(family: family, profile: "work")
            let sharedIDs = sharedSuffixes(family: family).map { "\(family).\($0)" }

            XCTAssertEqual(store.sharedSettingsMetrics(for: family).map(\.id), sharedIDs)
            XCTAssertEqual(store.sharedSettingsMetrics(for: workID).map(\.id), sharedIDs)
            XCTAssertEqual(
                store.accountSettingsMetrics(for: workID).map(\.id),
                accountSuffixes(family: family).map { "\(workID).\($0)" }
            )
            XCTAssertEqual(
                store.accountSettingsMetrics(for: family).map(\.id),
                accountSuffixes(family: family).map { "\(family).\($0)" }
            )
            store.setMetricEnabled("\(workID).weekly", false)
            XCTAssertFalse(store.isMetricEnabled("\(workID).weekly"))
            XCTAssertTrue(store.isMetricEnabled("\(family).weekly"))
            assertNoSharedAliases(store)
        }
    }

    func testSharedControlsFromAnotherAccountSupportOrderAndUndo() throws {
        let store = makeStore(defaults: makeDefaults(), catalog: catalog())
        let workID = cardID(profile: "work")
        let today = try XCTUnwrap(store.sharedSettingsMetrics(for: workID).first { $0.id == "codex.today" })
        let originalOrder = store.sharedSettingsMetrics(for: "codex").map(\.id)

        XCTAssertTrue(store.reorderMetric(dragged: "codex.last30", target: today.id, in: today.providerID))
        XCTAssertEqual(
            store.sharedSettingsMetrics(for: workID).map(\.id), store.sharedSettingsMetrics(for: "codex").map(\.id))
        XCTAssertNotEqual(store.sharedSettingsMetrics(for: workID).map(\.id), originalOrder)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.sharedSettingsMetrics(for: workID).map(\.id), originalOrder)

        store.setMetricEnabled(today.id, false)
        XCTAssertFalse(store.isMetricEnabled("codex.today"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("codex.today"))
        assertNoSharedAliases(store)
    }

    func testMigrationKeepsBareChoicesWhenExtraCardsContainSharedCopies() throws {
        for hasSeededCards in [false, true] {
            let defaults = makeDefaults()
            let fixture = catalog()
            let workID = cardID(profile: "work")
            let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
            persistence.savePlaced(
                ["codex.session", "codex.last30", "\(workID).today", "\(workID).trend"].map {
                    PlacedWidget(descriptorID: $0)
                })
            persistence.saveMetricOrder([
                "codex": ["codex.last30", "codex.session", "codex.today", "codex.trend"],
                workID: ["\(workID).today", "\(workID).weekly", "\(workID).trend"]
            ])
            persistence.savePriorityPins(["codex.last30", "\(workID).today"])
            persistence.saveSeededDefaults(Set(defaultIDs(family: "codex")))
            if hasSeededCards { persistence.saveSeededCards(Set(fixture.mapping.keys)) }
            defaults.set(try JSONEncoder().encode(fixture.mapping), forKey: "layout.accountProfilesByCard")

            let store = makeStore(defaults: defaults, catalog: fixture)
            XCTAssertFalse(store.isMetricEnabled("codex.today"), "추가 계정의 ON 값으로 기존 공통 OFF를 덮지 않음")
            XCTAssertFalse(store.isMetricEnabled("codex.trend"))
            XCTAssertTrue(store.isMetricEnabled("codex.last30"))
            XCTAssertEqual(
                Array(store.sharedSettingsMetrics(for: workID).map(\.id).prefix(3)),
                ["codex.last30", "codex.today", "codex.trend"])
            assertNoSharedAliases(store)
            assertNoSharedAliases(makeStore(defaults: defaults, catalog: fixture))
        }
    }

    func testSharedSettingsStayPutAcrossProfileSwitchRelaunchAndReturn() {
        for switchWhileClosed in [false, true] {
            let defaults = makeDefaults()
            let initial = catalog()
            var store = makeStore(defaults: defaults, catalog: initial)
            let workID = cardID(profile: "work")
            let personalID = cardID(profile: "personal")
            store.setMetricEnabled("codex.today", false)
            XCTAssertTrue(store.reorderMetric(dragged: "codex.last30", target: "codex.trend", in: "codex"))
            XCTAssertTrue(store.reorderMetric(dragged: "codex.credits", target: "codex.session", in: "codex"))
            XCTAssertTrue(store.reorderMetric(dragged: "\(workID).weekly", target: "\(workID).session", in: workID))
            store.setMetricEnabled("\(workID).weekly", false)
            let sharedOrder = store.sharedSettingsMetrics(for: "codex").map(\.id)
            let personalOrder = canonicalAccountOrder(store, cardID: "codex")
            let workOrder = canonicalAccountOrder(store, cardID: workID)
            let next = catalog(selected: "work")

            if switchWhileClosed {
                store = makeStore(defaults: defaults, catalog: next)
            } else {
                store.replaceRegistry(next.registry, profileIDsByCardID: next.mapping)
            }
            assertSharedState(store, order: sharedOrder)
            XCTAssertEqual(canonicalAccountOrder(store, cardID: "codex"), workOrder)
            XCTAssertEqual(canonicalAccountOrder(store, cardID: personalID), personalOrder)
            XCTAssertFalse(store.isMetricEnabled("codex.weekly"))
            XCTAssertFalse(store.canUndo)

            let relaunched = makeStore(defaults: defaults, catalog: next)
            assertSharedState(relaunched, order: sharedOrder)
            relaunched.replaceRegistry(initial.registry, profileIDsByCardID: initial.mapping)
            assertSharedState(relaunched, order: sharedOrder)
            XCTAssertEqual(canonicalAccountOrder(relaunched, cardID: "codex"), personalOrder)
            XCTAssertEqual(canonicalAccountOrder(relaunched, cardID: workID), workOrder)
            XCTAssertTrue(relaunched.isMetricEnabled("codex.weekly"))
            XCTAssertFalse(relaunched.isMetricEnabled("\(workID).weekly"))
        }
    }

    func testReplacingTheOnlyProfileDoesNotReseedSharedDefaults() {
        let defaults = makeDefaults()
        let personal = catalog(profiles: ["personal"])
        let store = makeStore(defaults: defaults, catalog: personal)
        store.setMetricEnabled("codex.today", false)
        store.setMetricEnabled("codex.weekly", false)
        let work = catalog(selected: "work", profiles: ["work"])
        XCTAssertEqual(personal.registry.providers, work.registry.providers)

        store.replaceRegistry(work.registry, profileIDsByCardID: work.mapping)

        XCTAssertFalse(store.isMetricEnabled("codex.today"))
        XCTAssertTrue(store.isMetricEnabled("codex.weekly"), "새 프로필의 개인 지표는 앱 기본값 사용")
        let restored = makeStore(defaults: defaults, catalog: personal)
        XCTAssertFalse(restored.isMetricEnabled("codex.today"))
        XCTAssertFalse(restored.isMetricEnabled("codex.weekly"))
        assertNoSharedAliases(restored)
    }

    func testAddingAnAccountDoesNotReenableSharedMetrics() {
        let store = makeStore(defaults: makeDefaults(), catalog: catalog())
        store.setMetricEnabled("codex.today", false)
        store.setMetricEnabled("codex.weekly", false)
        let next = catalog(profiles: ["personal", "work", "new"])

        store.replaceRegistry(next.registry, profileIDsByCardID: next.mapping)

        XCTAssertFalse(store.isMetricEnabled("codex.today"))
        XCTAssertTrue(store.isMetricEnabled("\(cardID(profile: "new")).weekly"))
        XCTAssertFalse(store.isMetricEnabled("codex.weekly"))
        assertNoSharedAliases(store)
    }

    func testANewSharedDefaultIsSeededOnlyOnceAtTheCanonicalID() {
        let defaults = makeDefaults()
        let fixture = catalog()
        let originalDefaults = ["codex.session", "codex.weekly", "codex.today"]
        let oldCatalog = Catalog(
            family: fixture.family,
            registry: WidgetRegistry(
                providers: fixture.registry.providers,
                descriptors: fixture.registry.descriptors.filter { !$0.id.hasSuffix(".last30") }
            ),
            mapping: fixture.mapping
        )
        let initial = makeStore(defaults: defaults, catalog: oldCatalog, defaultsIDs: originalDefaults)
        initial.setMetricEnabled("codex.today", false)
        let updatedDefaults = originalDefaults + ["codex.last30"]

        let updated = makeStore(defaults: defaults, catalog: fixture, defaultsIDs: updatedDefaults)

        XCTAssertFalse(updated.isMetricEnabled("codex.today"))
        XCTAssertEqual(
            updated.placed.filter { $0.descriptorID.hasSuffix(".last30") }.map(\.descriptorID), ["codex.last30"])
        updated.setMetricEnabled("codex.last30", false)
        let relaunched = makeStore(defaults: defaults, catalog: fixture, defaultsIDs: updatedDefaults)
        XCTAssertFalse(relaunched.isMetricEnabled("codex.last30"))
        assertNoSharedAliases(relaunched)
    }

    func testSharedSettingsSurviveWhenTheBareCardTemporarilyDisappears() {
        let defaults = makeDefaults()
        let initial = catalog()
        let store = makeStore(defaults: defaults, catalog: initial)
        store.setMetricEnabled("codex.today", false)
        XCTAssertTrue(store.reorderMetric(dragged: "codex.last30", target: "codex.trend", in: "codex"))
        let order = store.sharedSettingsMetrics(for: "codex").map(\.id)
        let absent = catalog(includeBare: false)

        store.replaceRegistry(absent.registry, profileIDsByCardID: absent.mapping)
        let relaunched = makeStore(defaults: defaults, catalog: absent)
        XCTAssertFalse(defaults.stringArray(forKey: "layout.disabledMetrics")?.contains("codex.last30") ?? true)
        XCTAssertFalse(relaunched.placed.contains { $0.descriptorID == "codex.today" })
        relaunched.replaceRegistry(initial.registry, profileIDsByCardID: initial.mapping)

        assertSharedState(relaunched, order: order)
    }

    private struct Catalog {
        let family: String
        let registry: WidgetRegistry
        let mapping: [String: String]
    }

    private func catalog(
        family: String = "codex", selected: String = "personal",
        profiles: [String] = ["personal", "work"], includeBare: Bool = true
    ) -> Catalog {
        var mapping = Dictionary(
            uniqueKeysWithValues: profiles.filter { !includeBare || $0 != selected }.map {
                (cardID(family: family, profile: $0), $0)
            })
        if includeBare { mapping[family] = selected }
        let ids =
            (includeBare ? [family] : [])
            + profiles.filter { !includeBare || $0 != selected }.map {
                cardID(family: family, profile: $0)
            }
        let providers = ids.map { Provider(id: $0, displayName: $0, icon: .providerMark(family)) }
        let descriptors = providers.flatMap { provider in
            (accountSuffixes(family: family) + sharedSuffixes(family: family)).map { suffix in
                WidgetDescriptor(
                    id: "\(provider.id).\(suffix)", providerID: provider.id, metricLabel: suffix,
                    sample: WidgetData(title: suffix, icon: provider.icon, kind: .percent, used: 0, limit: 100),
                    pinnable: suffix != "trend"
                )
            }
        }
        return Catalog(
            family: family, registry: WidgetRegistry(providers: providers, descriptors: descriptors), mapping: mapping)
    }

    private func accountSuffixes(family: String) -> [String] {
        family == "claude"
            ? ["session", "weekly", "fable", "sonnet", "extra"]
            : ["session", "weekly", "spark", "sparkWeekly", "rateLimitResets", "credits"]
    }

    private func sharedSuffixes(family: String) -> [String] {
        ["trend", "today", "yesterday", "last30"] + (family == "codex" ? ["resetWatch"] : [])
    }

    private func defaultIDs(family: String) -> [String] {
        (accountSuffixes(family: family) + sharedSuffixes(family: family)).map { "\(family).\($0)" }
    }

    private func makeStore(defaults: UserDefaults, catalog: Catalog, defaultsIDs: [String]? = nil) -> LayoutStore {
        let ids = defaultsIDs ?? defaultIDs(family: catalog.family)
        return LayoutStore(
            registry: catalog.registry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ids, migrationBaselineMetricIDs: ids, defaultPinnedMetricIDs: [],
            profileIDsByCardID: catalog.mapping
        )
    }

    private func cardID(family: String = "codex", profile: String) -> String {
        AccountUsageCardPlanner.cardID(family: family, profileID: profile)
    }

    private func canonicalAccountOrder(_ store: LayoutStore, cardID: String) -> [String] {
        store.accountSettingsMetrics(for: cardID).map { ProviderAccountID.canonicalMetricID($0.id) }
    }

    private func assertSharedState(
        _ store: LayoutStore, order: [String], file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(store.isMetricEnabled("codex.today"), file: file, line: line)
        XCTAssertTrue(store.isMetricEnabled("codex.last30"), file: file, line: line)
        XCTAssertEqual(store.sharedSettingsMetrics(for: "codex").map(\.id), order, file: file, line: line)
        assertNoSharedAliases(store, file: file, line: line)
    }

    private func assertNoSharedAliases(_ store: LayoutStore, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(
            store.placed.contains { ProviderAccountID.isSharedMetricAlias($0.descriptorID) }, file: file, line: line)
        XCTAssertFalse(
            store.metricOrderByProvider.values.joined().contains(where: ProviderAccountID.isSharedMetricAlias),
            file: file, line: line)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "EgasuTests.SharedMetricSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
