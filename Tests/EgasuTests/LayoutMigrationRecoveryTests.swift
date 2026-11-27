import XCTest
@testable import Egasu

@MainActor
final class LayoutMigrationRecoveryTests: XCTestCase {
    func testExistingHiddenMetricInSavedOrderIsNotReenabled() {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])
        persistence.saveMetricOrder(["claude": ["claude.session", "claude.weekly", "claude.fable", "claude.extra"]])

        let store = LayoutStore(registry: registry(), defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isMetricEnabled("claude.fable"))
    }

    func testPreSeedMigrationEnablesOnlyUnknownLaterDefaults() {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveMetricOrder(["claude": ["claude.session", "claude.weekly"]])

        let store = LayoutStore(registry: registry(), defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.isMetricEnabled("claude.fable"))
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))
        XCTAssertFalse(store.isMetricEnabled("claude.sonnet"), "옛 선택 지표는 기본 ON 기준 목록에 없어도 새 지표가 아님")
    }

    func testNewProviderUsesMetricDefaultsWhenLegacyLayoutHasNoSavedCardList() {
        let registry = WidgetRegistry.from([ClaudeProvider(), CursorProvider(), DevinProvider(), DeepSeekProvider()])
        let deepSeekIDs = registry.descriptors(for: "deepseek").map(\.id)
        XCTAssertEqual(deepSeekIDs, ["deepseek.balanceUSD", "deepseek.balanceCNY", "deepseek.api"])

        for hasSavedOrder in [false, true] {
            let defaults = makeDefaults()
            let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
            persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
            let savedClaudeOrder = ["claude.weekly", "claude.session"]
            persistence.saveMetricOrder(["claude": savedClaudeOrder])
            if hasSavedOrder { persistence.saveProviderOrder(["cursor", "claude"]) }
            XCTAssertNil(persistence.loadSeededCards())

            let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

            XCTAssertEqual(deepSeekIDs.filter { store.isMetricEnabled($0) }, deepSeekIDs)
            XCTAssertTrue(store.isMetricEnabled("claude.session"))
            XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
            XCTAssertFalse(store.isMetricEnabled("devin.daily"))
            XCTAssertEqual(Array(store.metricOrder(for: "claude").prefix(2)), savedClaudeOrder)
            XCTAssertEqual(
                store.orderedProviderIDs(),
                (hasSavedOrder ? ["cursor", "claude"] : ["claude", "cursor"]) + ["devin", "deepseek"])

            store.setMetricEnabled("deepseek.balanceUSD", false)
            let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
            XCTAssertFalse(reloaded.isMetricEnabled("deepseek.balanceUSD"))
            XCTAssertTrue(reloaded.isMetricEnabled("deepseek.balanceCNY"))
        }
    }

    func testProviderRecordedInLegacyLayoutKeepsItsHiddenMetricsWithoutSavedCardList() {
        let registry = WidgetRegistry.from([ClaudeProvider(), DeepSeekProvider()])
        for hasSavedProviderOrder in [false, true] {
            let defaults = makeDefaults()
            let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
            persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
            if hasSavedProviderOrder {
                persistence.saveProviderOrder(["claude", "deepseek"])
            } else {
                persistence.saveSeededDefaults(["deepseek.balanceUSD"])
            }

            let store = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

            XCTAssertFalse(store.isMetricEnabled("deepseek.balanceUSD"))
        }
    }

    func testNewProviderDetectionDoesNotChangePendingLegacyVisibilityOnRelaunch() async throws {
        let providers: [any ProviderRuntime] = [
            ClaudeProvider(),
            DeepSeekProvider(files: FakeFiles(), environment: FakeEnvironment(["DEEPSEEK_API_KEY": "fixture-key"]))
        ]
        let registry = WidgetRegistry.from(providers)
        let deepSeekIDs = registry.descriptors(for: "deepseek").map(\.id)
        let storageKey = "openusage.layout.v1"

        for hideBalance in [false, true] {
            let defaults = makeDefaults()
            let persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
            persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
            let placed = try XCTUnwrap(persistence.loadPlaced())
            let badOrder = Data("unreadable-order".utf8)
            defaults.set(badOrder, forKey: "\(storageKey).metricOrderByProvider")
            XCTAssertNil(persistence.loadSeededCards())

            func launch() -> (LayoutStore, ProviderEnablementStore) {
                let enablement = ProviderEnablementStore(defaults: defaults)
                let layout = LayoutStore(
                    registry: registry, defaults: defaults, storageKey: storageKey,
                    knownCardIDs: enablement.knownIDs.union(enablement.enabledIDs ?? []),
                    isProviderEnabled: { enablement.isEnabled($0) }
                )
                return (layout, enablement)
            }

            let initialEnablement = ProviderEnablementStore(defaults: defaults)
            initialEnablement.seedEnabledProviders(["claude"])
            initialEnablement.registerKnownProviders(["claude"])
            let (firstLayout, firstEnablement) = launch()
            XCTAssertEqual(deepSeekIDs.filter { firstLayout.isMetricEnabled($0) }, deepSeekIDs)
            XCTAssertFalse(persistence.hasStoredDisabledMetrics)

            let detection = try XCTUnwrap(
                NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: firstEnablement))
            await detection.value
            firstLayout.setMetric("deepseek.balanceCNY", pinned: true)
            XCTAssertTrue(firstLayout.isMetricPinned("deepseek.balanceCNY"))

            let (pendingLayout, pendingEnablement) = launch()
            XCTAssertEqual(pendingEnablement.knownIDs, ["claude", "deepseek"])
            XCTAssertTrue(pendingEnablement.isEnabled("deepseek"))
            XCTAssertNil(NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: pendingEnablement))
            XCTAssertEqual(deepSeekIDs.filter { pendingLayout.isMetricEnabled($0) }, deepSeekIDs)
            XCTAssertTrue(pendingLayout.isMetricPinned("deepseek.balanceCNY"))
            XCTAssertFalse(pendingLayout.isMetricEnabled("claude.weekly"))
            XCTAssertFalse(persistence.hasStoredDisabledMetrics)
            XCTAssertEqual(persistence.loadPlaced(), placed)
            XCTAssertEqual(defaults.data(forKey: "\(storageKey).metricOrderByProvider"), badOrder)

            if hideBalance { pendingLayout.setMetricEnabled("deepseek.balanceUSD", false) }
            let repairedOrder = ["claude.weekly", "claude.session"]
            persistence.saveMetricOrder(["claude": repairedOrder])
            let (repairedLayout, repairedEnablement) = launch()

            let expected = hideBalance ? Array(deepSeekIDs.dropFirst()) : deepSeekIDs
            XCTAssertEqual(deepSeekIDs.filter { repairedLayout.isMetricEnabled($0) }, expected)
            XCTAssertTrue(repairedLayout.isMetricPinned("deepseek.balanceCNY"))
            XCTAssertTrue(repairedEnablement.knownIDs.contains("deepseek"))
            XCTAssertTrue(repairedLayout.isMetricEnabled("claude.session"))
            XCTAssertFalse(repairedLayout.isMetricEnabled("claude.weekly"))
            XCTAssertEqual(Array(repairedLayout.metricOrder(for: "claude").prefix(2)), repairedOrder)
            let persistedHidden = try XCTUnwrap(persistence.loadDisabledMetrics())
            XCTAssertEqual(Set(persistedHidden).intersection(deepSeekIDs), Set(deepSeekIDs).subtracting(expected))
            XCTAssertEqual(persistence.loadPlaced(), placed)
            XCTAssertTrue(persistence.deferredVisibility.isEmpty)
        }
    }

    func testExplicitEmptyLegacyLayoutDoesNotEnableNewDefaults() {
        for seeded in [false, true] {
            let defaults = makeDefaults()
            let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
            persistence.savePlaced([])
            if seeded { persistence.saveSeededDefaults(["claude.session", "claude.weekly"]) }

            let store = LayoutStore(registry: registry(), defaults: defaults, storageKey: "layout")

            XCTAssertTrue(store.placed.isEmpty)
        }
    }

    func testAbsentAccountFoundOnlyInLegacyPlacedKeepsHiddenMetricsOnReturn() {
        for seededCards in [false, true] {
            let defaults = makeDefaults()
            let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
            persistence.savePlaced([
                PlacedWidget(descriptorID: "claude.session"), PlacedWidget(descriptorID: "claude@absent.session")
            ])
            if seededCards { persistence.saveSeededCards(["claude"]) }
            let store = LayoutStore(registry: registry(), defaults: defaults, storageKey: "layout")

            store.replaceRegistry(registry(cards: ["claude", "claude@absent"]))

            XCTAssertTrue(store.isMetricEnabled("claude@absent.session"))
            XCTAssertFalse(store.isMetricEnabled("claude@absent.weekly"))
        }
    }

    func testUnreadableOrderPreservesVisibilityInputsAndRetriesAfterRepair() {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        let badOrder = Data("unreadable-order".utf8)
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])
        defaults.set(badOrder, forKey: "layout.metricOrderByProvider")
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")
        defaults.set(["claude.session"], forKey: "layout.menuBarPins")
        let broken = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout", defaultPinnedMetricIDs: [])
        _ = broken.migrateMenuBarStars()

        XCTAssertEqual(defaults.data(forKey: "layout.metricOrderByProvider"), badOrder)
        XCTAssertNil(defaults.object(forKey: "layout.disabledMetrics"))
        XCTAssertNil(defaults.object(forKey: "layout.priorityPins"))
        XCTAssertEqual(defaults.stringArray(forKey: "layout.expandedMetrics"), ["claude.weekly"])

        persistence.saveMetricOrder(["claude": ["claude.fable", "claude.weekly", "claude.session"]])
        let repaired = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout", defaultPinnedMetricIDs: [])

        XCTAssertFalse(repaired.isMetricEnabled("claude.fable"))
        XCTAssertTrue(repaired.metricOrder(for: "claude").first == "claude.fable")
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
        XCTAssertEqual(repaired.migrateMenuBarStars(), 1)
        XCTAssertTrue(repaired.isMetricPinned("claude.session"))
    }

    func testVisibilityEditsSurviveUnreadableOrderAndOnlyOverrideTheEditedAccount() {
        let defaults = makeDefaults()
        let files = LayoutPersistence(defaults: defaults, storageKey: "layout")
        let badOrder = Data("broken".utf8)
        defaults.set(badOrder, forKey: "layout.metricOrderByProvider")
        let a = AccountUsageCardPlanner.cardID(family: "claude", profileID: "a")
        let b = AccountUsageCardPlanner.cardID(family: "claude", profileID: "b")
        let mapping = ["claude": "a", b: "b"]
        files.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        files.saveSeededDefaults(["claude.session", "claude.weekly", "claude.today"])
        func store(_ other: String, _ mapping: [String: String]) -> LayoutStore {
            LayoutStore(registry: registry(cards: ["claude", other]), defaults: defaults, storageKey: "layout",
                        profileIDsByCardID: mapping)
        }
        let first = store(b, mapping)
        first.setMetricEnabled("claude.session", false)
        first.setMetricEnabled("claude.weekly", true)
        first.setMetricEnabled(b + ".today", true)
        first.setMetricEnabled("claude.fable", false)
        XCTAssertTrue(first.undo())

        let reloaded = store(b, mapping)
        XCTAssertFalse(reloaded.isMetricEnabled("claude.session"))
        XCTAssertTrue(reloaded.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(reloaded.isMetricEnabled("claude.today"))
        XCTAssertTrue(reloaded.isMetricEnabled(b + ".session"))
        XCTAssertFalse(reloaded.isMetricEnabled(b + ".weekly"))
        XCTAssertEqual(defaults.data(forKey: "layout.metricOrderByProvider"), badOrder)
        XCTAssertNil(defaults.object(forKey: "layout.disabledMetrics"))

        let switched = ["claude": "b", a: "a"]
        _ = store(a, switched)
        files.saveMetricOrder(["claude": ["claude.fable", "claude.weekly", "claude.session"]])
        let repaired = store(a, switched)
        XCTAssertFalse(repaired.isMetricEnabled(a + ".session"))
        XCTAssertTrue(repaired.isMetricEnabled(a + ".weekly"))
        XCTAssertTrue(repaired.isMetricEnabled("claude.today"))
        XCTAssertFalse(repaired.isMetricEnabled("claude.fable"), "실행 취소한 잠정 편집보다 복구한 순서 우선")
        XCTAssertNotNil(defaults.object(forKey: "layout.disabledMetrics"))
        XCTAssertNil(defaults.object(forKey: "layout.deferredVisibility"))
    }

    func testUnreadableVisibilityDoesNotCompleteStarMigration() {
        let defaults = makeDefaults()
        defaults.set("unreadable-visibility", forKey: "layout.disabledMetrics")
        defaults.set(["claude.session"], forKey: "layout.menuBarPins")
        let broken = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout", defaultPinnedMetricIDs: [])
        _ = broken.migrateMenuBarStars()

        XCTAssertNil(defaults.object(forKey: "layout.priorityPins"))
        XCTAssertEqual(defaults.string(forKey: "layout.disabledMetrics"), "unreadable-visibility")

        defaults.set([String](), forKey: "layout.disabledMetrics")
        let repaired = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout", defaultPinnedMetricIDs: [])
        XCTAssertEqual(repaired.migrateMenuBarStars(), 1)
        XCTAssertTrue(repaired.isMetricPinned("claude.session"))
    }

    func testUnreadableProfileMappingDefersPersonalSettingsWithoutLosingOtherEdits() throws {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        let badMapping = Data("unreadable-profile-mapping".utf8)
        let originalOrder = ["claude.weekly", "claude.session", "claude.today"]
        defaults.set(badMapping, forKey: "layout.accountProfilesByCard")
        persistence.saveDisabledMetrics(["claude.weekly", "claude.today"])
        persistence.savePriorityPins(["claude.session"])
        persistence.saveMetricOrder(["claude": originalOrder])
        let store = LayoutStore(
            registry: registry(cards: ["claude", "cursor"]), defaults: defaults, storageKey: "layout",
            profileIDsByCardID: ["claude": "new-profile"])

        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isMetricPinned("claude.session"))
        XCTAssertFalse(store.isMetricEnabled("claude.today"), "공통 지표는 계정 매핑에 의존하지 않음")
        XCTAssertEqual(
            store.metricOrder(for: "claude").filter { !ProviderAccountID.isSharedMetric($0) }.first, "claude.session")
        store.setMetricEnabled("cursor.weekly", false)
        XCTAssertTrue(store.undo())
        store.setMetricEnabled("cursor.weekly", false)
        store.setMetric("cursor.session", pinned: true)
        store.setMetricEnabled("claude.weekly", false)
        XCTAssertTrue(store.undo())

        XCTAssertEqual(defaults.data(forKey: "layout.accountProfilesByCard"), badMapping)
        XCTAssertEqual(persistence.loadMetricOrder()?["claude"], originalOrder)
        XCTAssertEqual(Set(persistence.loadDisabledMetrics() ?? []), ["claude.weekly", "claude.today", "cursor.weekly"])
        XCTAssertEqual(Set(persistence.loadPriorityPins() ?? []), ["claude.session", "cursor.session"])

        defaults.set(try JSONEncoder().encode(["claude": "new-profile"]), forKey: "layout.accountProfilesByCard")
        let repaired = LayoutStore(
            registry: registry(cards: ["claude", "cursor"]), defaults: defaults, storageKey: "layout",
            profileIDsByCardID: ["claude": "new-profile"])
        XCTAssertFalse(repaired.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(repaired.isMetricPinned("claude.session"))
        XCTAssertEqual(repaired.metricOrder(for: "claude").first, "claude.weekly")
        XCTAssertFalse(repaired.isMetricEnabled("cursor.weekly"))
        XCTAssertTrue(repaired.isMetricPinned("cursor.session"))
    }

    func testRestartBetweenRecoveredWritesPreservesNewMetricsAndAccountOrder() throws {
        let suite = "EgasuTests.SeedRecovery." + UUID().uuidString
        let defaults = try XCTUnwrap(RecordingLayoutMigrationDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let files = LayoutPersistence(defaults: defaults, storageKey: "layout")
        files.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        defaults.set("bad", forKey: "layout.seededDefaults")
        let card = AccountUsageCardPlanner.cardID(family: "claude", profileID: "b")
        let registry = registry(cards: ["claude", card])
        files.saveMetricOrder(["claude": ["claude.weekly", "claude.session"]])
        _ = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        files.saveSeededDefaults(["claude.session", "claude.weekly"])
        defaults.migrationSnapshotDomain = suite
        _ = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")

        for key in ["layout.metricOrderByProvider", "layout.disabledMetrics"] {
            let restored = makeDefaults()
            for (key, value) in try XCTUnwrap(defaults.migrationSnapshots[key]) {
                restored.set(value, forKey: key)
            }
            let restarted = LayoutStore(registry: registry, defaults: restored, storageKey: "layout")
            XCTAssertTrue(restarted.isMetricEnabled("claude.fable"), key)
            let personal = [card + ".weekly", card + ".session"]
            XCTAssertEqual(restarted.metricOrder(for: card).filter(personal.contains), personal, key)
        }
    }

    func testUnreadableSeedMarkerDoesNotLookLikeAMissingPreSeedMarker() {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        defaults.set("unreadable-seed", forKey: "layout.seededDefaults")

        let store = LayoutStore(registry: registry(), defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("claude.fable"))
        XCTAssertEqual(defaults.string(forKey: "layout.seededDefaults"), "unreadable-seed")
        XCTAssertNil(defaults.object(forKey: "layout.disabledMetrics"))
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])
        let repaired = LayoutStore(registry: registry(), defaults: defaults, storageKey: "layout")
        XCTAssertTrue(repaired.isMetricEnabled("claude.fable"))
    }

    func testUnreadableMappingKeepsLegacyPersonalVisibilityForLaterRecovery() throws {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([PlacedWidget(descriptorID: "claude.session")])
        persistence.saveSeededDefaults(["claude.session", "claude.weekly"])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.fable", "claude.session"]])
        defaults.set(Data("bad-mapping".utf8), forKey: "layout.accountProfilesByCard")

        let deferred = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout",
            profileIDsByCardID: ["claude": "profile"])
        XCTAssertTrue(deferred.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(deferred.isMetricEnabled("claude.fable"))
        XCTAssertTrue(Set(persistence.loadDisabledMetrics() ?? []).contains("claude.weekly"))
        XCTAssertTrue(Set(persistence.loadDisabledMetrics() ?? []).contains("claude.fable"))

        defaults.set(try JSONEncoder().encode(["claude": "profile"]), forKey: "layout.accountProfilesByCard")
        deferred.replaceRegistry(registry(), profileIDsByCardID: ["claude": "profile"])

        XCTAssertFalse(deferred.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(deferred.isMetricEnabled("claude.fable"))
    }

    func testUnreadableMappingDoesNotDeferAnUnmappedProvidersChoices() {
        let defaults = makeDefaults()
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        defaults.set(Data("bad-mapping".utf8), forKey: "layout.accountProfilesByCard")
        persistence.saveDisabledMetrics(["claude.weekly", "codex.weekly"])
        persistence.savePriorityPins(["claude.session", "codex.session"])
        let store = LayoutStore(
            registry: registry(cards: ["claude", "codex"]), defaults: defaults, storageKey: "layout",
            profileIDsByCardID: ["claude": "new-profile"])

        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isMetricPinned("claude.session"))
        XCTAssertFalse(store.isMetricEnabled("codex.weekly"))
        XCTAssertTrue(store.isMetricPinned("codex.session"))
    }

    private func registry(cards: [String] = ["claude"]) -> WidgetRegistry {
        let providers = cards.map { Provider(id: $0, displayName: $0, icon: .providerMark("claude")) }
        return WidgetRegistry(
            providers: providers,
            descriptors: providers.flatMap { provider in
                ["session", "weekly", "fable", "extra", "sonnet", "today"].map { suffix in
                    WidgetDescriptor(
                        id: provider.id + "." + suffix, providerID: provider.id, metricLabel: suffix,
                        sample: WidgetData(title: suffix, icon: provider.icon, kind: .percent, used: 0, limit: 100))
                }
            })
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "EgasuTests.LayoutMigrationRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
