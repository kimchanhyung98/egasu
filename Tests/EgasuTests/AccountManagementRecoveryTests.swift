import XCTest
@testable import Egasu

@MainActor
final class AccountManagementRecoveryTests: XCTestCase {
    func testAccountsIncludesInactiveProfilesWithoutCreatingUsageCards() {
        for family in AccountProfilesStore.supportedFamilies {
            let selected = profile("selected", family: family)
            let missing = profile("missing", family: family)
            let registry = registry([family, "cursor"])
            let mapping = [family: selected.id]

            let providers = AccountCardPresentationPlanner.managementProviders(
                registry.providers, profiles: [selected, missing], profileIDsByCardID: mapping
            )
            let missingID = cardID(missing)

            XCTAssertEqual(providers.map(\.id), [family, "cursor", missingID])
            XCTAssertEqual(providers.last?.icon, registry.provider(id: family)?.icon)
            XCTAssertEqual(profileID(missingID, mapping: mapping, profiles: [selected, missing]), missing.id)
            XCTAssertNil(registry.provider(id: missingID), "Accounts에서만 관리 행을 보완")
            XCTAssertTrue(
                AccountUsageCardPlanner.snapshotCards(
                    profiles: [selected, missing], preferredProfileIDs: [family: selected.id],
                    availableSnapshotProfileIDs: []
                ).isEmpty, "저장 인증 없는 계정의 조회 runtime은 만들지 않음")
            XCTAssertFalse(
                AccountCardPresentationPlanner.isInUse(
                    cardID: missingID, profileID: missing.id, preferredProfileID: selected.id
                ))
        }
    }

    func testRestoringCredentialsKeepsTheAccountNameOrderAndOpenDetail() throws {
        for family in AccountProfilesStore.supportedFamilies {
            let defaults = makeDefaults()
            let profiles = AccountProfilesStore(defaults: defaults)
            let selected = try profiles.add(family: family, label: "Personal", identityKey: "personal")
            let missing = try profiles.add(family: family, label: "Work", identityKey: "work")
            let order = AccountCardPresentationStore(defaults: defaults)
            XCTAssertTrue(
                order.reorder(
                    dragged: missing.id, target: selected.id, family: family, profiles: profiles.profiles
                ))
            try profiles.rename(profileID: missing.id, to: "Office")
            let mapping = [family: selected.id]
            let missingID = cardID(missing)
            let state = PopoverState()
            state.openAccounts(missingID)

            let before = orderedManagementIDs(
                registry([family]).providers, profiles: profiles, order: order, mapping: mapping
            )
            state.reconcileAccountDetail(
                in: registry([family]), previousProfileIDsByCard: mapping, nextProfileIDsByCard: mapping,
                registeredProfiles: profiles.profiles
            )
            XCTAssertEqual(state.accountDetailID, missingID, "다른 카탈로그 변경에도 복구 상세 유지")

            let restored = [family: selected.id, missingID: missing.id]
            let restoredRegistry = registry([family, missingID])
            let after = orderedManagementIDs(
                restoredRegistry.providers, profiles: profiles, order: order, mapping: restored
            )
            state.reconcileAccountDetail(
                in: restoredRegistry, previousProfileIDsByCard: mapping, nextProfileIDsByCard: restored,
                registeredProfiles: profiles.profiles
            )

            XCTAssertEqual(before, [missingID, family])
            XCTAssertEqual(after, before, "저장 로그인 복원 후 같은 계정의 행은 중복되지 않음")
            XCTAssertEqual(state.accountDetailID, missingID)
            XCTAssertEqual(profiles.profile(id: missing.id)?.label, "Office")
            XCTAssertEqual(profiles.preferredProfileID(family: family), selected.id)
            XCTAssertEqual(
                AccountCardPresentationStore(defaults: defaults)
                    .orderedProfiles(profiles.profiles, family: family).map(\.id), [missing.id, selected.id])
        }
    }

    func testAnOpenUsageCardBecomesAManagementRowWhenItsCredentialsDisappear() {
        let selected = profile("selected")
        let missing = profile("missing")
        let missingID = cardID(missing)
        let state = PopoverState()
        state.openAccounts(missingID)

        state.reconcileAccountDetail(
            in: registry(["codex"]),
            previousProfileIDsByCard: ["codex": selected.id, missingID: missing.id],
            nextProfileIDsByCard: ["codex": selected.id],
            registeredProfiles: [selected, missing]
        )

        XCTAssertEqual(state.accountDetailID, missingID)
        XCTAssertEqual(state.screen, .accounts)
    }

    func testARecoveredAccountDetailFollowsTheSameProfileToTheSharedCard() {
        let selected = profile("selected")
        let recovered = profile("recovered")
        let state = PopoverState()
        state.openAccounts(cardID(recovered))

        state.reconcileAccountDetail(
            in: registry(["codex", cardID(selected)]),
            previousProfileIDsByCard: ["codex": selected.id],
            nextProfileIDsByCard: ["codex": recovered.id, cardID(selected): selected.id],
            registeredProfiles: [selected, recovered]
        )

        XCTAssertEqual(state.accountDetailID, "codex")
    }

    func testRemovingTheProfileClosesItsDetailEvenWhenTheRuntimeCatalogIsUnchanged() throws {
        let profiles = AccountProfilesStore(defaults: makeDefaults())
        let selected = try profiles.add(family: "codex", label: "Personal", identityKey: "personal")
        let missing = try profiles.add(family: "codex", label: "Work", identityKey: "work")
        let state = PopoverState()
        state.openAccounts(cardID(missing))
        try profiles.archive(profileID: missing.id)

        let mapping = ["codex": selected.id]
        state.reconcileAccountDetail(
            in: registry(["codex"]), previousProfileIDsByCard: mapping, nextProfileIDsByCard: mapping,
            registeredProfiles: profiles.profiles
        )

        XCTAssertNil(state.accountDetailID)
        XCTAssertEqual(state.screen, .accounts)
        XCTAssertNil(
            AccountCardPresentationPlanner.snapshotProfileID(for: cardID(missing), profiles: profiles.profiles))
        XCTAssertEqual(
            AccountCardPresentationPlanner.managementProviders(
                registry(["codex"]).providers, profiles: profiles.profiles, profileIDsByCardID: mapping
            ).map(\.id), ["codex"])
    }

    func testRemovingTheLastProfileClosesItsDetailDespiteTheOldSharedCardMapping() {
        let removed = profile("removed")
        let state = PopoverState()
        state.openAccounts("codex")
        let mapping = ["codex": removed.id]

        state.reconcileAccountDetail(
            in: registry(["codex"]), previousProfileIDsByCard: mapping, nextProfileIDsByCard: mapping,
            registeredProfiles: []
        )

        XCTAssertNil(state.accountDetailID)
    }

    func testDisabledFamiliesAndArchivedProfilesDoNotAddManagementRows() {
        var archived = profile("archived")
        archived.isArchived = true
        let profiles = [profile("disabled", family: "claude"), archived]
        let providers = registry(["codex", "cursor"]).providers

        XCTAssertEqual(
            AccountCardPresentationPlanner.managementProviders(
                providers, profiles: profiles, profileIDsByCardID: [:]
            ), providers)
        XCTAssertNil(AccountCardPresentationPlanner.snapshotProfileID(for: cardID(archived), profiles: profiles))
        XCTAssertNil(AccountCardPresentationPlanner.snapshotProfileID(for: "claude@unknown", profiles: profiles))
    }

    func testUnreadableRegistryKeepsTheWarningAndDoesNotInventProfileRowsOrRewriteStorage() {
        let defaults = makeDefaults()
        let invalid = Data("unreadable registry".utf8)
        defaults.set(invalid, forKey: AccountProfilesStore.storageKey)
        let profiles = AccountProfilesStore(defaults: defaults)
        let providers = registry(["claude", "codex"]).providers

        XCTAssertEqual(
            AccountCardPresentationPlanner.managementProviders(
                providers, profiles: profiles.profiles, profileIDsByCardID: [:]
            ), providers)
        XCTAssertTrue(profiles.hasUnreadableRegistry, "Accounts 목록의 기존 오류 안내 조건 유지")
        XCTAssertEqual(defaults.data(forKey: AccountProfilesStore.storageKey), invalid)
    }

    private func orderedManagementIDs(
        _ providers: [Provider], profiles: AccountProfilesStore,
        order: AccountCardPresentationStore, mapping: [String: String]
    ) -> [String] {
        let management = AccountCardPresentationPlanner.managementProviders(
            providers, profiles: profiles.profiles, profileIDsByCardID: mapping
        )
        let resolved = Dictionary(
            uniqueKeysWithValues: management.compactMap { provider in
                profileID(provider.id, mapping: mapping, profiles: profiles.profiles).map { (provider.id, $0) }
            })
        return AccountCardPresentationPlanner.orderedCardIDs(
            management.map(\.id), familyOrder: providers.map(\.id),
            orderedProfileIDsByFamily: Dictionary(
                uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.map {
                    ($0, order.orderedProfiles(profiles.profiles, family: $0).map(\.id))
                }), profileIDsByCardID: resolved
        )
    }

    private func profileID(_ cardID: String, mapping: [String: String], profiles: [AccountProfile]) -> String? {
        mapping[cardID] ?? AccountCardPresentationPlanner.snapshotProfileID(for: cardID, profiles: profiles)
    }

    private func profile(_ id: String, family: String = "codex") -> AccountProfile {
        AccountProfile(id: id, family: family, label: id, identityKey: id, createdAt: .distantPast)
    }

    private func cardID(_ profile: AccountProfile) -> String {
        AccountUsageCardPlanner.cardID(family: profile.family, profileID: profile.id)
    }

    private func registry(_ ids: [String]) -> WidgetRegistry {
        WidgetRegistry(
            providers: ids.map {
                Provider(id: $0, displayName: $0, icon: .providerMark(ProviderAccountID.family(of: $0)))
            }, descriptors: [])
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "EgasuTests.AccountManagementRecovery.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
