import XCTest
@testable import Egasu

/// `MockData`에 Antigravity 픽스처가 없어 실제 provider registry 사용
@MainActor
final class AntigravityLayoutTests: XCTestCase {

    func testFreshDefaultsSeedFiveMetrics() {
        let store = makeStore("FreshDefaults")

        XCTAssertEqual(store.placed.map(\.descriptorID), [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly", "antigravity.argonWeekly"
        ])

        XCTAssertTrue(store.priorityPinIDs.isEmpty, "새 설치는 고정 없이 시작")

        let group = store.customizeGroups.first { $0.provider.id == "antigravity" }
        XCTAssertEqual(group?.metrics.map(\.id), [
            "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.claude", "antigravity.claudeWeekly", "antigravity.argonWeekly"
        ])
    }

    func testHistoryOnlyProviderIsSpendCapableWhileEnabledWithoutChangingLayout() {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("HistoryEnablement"))
        let store = LayoutStore(
            registry: .antigravityOnly,
            defaults: makeDefaults("HistoryLayout"),
            storageKey: "layout",
            isProviderEnabled: { enablement.isEnabled($0) }
        )
        let placed = store.placed
        let pins = store.priorityPinIDs

        XCTAssertEqual(store.registry.descriptors.map(\.id), [
            "antigravity.geminiPro", "antigravity.geminiWeekly",
            "antigravity.claude", "antigravity.claudeWeekly", "antigravity.argonWeekly"
        ])
        XCTAssertTrue(store.hasSpendCapableProvider)
        XCTAssertEqual(store.spendCapableProviders.map(\.id), ["antigravity"])

        enablement.setEnabled(false, for: "antigravity")

        XCTAssertFalse(store.hasSpendCapableProvider)
        XCTAssertTrue(store.spendCapableProviders.isEmpty)
        XCTAssertEqual(store.placed, placed)
        XCTAssertEqual(store.priorityPinIDs, pins)

        enablement.setEnabled(true, for: "antigravity")

        XCTAssertTrue(store.hasSpendCapableProvider)
        XCTAssertEqual(store.spendCapableProviders.map(\.id), ["antigravity"])
        XCTAssertEqual(store.placed, placed)
        XCTAssertEqual(store.priorityPinIDs, pins)
    }

    func testNewWeeklyMetricsAreEnabledWithoutRestoringPreviouslyHiddenQuotas() {
        let defaults = makeDefaults("SeedWeeklies")
        saveStored([PlacedWidget(descriptorID: "antigravity.claude")], forKey: "layout", in: defaults)
        saveStored(["antigravity.geminiPro", "antigravity.claude"], forKey: "layout.seededDefaults", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiPro"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.claude"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.geminiWeekly"))
        XCTAssertTrue(store.isMetricEnabled("antigravity.claudeWeekly"))
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
    }

    func testNewArgonMetricKeepsSavedOrderPinsAndExistingVisibility() {
        let defaults = makeDefaults("ArgonUpgrade")
        let priorOrder = [
            "antigravity.claudeWeekly", "antigravity.claude", "antigravity.geminiPro", "antigravity.geminiWeekly"
        ]
        saveStored(priorOrder.map { PlacedWidget(descriptorID: $0) }, forKey: "layout", in: defaults)
        saveStored(["antigravity": priorOrder], forKey: "layout.metricOrderByProvider", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.priorityPins")
        defaults.set(["antigravity.claudeWeekly"], forKey: "layout.expandedMetrics")

        let registry = WidgetRegistry.antigravityOnly
        let oldRegistry = WidgetRegistry(
            providers: registry.providers,
            descriptors: registry.descriptors.filter { $0.id != "antigravity.argonWeekly" }
        )
        let previous = LayoutStore(registry: oldRegistry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(previous.orderedSupportedMetrics(for: "antigravity").map(\.id), priorOrder)
        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "antigravity").map(\.id), priorOrder + ["antigravity.argonWeekly"])
        XCTAssertTrue(store.isMetricEnabled("antigravity.argonWeekly"))
        XCTAssertEqual(store.priorityPinIDs, ["antigravity.claude"])
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
    }

    func testSavedGeminiFlashStateStaysInvisibleWhileItsTombstonesAreRetained() {
        // `antigravity.geminiFlash`는 폐기 — UI에서 제외되나, 일시 부재 account card일 수도 있어 저장 상태는 tombstone으로 유지
        let defaults = makeDefaults("FlashFilter")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.geminiFlash"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)
        defaults.set(["antigravity.geminiPro", "antigravity.geminiFlash"], forKey: "layout.priorityPins")
        saveStored(
            ["antigravity": ["antigravity.geminiFlash", "antigravity.geminiPro", "antigravity.claude"]],
            forKey: "layout.metricOrderByProvider", in: defaults
        )

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertFalse(store.isMetricEnabled("antigravity.geminiFlash"))
        XCTAssertFalse(store.orderedSupportedMetrics(for: "antigravity").map(\.id).contains("antigravity.geminiFlash"))
        XCTAssertFalse(store.isMetricPinned("antigravity.geminiFlash"), "the dead pin stays invisible")
        XCTAssertTrue(
            store.priorityPinIDs.contains("antigravity.geminiFlash"),
            "…but its tombstone is retained for a possible return"
        )
        XCTAssertTrue(store.isMetricPinned("antigravity.geminiPro"))
        XCTAssertFalse(store.isMetricPinned("antigravity.geminiWeekly"), "an existing pin set gains no new defaults")
    }

    func testAbsentPinsKeyStartsWithoutPriorityPins() {
        let defaults = makeDefaults("PinsAbsent")
        saveStored([
            PlacedWidget(descriptorID: "antigravity.geminiPro"),
            PlacedWidget(descriptorID: "antigravity.claude")
        ], forKey: "layout", in: defaults)

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.priorityPinIDs.isEmpty)
        XCTAssertNil(store.migrateMenuBarStars())
    }

    func testSavedPinsKeyIsRespectedExactly() {
        let defaults = makeDefaults("PinsPresent")
        saveStored([PlacedWidget(descriptorID: "antigravity.geminiPro")], forKey: "layout", in: defaults)
        defaults.set(["antigravity.claude"], forKey: "layout.priorityPins")

        let store = LayoutStore(registry: .antigravityOnly, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.priorityPinIDs, ["antigravity.claude"],
                       "a user-saved pin set must not gain the new default pins")
    }

    // MARK: - Fixtures

    private func makeStore(_ name: String) -> LayoutStore {
        LayoutStore(registry: .antigravityOnly, defaults: makeDefaults(name), storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.AntigravityLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// Antigravity provider만 담은 registry — `DefaultLayout` seed가 4개 metric으로 좁혀짐
    @MainActor
    static var antigravityOnly: WidgetRegistry { .from([AntigravityProvider()]) }
}
