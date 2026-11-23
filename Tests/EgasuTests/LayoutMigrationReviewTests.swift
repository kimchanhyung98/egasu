import XCTest
@testable import Egasu

@MainActor
final class LayoutMigrationReviewTests: XCTestCase {
    func testSharedReorderWhileMappingIsUnreadableKeepsPersonalOrderAndPersistsSharedEdit() throws {
        let fixture = makeDefaults()
        let persistence = LayoutPersistence(defaults: fixture.defaults, storageKey: "layout")
        fixture.defaults.set(Data("bad mapping".utf8), forKey: "layout.accountProfilesByCard")
        persistence.saveDisabledMetrics([])
        persistence.savePriorityPins([])
        let personal = ["claude.weekly", "claude.session", "claude.unavailable"]
        persistence.saveMetricOrder([
            "claude": [personal[0], "claude.today", personal[1], "claude.yesterday", personal[2]]
        ])
        let mapping = ["claude": "current"]
        let store = LayoutStore(
            registry: registry(), defaults: fixture.defaults, storageKey: "layout", profileIDsByCardID: mapping)

        XCTAssertTrue(store.reorderMetric(dragged: "claude.today", target: "claude.yesterday", in: "claude"))
        let reloaded = LayoutStore(
            registry: registry(), defaults: fixture.defaults, storageKey: "layout", profileIDsByCardID: mapping)

        XCTAssertEqual(
            reloaded.metricOrder(for: "claude").filter(ProviderAccountID.isSharedMetric),
            ["claude.yesterday", "claude.today"])
        let saved = try XCTUnwrap(persistence.loadMetricOrder()?["claude"])
        XCTAssertEqual(saved.filter { !ProviderAccountID.isSharedMetric($0) }, personal)
        XCTAssertTrue(store.undo())
        XCTAssertEqual(
            persistence.loadMetricOrder()?["claude"]?.filter(ProviderAccountID.isSharedMetric),
            ["claude.today", "claude.yesterday"])
        XCTAssertEqual(
            persistence.loadMetricOrder()?["claude"]?.filter { !ProviderAccountID.isSharedMetric($0) }, personal)
    }

    func testFirstLocalEditWhileImportIsPendingKeepsTheLatestProfileBinding() throws {
        for switchBeforeEdit in [false, true] {
            let fixture = makeDefaults()
            fixture.defaults.setPersistentDomain(["openusage.layout.v2": Data("bad".utf8)], forName: fixture.source)
            XCTAssertFalse(
                SettingsMigrator.importUpstreamLayoutIfNeeded(
                    defaults: fixture.defaults, domainName: fixture.name, sourceDomainName: fixture.source))
            let a = AccountUsageCardPlanner.cardID(family: "claude", profileID: "a")
            let b = AccountUsageCardPlanner.cardID(family: "claude", profileID: "b")
            let mappingA = ["claude": "a", b: "b"]
            let mappingB = ["claude": "b", a: "a"]
            let store = LayoutStore(
                registry: registry(cards: ["claude", b]), defaults: fixture.defaults,
                profileIDsByCardID: mappingA)
            if switchBeforeEdit {
                store.replaceRegistry(registry(cards: ["claude", a]), profileIDsByCardID: mappingB)
            }
            store.setMetricEnabled("claude.weekly", false)

            let nextMapping = switchBeforeEdit ? mappingA : mappingB
            let nextCard = switchBeforeEdit ? b : a
            store.replaceRegistry(registry(cards: ["claude", nextCard]), profileIDsByCardID: nextMapping)

            XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
            XCTAssertFalse(store.isMetricEnabled(nextCard + ".weekly"))
            let reloaded = LayoutStore(
                registry: registry(cards: ["claude", nextCard]), defaults: fixture.defaults,
                profileIDsByCardID: nextMapping)
            XCTAssertTrue(reloaded.isMetricEnabled("claude.weekly"))
            XCTAssertFalse(reloaded.isMetricEnabled(nextCard + ".weekly"))
        }
    }

    func testUndoingAnUnrelatedPinKeepsUnreadableOrderBytes() {
        let fixture = makeDefaults()
        let original = Data("unreadable order".utf8)
        fixture.defaults.set(original, forKey: "layout.metricOrderByProvider")
        fixture.defaults.set([String](), forKey: "layout.disabledMetrics")
        let store = LayoutStore(registry: registry(), defaults: fixture.defaults, storageKey: "layout")

        store.setMetric("cursor.session", pinned: true)
        XCTAssertTrue(store.undo())

        XCTAssertFalse(store.isMetricPinned("cursor.session"))
        XCTAssertEqual(fixture.defaults.data(forKey: "layout.metricOrderByProvider"), original)
    }

    func testDeferredLegacyStarsMergeAfterOtherProviderGetsANewPin() throws {
        let fixture = makeDefaults()
        let persistence = LayoutPersistence(defaults: fixture.defaults, storageKey: "layout")
        fixture.defaults.set(Data("bad mapping".utf8), forKey: "layout.accountProfilesByCard")
        fixture.defaults.set(["claude.session"], forKey: "layout.menuBarPins")
        persistence.saveDisabledMetrics([])
        let mapping = ["claude": "current"]
        let store = LayoutStore(
            registry: registry(), defaults: fixture.defaults, storageKey: "layout",
            defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
        XCTAssertNil(store.migrateMenuBarStars())
        XCTAssertNil(fixture.defaults.object(forKey: "layout.priorityPins"))
        store.setMetric("cursor.session", pinned: true)
        XCTAssertTrue(store.isMetricPinned("cursor.session"))
        fixture.defaults.set(try JSONEncoder().encode(mapping), forKey: "layout.accountProfilesByCard")

        let repaired = LayoutStore(
            registry: registry(), defaults: fixture.defaults, storageKey: "layout",
            defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
        XCTAssertEqual(repaired.migrateMenuBarStars(), 1)
        XCTAssertTrue(repaired.isMetricPinned("claude.session"))
        XCTAssertTrue(repaired.isMetricPinned("cursor.session"))
        XCTAssertNil(repaired.migrateMenuBarStars())
    }

    func testStoredEmptyPriorityIsNotReimportedAndResetCancelsDeferredStars() throws {
        for reset in [false, true] {
            let fixture = makeDefaults()
            fixture.defaults.set(["claude.session"], forKey: "layout.menuBarPins")
            fixture.defaults.set([String](), forKey: "layout.disabledMetrics")
            let mapping = ["claude": "current"]
            if reset {
                fixture.defaults.set(Data("bad mapping".utf8), forKey: "layout.accountProfilesByCard")
            } else {
                fixture.defaults.set([String](), forKey: "layout.priorityPins")
            }
            let store = LayoutStore(
                registry: registry(), defaults: fixture.defaults, storageKey: "layout",
                defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
            XCTAssertNil(store.migrateMenuBarStars())
            if reset { store.resetToDefault() }
            fixture.defaults.set(try JSONEncoder().encode(mapping), forKey: "layout.accountProfilesByCard")
            let repaired = LayoutStore(
                registry: registry(), defaults: fixture.defaults, storageKey: "layout",
                defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)

            XCTAssertNil(repaired.migrateMenuBarStars())
            XCTAssertFalse(repaired.isMetricPinned("claude.session"))
        }
    }

    func testDeferredStarsAreRecordedBeforeNewPinsAndClearedOnlyAfterRecoveryPins() throws {
        let name = "EgasuTests.LayoutMigrationReview.Ordering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(RecordingLayoutMigrationDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("bad mapping".utf8), forKey: "layout.accountProfilesByCard")
        defaults.set([String](), forKey: "layout.disabledMetrics")
        defaults.set(["claude.session", "cursor.session"], forKey: "layout.menuBarPins")
        let mapping = ["claude": "current"]
        let store = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout",
            defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
        XCTAssertEqual(store.migrateMenuBarStars(), 1)
        let firstPinWrite = try XCTUnwrap(defaults.writes.first { $0.key == "layout.priorityPins" })
        XCTAssertEqual(Set(firstPinWrite.deferred ?? []), ["claude.session", "cursor.session"])
        defaults.set(try JSONEncoder().encode(mapping), forKey: "layout.accountProfilesByCard")
        let repaired = LayoutStore(
            registry: registry(), defaults: defaults, storageKey: "layout",
            defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
        XCTAssertEqual(repaired.migrateMenuBarStars(), 1)

        let cleared = try XCTUnwrap(
            defaults.writes.last { $0.key == "layout.deferredMenuBarStars" && $0.deferred == nil })
        XCTAssertEqual(Set(cleared.pins ?? []), ["claude.session", "cursor.session"])
        for state in defaults.writes {
            let resumedFixture = makeDefaults()
            let resumedDefaults = resumedFixture.defaults
            resumedDefaults.set(try JSONEncoder().encode(mapping), forKey: "layout.accountProfilesByCard")
            resumedDefaults.set([String](), forKey: "layout.disabledMetrics")
            resumedDefaults.set(["claude.session", "cursor.session"], forKey: "layout.menuBarPins")
            if let deferred = state.deferred { resumedDefaults.set(deferred, forKey: "layout.deferredMenuBarStars") }
            if let pins = state.pins { resumedDefaults.set(pins, forKey: "layout.priorityPins") }
            let resumed = LayoutStore(
                registry: registry(), defaults: resumedDefaults, storageKey: "layout",
                defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
            _ = resumed.migrateMenuBarStars()
            XCTAssertTrue(resumed.isMetricPinned("claude.session"), "저장 경계: \(state.key)")
            XCTAssertTrue(resumed.isMetricPinned("cursor.session"), "저장 경계: \(state.key)")
        }
    }

    func testExplicitUnpinWinsOverDeferredStarsAndUndoRestoresThePinChoice() {
        for undo in [false, true] {
            for switchAfterEdit in [false, true] {
                let fixture = makeDefaults()
                let brokenOrder = Data("bad order".utf8)
                fixture.defaults.set(brokenOrder, forKey: "layout.metricOrderByProvider")
                fixture.defaults.set([String](), forKey: "layout.disabledMetrics")
                fixture.defaults.set(["claude.session"], forKey: "layout.menuBarPins")
                let other = AccountUsageCardPlanner.cardID(family: "claude", profileID: "other")
                var catalog = registry(cards: ["claude", other, "cursor"])
                var mapping = ["claude": "current", other: "other"]
                let store = LayoutStore(
                    registry: catalog, defaults: fixture.defaults, storageKey: "layout",
                    defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
                XCTAssertNil(store.migrateMenuBarStars())
                store.setMetric("claude.session", pinned: true)
                store.setMetric("claude.session", pinned: false)
                if undo { XCTAssertTrue(store.undo()) }
                var editedCard = "claude"
                var otherCard = other
                if switchAfterEdit {
                    editedCard = AccountUsageCardPlanner.cardID(family: "claude", profileID: "current")
                    otherCard = "claude"
                    catalog = registry(cards: ["claude", editedCard, "cursor"])
                    mapping = ["claude": "other", editedCard: "current"]
                    store.replaceRegistry(catalog, profileIDsByCardID: mapping)
                }
                XCTAssertEqual(fixture.defaults.data(forKey: "layout.metricOrderByProvider"), brokenOrder)
                LayoutPersistence(defaults: fixture.defaults, storageKey: "layout").saveMetricOrder([:])

                let repaired = LayoutStore(
                    registry: catalog, defaults: fixture.defaults, storageKey: "layout",
                    defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
                _ = repaired.migrateMenuBarStars()

                XCTAssertEqual(repaired.isMetricPinned(editedCard + ".session"), undo)
                XCTAssertTrue(repaired.isMetricPinned(otherCard + ".session"), "다른 계정의 후보는 해제하지 않음")
            }
        }
    }

    func testExplicitUnpinDoesNotCancelUnknownOwnerCandidates() throws {
        for editedCard in ["cursor", "claude"] {
            let fixture = makeDefaults()
            fixture.defaults.set(Data("bad mapping".utf8), forKey: "layout.accountProfilesByCard")
            fixture.defaults.set([String](), forKey: "layout.disabledMetrics")
            fixture.defaults.set(["claude.session"], forKey: "layout.menuBarPins")
            let mapping = ["claude": "current"]
            let store = LayoutStore(
                registry: registry(), defaults: fixture.defaults, storageKey: "layout",
                defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
            XCTAssertNil(store.migrateMenuBarStars())
            store.setMetric(editedCard + ".session", pinned: true)
            store.setMetric(editedCard + ".session", pinned: false)
            fixture.defaults.set(try JSONEncoder().encode(mapping), forKey: "layout.accountProfilesByCard")

            let repaired = LayoutStore(
                registry: registry(), defaults: fixture.defaults, storageKey: "layout",
                defaultPinnedMetricIDs: [], profileIDsByCardID: mapping)
            _ = repaired.migrateMenuBarStars()

            XCTAssertTrue(repaired.isMetricPinned("claude.session"))
            XCTAssertFalse(repaired.isMetricPinned("cursor.session"))
        }
    }

    private func registry(cards: [String] = ["claude", "cursor"]) -> WidgetRegistry {
        let providers = cards.map { Provider(id: $0, displayName: $0, icon: .providerMark("claude")) }
        return WidgetRegistry(
            providers: providers,
            descriptors: providers.flatMap { provider in
                ["session", "weekly", "today", "yesterday"].map { suffix in
                    WidgetDescriptor(
                        id: provider.id + "." + suffix, providerID: provider.id, metricLabel: suffix,
                        sample: WidgetData(title: suffix, icon: provider.icon, kind: .percent, used: 0, limit: 100))
                }
            })
    }

    private func makeDefaults() -> (defaults: UserDefaults, name: String, source: String) {
        let name = "EgasuTests.LayoutMigrationReview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        let source = name + ".source"
        addTeardownBlock {
            defaults.removePersistentDomain(forName: name)
            defaults.removePersistentDomain(forName: source)
        }
        return (defaults, name, source)
    }
}

private final class RecordingLayoutMigrationDefaults: UserDefaults {
    var writes: [(key: String, deferred: [String]?, pins: [String]?)] = []

    override func set(_ value: Any?, forKey defaultName: String) {
        super.set(value, forKey: defaultName)
        record(defaultName)
    }

    override func removeObject(forKey defaultName: String) {
        super.removeObject(forKey: defaultName)
        record(defaultName)
    }

    private func record(_ key: String) {
        if ["layout.priorityPins", "layout.deferredMenuBarStars"].contains(key) {
            writes.append(
                (key, stringArray(forKey: "layout.deferredMenuBarStars"), stringArray(forKey: "layout.priorityPins")))
        }
    }
}
