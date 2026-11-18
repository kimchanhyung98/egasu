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


}
