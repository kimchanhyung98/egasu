import Foundation

extension AppContainer {
    /// All Usage·Priority·메뉴 막대가 공유하는 계정 섹션 목록 — 모든 표시 계정 카드, 사용자 저장 순서.
    func dashboardFamilies() -> [DashboardFamily] {
        let groups = layout.displayGroups
        let byID = Dictionary(uniqueKeysWithValues: groups.map { ($0.provider.id, $0) })
        var families: [DashboardFamily] = []
        for cardID in orderedAccountCardIDs(groups.map(\.provider.id)) {
            guard let group = byID[cardID] else { continue }
            let account = dashboardAccount(for: group)
            guard account.isVisible(headerNotice: dataStore.headerNotice(for:)) else { continue }
            let familyID = Self.dashboardFamilyID(for: cardID)
            if let index = families.firstIndex(where: { $0.id == familyID }) {
                families[index].accounts.append(account)
            } else {
                families.append(
                    DashboardFamily(
                        id: familyID,
                        provider: group.provider,
                        displayName: account.providerName,
                        accounts: [account]
                    ))
            }
        }
        return families.filter { $0.isVisible(headerNotice: dataStore.headerNotice(for:)) }
    }

    /// 모든 계정 섹션 — Priority 보드와 메뉴 막대 입력.
    func dashboardAccounts() -> [DashboardAccount] {
        dashboardFamilies().flatMap(\.accounts)
    }

    /// 계정 섹션을 묶는 카드 단위 — Claude·Codex는 패밀리, 나머지는 프로바이더.
    static func dashboardFamilyID(for cardID: String) -> String {
        let family = ProviderAccountID.family(of: cardID)
        return ProviderAccountID.families.contains(family) ? family : cardID
    }

    /// 캡션·Priority 둘째 줄 계정명 — Claude·Codex 등록 계정만, 나머지는 nil.
    func dashboardAccountName(for cardID: String) -> String? {
        guard ProviderAccountID.families.contains(ProviderAccountID.family(of: cardID)) else { return nil }
        return accountProfileLabel(for: cardID)
    }

    /// 등록 계정의 로그인 이메일 — 계정 카탈로그 라벨에서 추출, 알 수 없으면 nil.
    func accountLoginEmail(for cardID: String) -> String? {
        guard let profileID = accountProfileID(for: cardID),
            let profile = accountProfiles.profile(id: profileID)
        else { return nil }
        return accountLoginEmail(for: profile)
    }

    func accountLoginEmail(for profile: AccountProfile) -> String? {
        guard
            let label = accounts.records.first(where: {
                $0.family == profile.family && $0.identityKey == profile.identityKey
            })?.label
        else { return nil }
        return Self.loginEmail(fromAccountLabel: label)
    }

    /// 계정명 대신 볼 수 있는 로그인 이메일 — 계정명과 같으면 nil.
    func dashboardAccountEmail(for cardID: String) -> String? {
        guard let email = accountLoginEmail(for: cardID), email != accountProfileLabel(for: cardID) else { return nil }
        return email
    }

    /// 카탈로그 라벨의 이메일 부분 — Claude 라벨은 "email (Organization)" 형식.
    nonisolated static func loginEmail(fromAccountLabel label: String) -> String? {
        let email = (label.range(of: " (").map { String(label[..<$0.lowerBound]) } ?? label)
            .trimmingCharacters(in: .whitespaces)
        return email.contains("@") ? email : nil
    }

    /// 공통 지표의 표시 위치 — 공유 홈 카드 한 곳에 유지.
    static func isSharedHomeOnlyMetric(_ metricID: String, cardID: String) -> Bool {
        guard metricID.hasPrefix(cardID + ".") else { return false }
        return ProviderAccountID.isSharedMetric(metricID)
    }

    /// 계정 추가 시트 선택지 — 프로바이더 런타임을 카탈로그 기본 순서로 제공.
    var addableProviders: [ProviderRuntime] {
        providers.filter { !ProviderAccountID.isAccountCard($0.provider.id) }
    }

    /// Accounts 목록 — 켜진 프로바이더의 모든 등록 계정, 저장 로그인·표시 지표가 없어도 유지.
    func accountListAccounts() -> [DashboardAccount] {
        let providers = accountManagementProviders()
        let byID = Dictionary(uniqueKeysWithValues: providers.map { ($0.id, $0) })
        return orderedAccountCardIDs(providers.map(\.id)).compactMap { cardID in
            guard let provider = byID[cardID] else { return nil }
            return DashboardAccount(
                provider: provider,
                providerName: ProviderAccountID.cardTitle(providerID: cardID, fallback: provider.displayName),
                name: dashboardAccountName(for: cardID),
                isInUse: isAccountInUse(cardID),
                lines: []
            )
        }
    }

    func accountManagementProvider(id: String) -> Provider? {
        layout.provider(id: id) ?? accountManagementProviders().first { $0.id == id }
    }

    private func accountManagementProviders() -> [Provider] {
        let providers = layout.orderedProviderIDs()
            .filter { layout.isProviderEnabled($0) }
            .compactMap { layout.provider(id: $0) }
        let mapping = Dictionary(
            uniqueKeysWithValues: providers.compactMap { provider in
                accountProfileID(for: provider.id).map { (provider.id, $0) }
            })
        return AccountCardPresentationPlanner.managementProviders(
            providers, profiles: accountProfiles.profiles, profileIDsByCardID: mapping
        )
    }

    /// Reset Watch 조회 조건 — 대시보드에 표시 중이거나 알림이 켜져 있을 때만.
    static func needsResetWatch(layout: LayoutStore, notificationsEnabled: Bool) -> Bool {
        notificationsEnabled
            || layout.orderedRefreshDescriptors().contains {
                ProviderAccountID.canonicalMetricID($0.id) == "codex.resetWatch"
                    && !hidesMetric($0.id, onCard: $0.providerID)
            }
    }

    /// 카드에서 행을 숨기는지 — Claude·Codex 추가 계정 카드의 공유 홈 전용 지표만.
    static func hidesMetric(_ metricID: String, onCard cardID: String) -> Bool {
        ProviderAccountID.isAccountCard(cardID)
            && ProviderAccountID.families.contains(ProviderAccountID.family(of: cardID))
            && isSharedHomeOnlyMetric(metricID, cardID: cardID)
    }

    private func isAccountInUse(_ cardID: String) -> Bool {
        AccountCardPresentationPlanner.isInUse(
            cardID: cardID,
            profileID: accountProfileID(for: cardID),
            preferredProfileID: accountProfiles.preferredProfileID(family: ProviderAccountID.family(of: cardID))
        )
    }

    private func dashboardAccount(for group: ProviderGroup) -> DashboardAccount {
        let cardID = group.provider.id
        // 기존 공유 이미지의 펼침 분할과 별개로 계정의 저장된 행 순서 사용.
        let descriptors = layout.orderedSupportedMetrics(for: cardID)
            .filter { layout.isMetricEnabled($0.id) && !Self.hidesMetric($0.id, onCard: cardID) }
        let providerName = ProviderAccountID.cardTitle(providerID: cardID, fallback: group.provider.displayName)
        if dataStore.isWaitingForFirstReading(cardID) {
            return DashboardAccount(
                provider: group.provider,
                providerName: providerName,
                name: dashboardAccountName(for: cardID),
                email: dashboardAccountEmail(for: cardID),
                isInUse: isAccountInUse(cardID),
                lines: [],
                waitingMetricIDs: descriptors.map(\.id)
            )
        }
        let lines =
            descriptors
            .map { DashboardLine(descriptor: $0, data: dataStore.data(for: $0)) }
        return DashboardAccount(
            provider: group.provider,
            providerName: providerName,
            name: dashboardAccountName(for: cardID),
            email: dashboardAccountEmail(for: cardID),
            isInUse: isAccountInUse(cardID),
            lines: lines
        )
    }
}
