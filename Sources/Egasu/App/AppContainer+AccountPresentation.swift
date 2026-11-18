import Foundation

extension AppContainer {
    static func configureQuotaNotificationNames(
        dataStore: WidgetDataStore,
        accounts: ProviderAccountsStore,
        profiles: AccountProfilesStore,
        profileID: @escaping @MainActor (String) -> String?
    ) {
        dataStore.resolveDisplayName = { cardID in
            guard let id = profileID(cardID), let profile = profiles.profile(id: id) else {
                return accounts.resolvedDisplayName(cardID: cardID)
            }
            return L10n.metrics("%@ — %@", profile.family.capitalized, profile.label)
        }
    }

    func orderedAccountProfiles(for family: String) -> [AccountProfile] {
        accountCardPresentation.orderedProfiles(accountProfiles.profiles(family: family), family: family)
    }

    func accountCardDisplayMode(for family: String) -> AccountCardDisplayMode {
        accountCardPresentation.effectiveMode(
            for: family,
            profiles: accountProfiles.profiles(family: family),
            registryReadable: !accountProfiles.hasUnreadableRegistry
        )
    }

    /// 등록 계정 표시 대상·순서만 계산 — 런타임 catalog·CLI·HTTP API는 유지.
    func orderedAccountCardIDs(_ cardIDs: [String]) -> [String] {
        let profileOrders = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.map {
            ($0, orderedAccountProfiles(for: $0).map(\.id))
        })
        let profileMapping = Dictionary(uniqueKeysWithValues: cardIDs.compactMap { cardID in
            accountProfileID(for: cardID).map { (cardID, $0) }
        })
        return AccountCardPresentationPlanner.orderedCardIDs(
            cardIDs,
            familyOrder: layout.customizeProviderRows.map(\.id),
            orderedProfileIDsByFamily: profileOrders,
            profileIDsByCardID: profileMapping
        )
    }

    /// 푸터 공유 대상 — 표시 중인 계정에 저장된 계정 선택·표시 모드 적용.
    func presentedShareAccounts() -> [DashboardAccount] {
        _ = accountSelectionRevision
        let selections = DashboardUsageAccountSelection.storedSelections()
        let accounts = dashboardAccounts()
        let cardIDs = accounts.map(\.id)
        let selectedIDs = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.compactMap { family in
            visibleAccountCardID(
                for: family,
                among: accountCardIDs(for: family, among: cardIDs),
                stored: selections[family] ?? ""
            ).map { (family, $0) }
        })
        let modes = Dictionary(uniqueKeysWithValues: AccountProfilesStore.supportedFamilies.map {
            ($0, accountCardDisplayMode(for: $0))
        })
        let presentedIDs = Set(AccountCardPresentationPlanner.presentedCardIDs(
            orderedCardIDs: cardIDs,
            modesByFamily: modes,
            selectedCardIDsByFamily: selectedIDs
        ))
        return accounts.filter { presentedIDs.contains($0.id) }
    }

    func accountCardTitle(for provider: Provider) -> String {
        let family = ProviderAccountID.family(of: provider.id)
        return AccountCardPresentationPlanner.cardTitle(
            providerID: provider.id,
            fallback: displayName(for: provider),
            mode: accountCardDisplayMode(for: family),
            accountName: accountOptionTitle(for: provider.id)
        )
    }
}
