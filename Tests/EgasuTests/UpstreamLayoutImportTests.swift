import XCTest
@testable import Egasu

@MainActor
final class UpstreamLayoutImportTests: XCTestCase {
    private let layoutKey = "openusage.layout.v1"

    func testV1ImportAppliesResetWatchPlacementAfterFreshSchemaStamp() throws {
        let fixture = makeDefaults()
        SettingsMigrator.migrate(
            defaults: fixture.defaults, domainName: fixture.target, capturedFreshInstall: true)
        XCTAssertEqual(fixture.defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 3)
        let order = ["codex": ["codex.session", "codex.rateLimitResets", "codex.weekly"]]
        fixture.defaults.setPersistentDomain(
            [
                layoutKey: try JSONEncoder().encode([PlacedWidget(descriptorID: "codex.session")]),
                "\(layoutKey).metricOrderByProvider": try JSONEncoder().encode(order),
                "\(layoutKey).expandedMetrics": ["codex.weekly"]
            ], forName: fixture.source)

        XCTAssertTrue(importLayout(fixture))
        XCTAssertEqual(
            fixture.defaults.stringArray(forKey: "\(layoutKey).expandedMetrics"),
            ["codex.weekly", "codex.resetWatch"])
        let saved = try XCTUnwrap(fixture.defaults.data(forKey: "\(layoutKey).metricOrderByProvider"))
        XCTAssertEqual(
            try JSONDecoder().decode([String: [String]].self, from: saved)["codex"],
            ["codex.session", "codex.resetWatch", "codex.rateLimitResets", "codex.weekly"])
        XCTAssertEqual(fixture.defaults.integer(forKey: SettingsMigrator.schemaVersionKey), 3)
        XCTAssertNil(fixture.defaults.object(forKey: "openusage.enabledProviders.v1"))
    }

    func testV1ImportsLayoutAndLeavesOtherSettingsAndSourceUntouched() throws {
        let fixture = makeDefaults()
        let placed = try JSONEncoder().encode([PlacedWidget(descriptorID: "claude.session")])
        let order = try JSONEncoder().encode(["claude": ["claude.weekly", "claude.session"]])
        let source: [String: Any] = [
            layoutKey: placed,
            "\(layoutKey).metricOrderByProvider": order,
            "\(layoutKey).menuBarPins": ["claude.session"],
            "\(layoutKey).expandedMetrics": ["claude.weekly"],
            "openusage.enabledProviders.v1": ["claude"],
            "accounts.v1": Data("private account metadata".utf8)
        ]
        fixture.defaults.setPersistentDomain(source, forName: fixture.source)
        fixture.defaults.set("keep", forKey: "unrelated")

        XCTAssertTrue(importLayout(fixture))
        XCTAssertEqual(fixture.defaults.data(forKey: layoutKey), placed)
        XCTAssertEqual(fixture.defaults.data(forKey: "\(layoutKey).metricOrderByProvider"), order)
        XCTAssertEqual(fixture.defaults.stringArray(forKey: "\(layoutKey).menuBarPins"), ["claude.session"])
        XCTAssertEqual(fixture.defaults.string(forKey: "unrelated"), "keep")
        XCTAssertNil(fixture.defaults.object(forKey: "openusage.enabledProviders.v1"))
        XCTAssertNil(fixture.defaults.object(forKey: "accounts.v1"))
        XCTAssertTrue(
            NSDictionary(dictionary: source).isEqual(to: fixture.defaults.persistentDomain(forName: fixture.source)!))

        let store = LayoutStore(registry: .mock, defaults: fixture.defaults)
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        store.setMetricEnabled("claude.weekly", true)
        XCTAssertFalse(importLayout(fixture), "이전 뒤 사용자 변경은 원본 앱 설정으로 덮어쓰지 않음")
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
    }

    func testAnyExistingTargetLayoutKeyPreventsImport() throws {
        for suffix in ["", ".disabledMetrics", ".providerOrder", ".priorityPins", ".seededCards", ".unknownFutureKey"] {
            let fixture = makeDefaults()
            let existingKey = layoutKey + suffix
            fixture.defaults.set("existing even if unreadable", forKey: existingKey)
            fixture.defaults.setPersistentDomain(
                [
                    layoutKey: try JSONEncoder().encode([PlacedWidget(descriptorID: "claude.session")])
                ], forName: fixture.source)
            let targetBefore = fixture.defaults.persistentDomain(forName: fixture.target)!

            XCTAssertFalse(importLayout(fixture), existingKey)
            XCTAssertTrue(
                NSDictionary(dictionary: targetBefore).isEqual(
                    to: fixture.defaults.persistentDomain(forName: fixture.target)!))
        }
    }

    func testV2WinsOverV1AndAppliesMatchingMetricIDs() throws {
        let fixture = makeDefaults()
        fixture.defaults.setPersistentDomain(
            [
                "openusage.layout.v2": try v2Data(
                    hidden: ["claude.weekly"], pins: ["claude.session"],
                    providers: ["cursor", "claude"],
                    order: ["claude": ["claude.extra", "claude.session", "claude.weekly"]]
                ),
                layoutKey: try JSONEncoder().encode([PlacedWidget(descriptorID: "claude.weekly")]),
                "\(layoutKey).menuBarPins": ["claude.weekly"],
                "\(layoutKey).expandedMetrics": ["claude.extra"]
            ], forName: fixture.source)

        XCTAssertTrue(importLayout(fixture))
        XCTAssertNil(fixture.defaults.object(forKey: layoutKey), "옛 v1 켜짐 목록은 가져오지 않음")
        XCTAssertNil(fixture.defaults.object(forKey: "\(layoutKey).menuBarPins"))
        XCTAssertNil(fixture.defaults.object(forKey: "\(layoutKey).expandedMetrics"))
        let store = LayoutStore(registry: .mock, defaults: fixture.defaults)
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isMetricEnabled("claude.extra"))
        XCTAssertTrue(storedPriorityPins(fixture).contains("claude.session"))
        XCTAssertEqual(store.pinnedMetricIDs, ["claude.session"])
        XCTAssertEqual(store.providerOrder, ["cursor", "claude"])
        XCTAssertEqual(store.metricOrderByProvider["claude"], ["claude.extra", "claude.session", "claude.weekly"])
    }

    func testV2KeepsUnknownAccountIDsWithoutApplyingThemToFamily() throws {
        let fixture = makeDefaults()
        let unknownCard = "claude@12345678"
        let hidden = ["\(unknownCard).session", "\(unknownCard).today"]
        let pins = ["\(unknownCard).weekly", "\(unknownCard).trend"]
        let order = [unknownCard: ["\(unknownCard).weekly", "\(unknownCard).session", "\(unknownCard).today"]]
        fixture.defaults.setPersistentDomain(
            [
                "openusage.layout.v2": try v2Data(hidden: hidden, pins: pins, providers: [unknownCard], order: order)
            ], forName: fixture.source)

        XCTAssertTrue(importLayout(fixture))
        let store = LayoutStore(registry: .mock, defaults: fixture.defaults)
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isMetricEnabled("claude.today"))
        XCTAssertFalse(storedPriorityPins(fixture).contains("claude.weekly"))
        XCTAssertTrue(store.pinnedMetricIDs.isEmpty, "미등록 계정의 고정으로 기본 카드나 기본 별표를 선택하지 않음")
        store.setMetricEnabled("claude.extra", false)

        let reloaded = LayoutStore(registry: .mock, defaults: fixture.defaults)
        XCTAssertTrue(
            Set(hidden).isSubset(of: Set(fixture.defaults.stringArray(forKey: "\(layoutKey).disabledMetrics") ?? [])))
        XCTAssertTrue(Set(pins).isSubset(of: storedPriorityPins(fixture)))
        XCTAssertEqual(reloaded.metricOrderByProvider[unknownCard], order[unknownCard])
        XCTAssertTrue(reloaded.providerOrder.contains(unknownCard))
        XCTAssertTrue(reloaded.isMetricEnabled("claude.session"))
    }

    func testV2AppliesScopedSettingsOnlyToTheMatchingCard() throws {
        let fixture = makeDefaults()
        let card = "claude@12345678"
        let providers = ["claude", card].map {
            Provider(id: $0, displayName: $0, icon: .providerMark("claude"))
        }
        let registry = WidgetRegistry(
            providers: providers,
            descriptors: providers.flatMap { provider in
                ["session", "weekly"].map { suffix in
                    WidgetDescriptor(
                        id: "\(provider.id).\(suffix)", providerID: provider.id, metricLabel: suffix,
                        sample: WidgetData(title: suffix, icon: provider.icon, kind: .percent, used: 0, limit: 100)
                    )
                }
            })
        fixture.defaults.setPersistentDomain(
            [
                "openusage.layout.v2": try v2Data(
                    hidden: ["\(card).session"], pins: ["\(card).weekly"], providers: [card, "claude"],
                    order: [card: ["\(card).weekly", "\(card).session"]]
                )
            ], forName: fixture.source)

        XCTAssertTrue(importLayout(fixture))
        let store = LayoutStore(registry: registry, defaults: fixture.defaults)
        XCTAssertFalse(store.isMetricEnabled("\(card).session"))
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(storedPriorityPins(fixture).contains("\(card).weekly"))
        XCTAssertFalse(storedPriorityPins(fixture).contains("claude.weekly"))
        XCTAssertEqual(store.metricOrder(for: card), ["\(card).weekly", "\(card).session"])
    }

    func testUnreadableV2NeverFallsBackToStaleV1() throws {
        let fixture = makeDefaults()
        let source: [String: Any] = [
            "openusage.layout.v2": Data("not JSON".utf8),
            layoutKey: try JSONEncoder().encode([PlacedWidget(descriptorID: "claude.session")])
        ]
        fixture.defaults.setPersistentDomain(source, forName: fixture.source)

        XCTAssertFalse(importLayout(fixture))
        XCTAssertNil(fixture.defaults.object(forKey: layoutKey))
        XCTAssertNil(fixture.defaults.object(forKey: "\(layoutKey).disabledMetrics"))
        XCTAssertTrue(
            NSDictionary(dictionary: source).isEqual(to: fixture.defaults.persistentDomain(forName: fixture.source)!))
    }

    func testEmptySourceAndExistingTargetV2DoNotImport() throws {
        let fixture = makeDefaults()
        XCTAssertFalse(importLayout(fixture))

        fixture.defaults.set(Data("saved target".utf8), forKey: "openusage.layout.v2")
        fixture.defaults.setPersistentDomain(
            [
                "openusage.layout.v2": try v2Data(hidden: ["claude.weekly"])
            ], forName: fixture.source)
        XCTAssertFalse(importLayout(fixture))
        XCTAssertNil(fixture.defaults.object(forKey: "\(layoutKey).disabledMetrics"))
    }

    private func storedPriorityPins(_ fixture: Fixture) -> Set<String> {
        Set(fixture.defaults.stringArray(forKey: "\(layoutKey).priorityPins") ?? [])
    }

    private func importLayout(_ fixture: Fixture) -> Bool {
        SettingsMigrator.importUpstreamLayoutIfNeeded(
            defaults: fixture.defaults, domainName: fixture.target, sourceDomainName: fixture.source
        )
    }

    private func v2Data(
        hidden: [String] = [], pins: [String] = [], providers: [String] = [], order: [String: [String]] = [:]
    ) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "hiddenMetricIDs": hidden,
            "priorityPinIDs": pins,
            "providerOrder": providers,
            "metricOrderByProvider": order,
            "seededProviderIDs": providers,
            "unifiedProviderKinds": []
        ])
    }

    private struct Fixture {
        let defaults: UserDefaults
        let target: String
        let source: String
    }

    private func makeDefaults() -> Fixture {
        let target = "EgasuTests.UpstreamLayoutImport.\(UUID().uuidString)"
        let source = target + ".source"
        let defaults = UserDefaults(suiteName: target)!
        addTeardownBlock {
            defaults.removePersistentDomain(forName: target)
            defaults.removePersistentDomain(forName: source)
        }
        return Fixture(defaults: defaults, target: target, source: source)
    }
}
