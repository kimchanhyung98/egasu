import XCTest
@testable import Egasu

@MainActor
final class AccountQuotaCardLayoutTests: XCTestCase {
    private let cardID = "claude@profile-work"

    func testReorderingAnAccountKeepsItsQuotaVisibilityIndependent() {
        let store = makeStore(defaults: makeDefaults("IndependentReorder"))
        store.setMetricEnabled("claude.weekly", false)

        XCTAssertTrue(store.reorderMetric(
            dragged: "\(cardID).weekly", target: "\(cardID).sonnet", in: cardID))

        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.isMetricEnabled("\(cardID).weekly"))
        XCTAssertEqual(store.accountSettingsMetrics(for: cardID).map(\.id),
            ["session", "sonnet", "weekly"].map { "\(cardID).\($0)" })
        XCTAssertEqual(store.accountSettingsMetrics(for: "claude").map(\.id),
            ["claude.session", "claude.weekly", "claude.sonnet"])
    }

    func testProviderResetFromAnAccountRestoresItsFamilyAndKeepsOtherProviders() {
        let store = makeStore(defaults: makeDefaults("FamilyReset"))
        store.setMetricEnabled("claude.weekly", false)
        store.setMetricEnabled("\(cardID).weekly", false)
        XCTAssertTrue(store.reorderMetric(dragged: "\(cardID).sonnet", target: "\(cardID).session", in: cardID))
        store.setMetricEnabled("codex.session", true)
        let codex = store.placed.filter { $0.descriptorID.hasPrefix("codex.") }

        store.resetProvider(cardID)

        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.isMetricEnabled("\(cardID).weekly"))
        XCTAssertEqual(
            store.accountSettingsMetrics(for: cardID).map(\.id),
            ["session", "weekly", "sonnet"].map { "\(cardID).\($0)" })
        XCTAssertEqual(store.placed.filter { $0.descriptorID.hasPrefix("codex.") }, codex)
        XCTAssertFalse(store.canUndo)
    }

    func testLegacyOnDemandGroupingMigratesToTheVisibleCardOrder() {
        // 기존 표시 순서를 평탄화한 뒤 개인 지표의 계정별 순서로 보존.
        let defaults = makeDefaults("OnDemandSplit")
        defaults.set(["claude.session"], forKey: "layout.expandedMetrics")
        saveStored(["claude.session", "claude.weekly", "claude.sonnet"], forKey: "layout.seededDefaults", in: defaults)

        let store = makeStore(defaults: defaults)

        let group = store.displayGroups.first { $0.provider.id == cardID }
        XCTAssertEqual(
            group?.widgets.map(\.descriptorID),
            ["\(cardID).weekly", "\(cardID).sonnet", "\(cardID).session"],
            "이전 접기 영역의 표시 순서 유지"
        )
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
    }

    func testHidingAMetricOnAnAccountCardLeavesOtherCardsAlone() {
        let store = makeStore(defaults: makeDefaults("HidePerCard"))

        store.setMetricEnabled("\(cardID).weekly", false)

        XCTAssertFalse(store.isMetricEnabled("\(cardID).weekly"))
        XCTAssertTrue(store.isMetricEnabled("claude.weekly"), "같은 프로바이더의 다른 카드는 그대로")
        XCTAssertEqual(widgets(store, cardID), ["\(cardID).session", "\(cardID).sonnet"])
    }

    func testMovingAMetricOnAnAccountCardMovesItOnlyThere() {
        let defaults = makeDefaults("ReorderPerCard")
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.reorderMetric(dragged: "\(cardID).sonnet", target: "\(cardID).weekly", in: cardID))

        XCTAssertEqual(widgets(store, cardID), ["\(cardID).session", "\(cardID).sonnet", "\(cardID).weekly"])
        XCTAssertEqual(widgets(store, "claude"), ["claude.session", "claude.weekly", "claude.sonnet"], "다른 카드 순서는 그대로")
        XCTAssertEqual(
            widgets(makeStore(defaults: defaults), cardID),
            ["\(cardID).session", "\(cardID).sonnet", "\(cardID).weekly"],
            "재실행 뒤에도 카드 순서 유지"
        )
    }

    func testALegacyLayoutFoldsThenCopiesTheProviderSettingsToEveryCard() {
        let defaults = makeDefaults("FoldStoredEntries")
        saveStored(
            [
                PlacedWidget(descriptorID: "claude.session"),
                PlacedWidget(descriptorID: "\(cardID).session"),
                PlacedWidget(descriptorID: "\(cardID).weekly")
            ],
            forKey: "layout",
            in: defaults
        )
        defaults.set(["claude.weekly", "\(cardID).sonnet"], forKey: "layout.expandedMetrics")
        defaults.set([cardID], forKey: "layout.expandedProviders")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(
            store.placed.map(\.descriptorID),
            ["claude.session", "claude.weekly", "\(cardID).session", "\(cardID).weekly"]
        )
        XCTAssertEqual(
            store.metricOrderByProvider["claude"], ["claude.session", "claude.sonnet", "claude.weekly"],
            "기존 표시 순서를 평탄화하여 보존"
        )
        XCTAssertEqual(
            store.metricOrderByProvider[cardID], ["\(cardID).session", "\(cardID).sonnet", "\(cardID).weekly"],
            "평탄화한 개인 지표 순서를 계정 카드로 복사"
        )
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
        XCTAssertNil(defaults.object(forKey: "layout.expandedProviders"))

        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        XCTAssertEqual(
            persistence.loadPlaced()?.map(\.descriptorID),
            [
                "claude.session", "\(cardID).session", "\(cardID).weekly"
            ], "이전 양식은 변환 입력으로 보존")
        XCTAssertEqual(makeStore(defaults: defaults).placed.map(\.descriptorID), store.placed.map(\.descriptorID))
    }

    func testALegacyLayoutAlsoCopiesToACardMissingFromThisLaunch() {
        let defaults = makeDefaults("AbsentCardMigration")
        let away = "claude@profile-away"
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        saveStored(["claude.session", "claude.weekly", "claude.sonnet"], forKey: "layout.seededDefaults", in: defaults)
        saveStored(["claude", away, cardID, "codex"], forKey: "layout.providerOrder", in: defaults)

        let store = makeStore(defaults: defaults)
        XCTAssertTrue(store.placed.contains { $0.descriptorID == "\(away).session" }, "이번 실행에 없는 카드도 패밀리 설정을 받음")

        store.replaceRegistry(.accountQuotaCards(includesCodexAccountCard: false, extraCardIDs: [away]))

        XCTAssertTrue(store.isMetricEnabled("\(away).session"))
        XCTAssertFalse(store.isMetricEnabled("\(away).weekly"), "돌아온 카드는 앱 기본값이 아니라 이전 설정")
    }

    func testALegacyLayoutCopiesToKnownOrPinnedCardsMissingFromThisLaunch() {
        let defaults = makeDefaults("KnownAndPinnedCards")
        let pinned = "claude@profile-pinned"
        let enabled = "claude@profile-enabled"
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        saveStored(["claude.session", "claude.weekly", "claude.sonnet"], forKey: "layout.seededDefaults", in: defaults)
        defaults.set(["\(pinned).session"], forKey: "layout.priorityPins")

        let store = LayoutStore(
            registry: .accountQuotaCards(includesCodexAccountCard: false), defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly", "claude.sonnet"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly", "claude.sonnet"],
            defaultPinnedMetricIDs: [],
            knownCardIDs: [enabled]
        )
        store.replaceRegistry(.accountQuotaCards(includesCodexAccountCard: false, extraCardIDs: [pinned, enabled]))

        for card in [pinned, enabled] {
            XCTAssertTrue(store.isMetricEnabled("\(card).session"), "\(card): 이전 설정 복사")
            XCTAssertFalse(store.isMetricEnabled("\(card).weekly"), "\(card): 앱 기본값으로 시작하지 않음")
        }
    }

    func testACardFirstSeenAfterTheSplitStartsFromAppDefaults() {
        let store = makeStore(defaults: makeDefaults("NewCardDefaults"))
        store.setMetricEnabled("claude.weekly", false)
        store.setMetricEnabled("\(cardID).weekly", false)

        let newcomer = "claude@profile-new"
        store.replaceRegistry(.accountQuotaCards(includesCodexAccountCard: false, extraCardIDs: [newcomer]))

        XCTAssertEqual(
            widgets(store, newcomer), ["\(newcomer).session", "\(newcomer).weekly", "\(newcomer).sonnet"],
            "새 카드는 다른 카드의 선택이 아니라 앱 기본값으로 시작"
        )
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
    }

    func testAFreshInstallKeepsItsDefaultsAcrossRelaunch() {
        let defaults = makeDefaults("FreshRelaunch")
        _ = makeStore(defaults: defaults)

        let relaunched = makeStore(defaults: defaults)

        XCTAssertEqual(widgets(relaunched, "claude"), ["claude.session", "claude.weekly", "claude.sonnet"])
        XCTAssertEqual(widgets(relaunched, cardID), ["\(cardID).session", "\(cardID).weekly", "\(cardID).sonnet"])
    }

    func testACardWithEveryMetricHiddenStaysEmptyAfterRelaunch() {
        let defaults = makeDefaults("EmptyCardStaysEmpty")
        let store = makeStore(defaults: defaults)
        for suffix in ["session", "weekly", "sonnet"] {
            store.setMetricEnabled("\(cardID).\(suffix)", false)
        }

        let reloaded = makeStore(defaults: defaults)

        XCTAssertNil(widgets(reloaded, cardID), "모두 끈 카드를 기본값으로 다시 채우지 않음")
        XCTAssertTrue(reloaded.isMetricEnabled("claude.session"))
    }

    func testANewMetricReachesEveryCardWithoutRestoringHiddenMetrics() {
        let defaults = makeDefaults("NewMetricEveryCard")
        let fullRegistry = WidgetRegistry.accountQuotaCards(includesCodexAccountCard: false)
        let previousRegistry = WidgetRegistry(
            providers: fullRegistry.providers,
            descriptors: fullRegistry.descriptors.filter { !$0.id.hasSuffix(".weekly") }
        )
        let previous = LayoutStore(registry: previousRegistry, defaults: defaults, storageKey: "layout")
        previous.setMetricEnabled("claude.sonnet", false)
        let updated = LayoutStore(registry: fullRegistry, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(updated.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(updated.isMetricEnabled("\(cardID).weekly"), "새 지표는 기존 카드에서도 기본 켜짐")
        XCTAssertFalse(updated.isMetricEnabled("claude.sonnet"))
        updated.setMetricEnabled("\(cardID).weekly", false)
        let relaunched = LayoutStore(registry: fullRegistry, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(relaunched.isMetricEnabled("\(cardID).weekly"))
        XCTAssertTrue(relaunched.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(relaunched.isMetricEnabled("claude.sonnet"))
    }

    func testFullyHiddenQuotaCardRemainsReachableThroughAccountsAndCanBeRestored() {
        let defaults = makeDefaults("RestoreHiddenCard")
        let store = makeStore(defaults: defaults)
        for suffix in ["session", "weekly", "sonnet"] {
            store.setMetricEnabled("\(cardID).\(suffix)", false)
        }
        XCTAssertNil(widgets(store, cardID))
        XCTAssertTrue(store.customizeProviderRows.contains { $0.id == cardID })
        XCTAssertEqual(store.accountSettingsMetrics(for: cardID).count, 3)

        store.setMetricEnabled("\(cardID).weekly", true)

        XCTAssertEqual(widgets(store, cardID), ["\(cardID).weekly"])
        XCTAssertEqual(widgets(makeStore(defaults: defaults), cardID), ["\(cardID).weekly"])
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
    }

    private func makeStore(
        defaults: UserDefaults,
        includesCodexAccountCard: Bool = false,
        defaultMetricIDs: [String] = ["claude.session", "claude.weekly", "claude.sonnet"]
    ) -> LayoutStore {
        LayoutStore(
            registry: .accountQuotaCards(includesCodexAccountCard: includesCodexAccountCard),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: defaultMetricIDs,
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly", "claude.sonnet"],
            defaultPinnedMetricIDs: []
        )
    }

    private func widgets(_ store: LayoutStore, _ providerID: String) -> [String]? {
        store.displayGroups.first { $0.provider.id == providerID }?.widgets.map(\.descriptorID)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.AccountCardLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// 기본 Claude 카드 + 등록 계정 카드 하나(+ 순서 검증용 Codex) — 카드들이 같은 metric 3종을 제공
    /// `extraCardIDs`는 나중에 나타나는 Claude 계정 카드.
    static func accountQuotaCards(includesCodexAccountCard: Bool, extraCardIDs: [String] = []) -> WidgetRegistry {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let card = Provider(id: "claude@profile-work", displayName: "Claude — Work", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var providers =
            [claude, card]
            + extraCardIDs.map {
                Provider(id: $0, displayName: "Claude — \($0)", icon: .providerMark("claude"))
            } + [codex]
        if includesCodexAccountCard {
            providers.append(
                Provider(id: "codex@profile-account-2", displayName: "Codex — Account 2", icon: .providerMark("codex")))
        }
        func descriptors(_ provider: Provider) -> [WidgetDescriptor] {
            ["session", "weekly", "sonnet"].map { suffix in
                WidgetDescriptor(
                    id: "\(provider.id).\(suffix)",
                    providerID: provider.id,
                    metricLabel: suffix,
                    sample: WidgetData(
                        title: suffix,
                        icon: provider.icon,
                        kind: .percent,
                        used: 0,
                        limit: 100
                    )
                )
            }
        }
        return WidgetRegistry(
            providers: providers,
            descriptors: providers.flatMap(descriptors)
        )
    }
}
