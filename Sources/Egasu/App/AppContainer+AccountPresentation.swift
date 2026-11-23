import Foundation

extension AppContainer {
    private static let recommendationSwitcher = AccountSelectionSwitcher()

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

    func accountRecommendation(
        for family: String, at now: Date, confirming profileID: String? = nil
    ) -> AccountSwitchRecommendation? {
        guard AccountProfilesStore.isSupportedFamily(family), enablement.isEnabled(family),
            popover.signingInAgainAccountID == nil,
            !accountProfiles.hasUnreadableRegistry, !accountSwitch.isSwitching || accountSwitch.profileID == profileID,
            let current = accountProfiles.preferredProfile(family: family), accountProfileID(for: family) == current.id
        else { return nil }
        let profiles = orderedAccountProfiles(for: family)
        guard profiles.count > 1 else { return nil }
        let recommendation = accountRecommendationSettings.recommendation(
            current: current, profiles: profiles, at: now
        ) { profile in
            recommendationQuota(for: profile, at: now)
        }
        if family == "claude", recommendation != nil, (try? Self.recommendationSwitcher.hasPendingSwitch()) != false {
            return nil
        }
        return recommendation
    }

    func dismissAccountRecommendation(_ suggestion: AccountSwitchRecommendation, at now: Date) {
        guard accountRecommendation(for: suggestion.current.family, at: now) == suggestion else { return }
        accountRecommendationSettings.dismiss(suggestion, at: now) { recommendationQuota(for: $0, at: now) }
    }

    private func recommendationQuota(for profile: AccountProfile, at now: Date) -> AccountSwitchQuota? {
        let card =
            profile.id == accountProfiles.preferredProfileID(family: profile.family)
            ? profile.family : AccountUsageCardPlanner.cardID(family: profile.family, profileID: profile.id)
        return dataStore.recommendationQuota(for: profile, cardID: card, at: now)
    }

    static func observeAccountRecommendationSession(
        _ snapshot: ProviderSnapshot, profiles: AccountProfilesStore, dataStore: WidgetDataStore,
        settings: AccountRecommendationSettingsStore, at now: Date
    ) {
        let family = ProviderAccountID.family(of: snapshot.providerID)
        guard let observedAt = snapshot.liveQuotaObservedAt else { return }
        for profile in profiles.profiles(family: family) {
            let savedCard = AccountUsageCardPlanner.cardID(family: family, profileID: profile.id)
            guard snapshot.providerID == family || snapshot.providerID == savedCard,
                let quota = dataStore.recommendationQuota(for: profile, cardID: snapshot.providerID, at: now)
            else { continue }
            settings.observeSession(for: profile, quota: quota, observedAt: observedAt, at: now)
        }
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
