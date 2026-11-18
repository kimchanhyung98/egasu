import XCTest
@testable import Egasu

/// 공통 이력·계정별 한도·기존 설정 이전의 계정 카드 호환성.
@MainActor
final class AccountCardLayoutSharingTests: XCTestCase {
    private let cardID = "claude@profile-work"

    func testLegacyGroupingKeepsPrivateQuotaAndCanonicalSharedRows() {
        let defaults = makeDefaults("OnDemandSplit")
        defaults.set(["claude.today"], forKey: "layout.expandedMetrics")
        saveStored(["claude": ["claude.today", "claude.trend", "claude.session"]],
                   forKey: "layout.metricOrderByProvider", in: defaults)

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.displayGroups.first { $0.provider.id == cardID }?.widgets.map(\.descriptorID),
                       ["\(cardID).session"])
        XCTAssertEqual(store.displayGroups.first { $0.provider.id == "claude" }?.widgets.map(\.descriptorID),
                       ["claude.trend", "claude.session", "claude.today"])
        XCTAssertFalse(LayoutPersistence(defaults: defaults, storageKey: "layout").hasOnDemandState)
    }

    func testHidingAMetricFromAnAccountCardHidesItOnEveryCard() {
        let store = makeStore(defaults: makeDefaults("HideEverywhere"))
        XCTAssertTrue(store.isMetricEnabled("claude.trend"))

        store.setMetricEnabled("\(cardID).trend", false)

        XCTAssertFalse(store.isMetricEnabled("claude.trend"))
        XCTAssertFalse(store.isMetricEnabled("\(cardID).trend"))
        XCTAssertFalse(
            store.placed.contains { ProviderAccountID.isSharedMetricAlias($0.descriptorID) },
            "공통 이력 지표만 프로바이더별로 한 번 저장"
        )
    }

    func testMovingSharedHistoryFromAnAccountChangesOnlyTheSharedOrder() {
        let defaults = makeDefaults("ReorderShared")
        let store = makeStore(defaults: defaults)

        XCTAssertTrue(store.reorderMetric(dragged: "\(cardID).today", target: "\(cardID).trend", in: cardID))

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id),
                       ["claude.session", "claude.today", "claude.trend"])
        XCTAssertEqual(store.displayGroups.first { $0.provider.id == cardID }?.widgets.map(\.descriptorID),
                       ["\(cardID).session"])
        XCTAssertEqual(makeStore(defaults: defaults).orderedSupportedMetrics(for: "claude").map(\.id),
                       ["claude.session", "claude.today", "claude.trend"])
    }

    func testEveryCardsMetricsFeedRefreshAndNotifications() {
        let store = makeStore(defaults: makeDefaults("RenderedDescriptors"))

        let ids = store.orderedRenderedDescriptors().map(\.id)

        XCTAssertTrue(ids.contains("claude.session"))
        XCTAssertTrue(
            ids.contains("\(cardID).session"),
            "an account card's metrics must still reach quota notifications"
        )
    }

    func testReorderingAProviderMovesItsWholeAccountBlock() {
        let store = makeStore(defaults: makeDefaults("ReorderFamilyBlock"))
        store.providerOrder = ["claude", cardID, "codex"]

        XCTAssertTrue(store.reorderProvider(dragged: "codex", target: "claude"))

        XCTAssertEqual(
            store.providerOrder,
            ["codex", "claude", cardID],
            "accounts of a provider stay together, so switching accounts never moves the section"
        )
    }

    func testProviderReorderKeepsTheAccountBlockAndExistingPriorityPins() {
        let defaults = makeDefaults("ReorderNewAccountRuntime")
        saveStored(["claude", "codex", "cursor"], forKey: "layout.providerOrder", in: defaults)
        let snapshotID = "claude@profile-b"
        let providers = [
            Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude")),
            Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex")),
            Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor")),
            Provider(id: snapshotID, displayName: "Claude — B", icon: .providerMark("claude")),
        ]
        let descriptors = providers.map { provider in
            WidgetDescriptor(
                id: "\(provider.id).session",
                providerID: provider.id,
                metricLabel: "session",
                sample: WidgetData(
                    title: "session",
                    icon: provider.icon,
                    kind: .percent,
                    used: 0,
                    limit: 100
                )
            )
        }
        let store = LayoutStore(
            registry: WidgetRegistry(providers: providers, descriptors: descriptors),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "codex.session", "cursor.session"],
            migrationBaselineMetricIDs: ["claude.session", "codex.session", "cursor.session"],
            defaultPinnedMetricIDs: []
        )
        for metricID in ["claude.session", "codex.session", "cursor.session"] {
            store.setMetric(metricID, pinned: true)
        }

        XCTAssertEqual(store.providerOrder, ["claude", "codex", "cursor"])
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        XCTAssertEqual(store.providerOrder, ["cursor", "claude", snapshotID, "codex"])
        XCTAssertEqual(store.priorityPinIDs, ["claude.session", "codex.session", "cursor.session"])
    }

    func testProviderReorderUsesCustomizeOrderWithoutChangingAccountOrder() {
        let defaults = makeDefaults("CanonicalProviderOrder")
        let layout = makeStore(defaults: defaults)
        layout.providerOrder = [cardID, "codex", "claude"]

        let firstClaudeAccount = AccountProfile(
            id: "account-1",
            family: "claude",
            label: "Account 1",
            identityKey: "acct-account-1",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let work = AccountProfile(
            id: "work",
            family: "claude",
            label: "work",
            identityKey: "acct-work",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let profiles = [firstClaudeAccount, work]
        let presentation = AccountCardPresentationStore(defaults: defaults)
        XCTAssertTrue(presentation.reorder(
            dragged: work.id,
            target: firstClaudeAccount.id,
            family: "claude",
            profiles: profiles
        ))
        let accountOrder = presentation.orderedProfiles(profiles, family: "claude").map(\.id)

        XCTAssertEqual(layout.customizeProviderRows.map(\.id), [cardID, "codex", "claude"])
        XCTAssertTrue(layout.reorderProvider(dragged: "claude", target: "codex"))

        XCTAssertEqual(layout.customizeProviderRows.map(\.id), ["codex", cardID, "claude"])
        XCTAssertEqual(layout.providerOrder, ["codex", cardID, "claude"])
        XCTAssertEqual(
            presentation.orderedProfiles(profiles, family: "claude").map(\.id),
            accountOrder,
            "provider-family movement must not rewrite the separately persisted account order"
        )
    }

    func testAccountOrderChangesDoNotMutateLayoutOrLegacySelections() {
        let defaults = makeDefaults("PresentationIsolation")
        let codexCardID = "codex@profile-account-2"
        saveStored(["codex", codexCardID, "claude", cardID], forKey: "layout.providerOrder", in: defaults)
        let layout = makeStore(defaults: defaults, includesCodexAccountCard: true)
        layout.setMetricEnabled("codex.session", true)
        layout.setMetricEnabled("codex.trend", true)
        layout.setMetric("claude.session", pinned: true)
        layout.setMetric("codex.session", pinned: true)
        defaults.set(cardID, forKey: "openusage.dashboardUsageAccount.claude")
        defaults.set(codexCardID, forKey: "openusage.dashboardUsageAccount.codex")

        let firstClaudeAccount = AccountProfile(
            id: "account-1",
            family: "claude",
            label: "Account 1",
            identityKey: "acct-account-1",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let work = AccountProfile(
            id: "work",
            family: "claude",
            label: "work",
            identityKey: "acct-work",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let personal = AccountProfile(
            id: "personal",
            family: "codex",
            label: "personal",
            identityKey: "acct-personal",
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let secondCodexAccount = AccountProfile(
            id: "account-2",
            family: "codex",
            label: "Account 2",
            identityKey: "acct-account-2",
            createdAt: Date(timeIntervalSince1970: 2)
        )
        let profiles = [firstClaudeAccount, work, personal, secondCodexAccount]
        let providerOrder = layout.providerOrder
        let placed = layout.placed
        let metricOrder = layout.metricOrderByProvider
        let pins = layout.priorityPinIDs
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        let persistedPlaced = persistence.loadPlaced()
        let persistedProviderOrder = persistence.loadProviderOrder()
        let persistedMetricOrder = persistence.loadMetricOrder()
        let persistedPins = persistence.loadPriorityPins()

        let presentation = AccountCardPresentationStore(defaults: defaults)
        XCTAssertTrue(presentation.reorder(
            dragged: work.id,
            target: firstClaudeAccount.id,
            family: "claude",
            profiles: profiles
        ))
        XCTAssertTrue(presentation.reorder(
            dragged: secondCodexAccount.id,
            target: personal.id,
            family: "codex",
            profiles: profiles
        ))
        let accountOrders = ["claude": [work.id, firstClaudeAccount.id], "codex": [secondCodexAccount.id, personal.id]]
        for family in ["claude", "codex"] {
            XCTAssertEqual(presentation.orderedProfiles(profiles, family: family).map(\.id), accountOrders[family])
        }
        XCTAssertEqual(layout.providerOrder, providerOrder)
        XCTAssertEqual(layout.placed, placed)
        XCTAssertEqual(layout.metricOrderByProvider, metricOrder)
        XCTAssertEqual(layout.priorityPinIDs, pins)
        XCTAssertEqual(defaults.string(forKey: "openusage.dashboardUsageAccount.claude"), cardID)
        XCTAssertEqual(defaults.string(forKey: "openusage.dashboardUsageAccount.codex"), codexCardID)
        XCTAssertEqual(persistence.loadPlaced(), persistedPlaced)
        XCTAssertEqual(persistence.loadProviderOrder(), persistedProviderOrder)
        XCTAssertEqual(persistence.loadMetricOrder(), persistedMetricOrder)
        XCTAssertEqual(persistence.loadPriorityPins(), persistedPins)
    }

    // MARK: - Migration of layouts saved per account card

    func testLegacyAccountEntriesCopyPrivateQuotaWithoutOverridingSharedChoices() {
        let defaults = makeDefaults("FoldStoredEntries")
        saveStored(
            [
                PlacedWidget(descriptorID: "claude.session"),
                PlacedWidget(descriptorID: "\(cardID).session"),
                PlacedWidget(descriptorID: "\(cardID).trend"),
            ],
            forKey: "layout",
            in: defaults
        )
        defaults.set(["claude.trend", "\(cardID).today"], forKey: "layout.expandedMetrics")
        defaults.set([cardID], forKey: "layout.expandedProviders")

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session", "\(cardID).session"])
        XCTAssertFalse(store.isMetricEnabled("claude.trend"), "계정의 공통 복사본으로 기본 카드의 숨김을 덮지 않음")

        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        XCTAssertEqual(persistence.loadPlaced()?.map(\.descriptorID), ["claude.session", "\(cardID).session"])
        XCTAssertFalse(persistence.hasOnDemandState)
    }

    func testFamilyGroupingWinsOverSharedAliasesBeforeFlattening() {
        let defaults = makeDefaults("FamilyExpansionWins")
        defaults.set(["claude.trend", "\(cardID).today"], forKey: "layout.expandedMetrics")
        saveStored(["claude": ["claude.trend", "claude.today", "claude.session"]],
                   forKey: "layout.metricOrderByProvider", in: defaults)

        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id),
                       ["claude.today", "claude.session", "claude.trend"])
        XCTAssertFalse(LayoutPersistence(defaults: defaults, storageKey: "layout").hasOnDemandState)
    }

    func testLegacyStarsMigrateWithoutTheRetiredProviderCap() {
        let defaults = makeDefaults("MigrateStars")
        defaults.set(
            ["\(cardID).today", "claude.session", "\(cardID).trend"],
            forKey: "layout.menuBarPins"
        )
        let store = makeStore(defaults: defaults)

        XCTAssertEqual(store.migrateMenuBarStars(), 4)
        XCTAssertEqual(store.priorityPinIDs, [
            "claude.session", "\(cardID).session", "claude.today", "claude.trend"
        ])
        XCTAssertEqual(
            LayoutPersistence(defaults: defaults, storageKey: "layout").loadPriorityPins().map(Set.init),
            store.priorityPinIDs)
        XCTAssertNil(store.migrateMenuBarStars(), "저장된 Priority 고정은 다시 이전하지 않음")
    }

    // MARK: - Fixtures

    private func makeStore(defaults: UserDefaults, includesCodexAccountCard: Bool = false) -> LayoutStore {
        LayoutStore(
            registry: .accountCards(includesCodexAccountCard: includesCodexAccountCard),
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.trend", "claude.today"],
            defaultPinnedMetricIDs: []
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.AccountCardLayout.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}

private extension WidgetRegistry {
    /// 기본 Claude 카드 + 등록 계정 카드 하나(+ 순서 검증용 Codex) — 카드들이 같은 metric 3종을 제공
    static func accountCards(includesCodexAccountCard: Bool) -> WidgetRegistry {
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let card = Provider(id: "claude@profile-work", displayName: "Claude — Work", icon: .providerMark("claude"))
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        var providers = [claude, card, codex]
        if includesCodexAccountCard {
            providers.append(Provider(id: "codex@profile-account-2", displayName: "Codex — Account 2", icon: .providerMark("codex")))
        }
        func descriptors(_ provider: Provider) -> [WidgetDescriptor] {
            ["session", "trend", "today"].map { suffix in
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
