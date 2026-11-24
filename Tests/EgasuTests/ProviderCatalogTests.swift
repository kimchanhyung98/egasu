import XCTest
@testable import Egasu

@MainActor
final class ProviderCatalogTests: XCTestCase {
    func testExportedHistoryNamesSharedSourcesOnlyWhenEnabled() throws {
        for includeShared in [true, false] {
            let claude = ClaudeProvider(includeSharedUsage: includeShared)
            let codex = CodexProvider(includeSharedUsage: includeShared)
            let claudeHistory = try XCTUnwrap(claude.widgetDescriptors.compactMap(\.historyResource).first)
            let codexHistory = try XCTUnwrap(codex.widgetDescriptors.compactMap(\.historyResource).first)
            XCTAssertEqual(claudeHistory.sourceNote, includeShared
                ? "From your Claude usage history and local tools (estimated)"
                : "From your Claude usage history (estimated)")
            XCTAssertEqual(codexHistory.sourceNote, includeShared
                ? "From your Codex logs and local tools (estimated)"
                : "From your Codex logs (estimated)")
        }
        let grok = try XCTUnwrap(GrokProvider().widgetDescriptors.compactMap(\.historyResource).first)
        XCTAssertEqual(grok.sourceNote, "From your Grok usage files, logs, and local tools (estimated)")
    }

    func testEstablishedProvidersLeadAlphabeticalTail() {
        let names = ProviderCatalog.make().map(\.provider.displayName)

        XCTAssertEqual(Array(names.prefix(3)), ["Claude", "Codex", "Cursor"])
        XCTAssertEqual(Array(names.dropFirst(3)), names.dropFirst(3).sorted())
    }

    private func makeScratchDefaults() -> UserDefaults {
        let suiteName = "EgasuTests.ProviderCatalog.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testCodexSnapshotCardsSlotInAfterTheDefaultCodexCard() {
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")

        let runtimes = ProviderCatalog.make(snapshotCards: [card])

        let ids = runtimes.map(\.provider.id)
        XCTAssertEqual(Array(ids.prefix(4)), ["claude", "codex", "codex@profile-p1", "cursor"])
        let accountRuntime = runtimes.compactMap { $0 as? CodexProvider }.first { $0.provider.id == card.id }
        XCTAssertEqual(accountRuntime?.provider.displayName, "Codex")
        XCTAssertEqual(accountRuntime?.includeSharedUsage, false)
        XCTAssertEqual(
            accountRuntime?.authStore.managedSharedAuthHome,
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        )
        let descriptorIDs = accountRuntime?.widgetDescriptors.map(\.id) ?? []
        XCTAssertEqual(
            descriptorIDs.count,
            CodexProvider().widgetDescriptors.count,
            "a snapshot card exposes exactly the default card's metric set"
        )
        for expected in ["session", "weekly", "trend", "resetWatch", "rateLimitResets", "credits", "today"] {
            XCTAssertTrue(
                descriptorIDs.contains("\(card.id).\(expected)"),
                "missing per-card metric \(card.id).\(expected)"
            )
        }
        XCTAssertFalse(descriptorIDs.contains("codex.session"), "metric ids never leak the bare card id")
    }

    func testCodexSnapshotUsesTheManagedSharedHome() {
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")
        let snapshot = ProviderCatalog.make(snapshotCards: [card], codexSharedAuthHome: "/fixture/.codex")
            .compactMap { $0 as? CodexProvider }.first { $0.provider.id == card.id }
        XCTAssertEqual(snapshot?.authStore.managedSharedAuthHome, "/fixture/.codex")
    }

    func testOnlyThePendingCodexProfilesRotationIsDeferredAndResumesWithoutRebuildingTheCatalog() throws {
        let defaults = makeScratchDefaults()
        let profiles = AccountProfilesStore(defaults: defaults)
        let pending = try profiles.add(family: "codex", label: "Pending", identityKey: "workspace", id: "pending")
        let other = try profiles.add(family: "codex", label: "Other", identityKey: "other-workspace", id: "other")
        let transaction = try profiles.beginIdentityReplacement(
            profileID: pending.id, with: pending.identityKey, replacesSharedAuthentication: true)
        let cards = [pending, other].map {
            AccountUsageSnapshotCard(id: AccountUsageCardPlanner.cardID(family: "codex", profileID: $0.id),
                                     profileID: $0.id, family: "codex")
        }
        let runtimes = ProviderCatalog.make(
            defaults: defaults, snapshotCards: cards, codexSharedAuthHome: "/fixture/.codex",
            codexSharedSnapshotProfileID: pending.id).compactMap { $0 as? CodexProvider }
        for runtime in runtimes {
            XCTAssertEqual(try runtime.allowsCredentialRefresh(), runtime.provider.id == cards[1].id)
        }
        try profiles.cancelIdentityReplacement(transaction)
        for runtime in runtimes { XCTAssertTrue(try runtime.allowsCredentialRefresh()) }
    }

    func testCodexResetWatchPrecedesRateLimitResets() throws {
        let codex = try XCTUnwrap(
            ProviderCatalog.make()
                .compactMap { $0 as? CodexProvider }
                .first { $0.provider.id == "codex" }
        )
        let descriptorIDs = codex.widgetDescriptors.map(\.id)
        let resetWatchIndex = try XCTUnwrap(descriptorIDs.firstIndex(of: "codex.resetWatch"))
        let rateLimitResetsIndex = try XCTUnwrap(descriptorIDs.firstIndex(of: "codex.rateLimitResets"))

        XCTAssertEqual(resetWatchIndex + 1, rateLimitResetsIndex)
    }

    func testCodexIdentityBindingKeepsManagedSnapshotOwnership() throws {
        let binding = CodexAccountBinding(home: "/Users/x/.codex", identityKey: "account-a")
        let provider = try XCTUnwrap(ProviderCatalog.make(
            codexSharedAuthHome: binding.home, codexSharedSnapshotProfileID: "p1",
            codexAccountBinding: binding
        ).compactMap { $0 as? CodexProvider }.first)

        XCTAssertEqual(provider.authStore.scope, .home(path: binding.home))
        XCTAssertEqual(provider.authStore.expectedIdentityKey, binding.identityKey)
        XCTAssertEqual(provider.authStore.managedSnapshotProfileID, "p1")
    }

    func testCodexIdentityBindingWithoutManagedHomeDoesNotAcquireSnapshotOwnership() throws {
        let binding = CodexAccountBinding(home: "/Users/x/.config/codex", identityKey: "account-a")
        let provider = try XCTUnwrap(ProviderCatalog.make(
            codexSharedSnapshotProfileID: "p1", codexAccountBinding: binding
        ).compactMap { $0 as? CodexProvider }.first)

        XCTAssertEqual(provider.authStore.scope, .home(path: binding.home))
        XCTAssertEqual(provider.authStore.expectedIdentityKey, binding.identityKey)
        XCTAssertNil(provider.authStore.managedSnapshotProfileID)
    }

    func testManagedSwitchingPinsTheDefaultCodexCardToTheSharedAuthFile() throws {
        let pinned = ProviderCatalog.make(
            codexSharedAuthHome: "/Users/x/.codex",
            codexSharedSnapshotProfileID: "p1"
        )
            .compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == "codex" }
        XCTAssertEqual(pinned?.authStore.scope, .home(path: "/Users/x/.codex"))
        XCTAssertEqual(pinned?.authStore.managedSnapshotProfileID, "p1")

        let unmanaged = ProviderCatalog.make()
            .compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == "codex" }
        XCTAssertEqual(unmanaged?.authStore.scope, .standard)
        XCTAssertNil(unmanaged?.authStore.managedSnapshotProfileID)

        let unbound = ProviderCatalog.make(codexSharedAuthHome: "/Users/x/.codex")
            .compactMap { $0 as? CodexProvider }
            .first { $0.provider.id == "codex" }
        XCTAssertNil(unbound?.authStore.managedSnapshotProfileID)
    }

    func testManagedSwitchingPinsTheDefaultClaudeCardToTheSharedHome() {
        let pinned = ProviderCatalog.make(claudeManagedSwitchActive: true)
            .compactMap { $0 as? ClaudeProvider }
            .first { $0.provider.id == "claude" }
        XCTAssertEqual(pinned?.authStore.pinsSharedHome, true)
        XCTAssertEqual(pinned?.logUsageScanner.pinsSharedHome, true)
        XCTAssertEqual(pinned?.authStore.allowsDesktopFallback, false)

        let unmanaged = ProviderCatalog.make()
            .compactMap { $0 as? ClaudeProvider }
            .first { $0.provider.id == "claude" }
        XCTAssertEqual(unmanaged?.authStore.pinsSharedHome, false)
        XCTAssertEqual(unmanaged?.logUsageScanner.pinsSharedHome, false)
    }

    func testAnotherClaudeLoginOnThisMacDisablesUnscopedPiUsage() {
        let claudeRuntimes = ProviderCatalog.make(hasUnregisteredClaudeLogins: true)
            .compactMap { $0 as? ClaudeProvider }

        XCTAssertTrue(claudeRuntimes.allSatisfy { !$0.includeSharedUsage })
        XCTAssertTrue(claudeRuntimes.allSatisfy { !$0.authStore.allowsDesktopFallback })
    }

    func testClaudeDesktopFallbackCanBeDisabledForTerminalQuotaChecks() throws {
        let provider = try XCTUnwrap(
            ProviderCatalog.make(allowsClaudeDesktopFallback: false)
                .compactMap { $0 as? ClaudeProvider }.first)
        XCTAssertFalse(provider.authStore.allowsDesktopFallback)
        XCTAssertFalse(provider.authStore.pinsSharedHome)
        XCTAssertTrue(provider.includeSharedUsage)
    }

    func testCustomizeShowsEachAccountForRestoringItsHiddenQuota() {
        let card = AccountUsageSnapshotCard(id: "claude@profile-work", profileID: "work", family: "claude")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")

        XCTAssertEqual(
            layout.customizeProviderRows
                .filter { ProviderAccountID.family(of: $0.id) == "claude" }
                .map(\.id),
            ["claude", card.id]
        )
    }

    func testCodexSnapshotCardsKeepQuotaAndCanonicalSharedRows() {
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")

        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertTrue(layout.isMetricEnabled("\(card.id).weekly"))

        let group = layout.displayGroups.first { $0.provider.id == card.id }
        XCTAssertNotNil(group, "the snapshot card renders its own dashboard group")
        let ids = group?.widgets.map(\.descriptorID) ?? []
        XCTAssertFalse(ids.contains("\(card.id).trend"), "공통 이력은 기본 카드에서 한 번 표시")
        XCTAssertTrue(ids.contains("\(card.id).rateLimitResets"))
        XCTAssertTrue(layout.isMetricEnabled("codex.trend"))

        XCTAssertFalse(
            layout.priorityPinIDs.contains { ProviderAccountID.isAccountCard($0) },
            "새 계정 카드는 Priority 고정 없이 시작"
        )
    }

    func testAccountCardDiscoveredAfterLaunchSeedsTheLiveLayout() {
        let defaults = makeScratchDefaults()
        let layout = LayoutStore(
            registry: WidgetRegistry.from(ProviderCatalog.make()),
            defaults: defaults,
            storageKey: "layout"
        )
        let card = AccountUsageSnapshotCard(id: "codex@profile-p1", profileID: "p1", family: "codex")
        let updatedRegistry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))

        layout.replaceRegistry(updatedRegistry)

        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertTrue(layout.displayGroups.contains { $0.provider.id == card.id })
        XCTAssertFalse(
            layout.priorityPinIDs.contains { $0.hasPrefix("\(card.id).") },
            "an account discovered at runtime must not claim menu-bar space by default"
        )
    }

    func testInactiveDefaultSnapshotSeedsASelectableDashboardGroup() {
        let defaults = makeScratchDefaults()
        let layout = LayoutStore(
            registry: WidgetRegistry.from(ProviderCatalog.make()),
            defaults: defaults,
            storageKey: "layout"
        )
        let card = AccountUsageSnapshotCard(
            id: "claude@profile-claude-default-home",
            profileID: "claude-default-home",
            family: "claude"
        )

        layout.replaceRegistry(WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card])))

        XCTAssertTrue(layout.isMetricEnabled("\(card.id).session"))
        XCTAssertTrue(layout.displayGroups.contains { $0.provider.id == card.id })
    }

    func testPriorityPinsBelongToOneCardAndHidingAMetricUnpinsOnlyThatCard() {
        let card = AccountUsageSnapshotCard(id: "claude@profile-work", profileID: "work", family: "claude")
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: [card]))
        let layout = LayoutStore(registry: registry, defaults: makeScratchDefaults(), storageKey: "layout")

        layout.setMetric("\(card.id).weekly", pinned: true)
        XCTAssertTrue(layout.isMetricPinned("\(card.id).weekly"))
        XCTAssertFalse(layout.isMetricPinned("claude.weekly"), "고정은 카드 단위 — 다른 계정에 번지지 않음")

        layout.setMetric("claude.weekly", pinned: true)
        layout.setMetricEnabled("claude.weekly", false)
        XCTAssertEqual(layout.priorityPinIDs, ["\(card.id).weekly"], "숨긴 카드의 고정만 해제")

        layout.setMetric("claude.weekly", pinned: true)
        XCTAssertEqual(layout.priorityPinIDs, ["\(card.id).weekly"], "숨긴 지표는 고정 불가")
    }
}
