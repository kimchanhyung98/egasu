import DesktopWidgetSupport
import Foundation

extension AppContainer {
    /// 사용자가 고른 계정 키를 현재 카탈로그의 카드로만 해석.
    func desktopWidgetCardID(for accountID: String) -> String? {
        desktopWidgetSources().first { $0.id == accountID }?.cardID
    }

    func desktopWidgetContent(now: Date = Date()) -> DesktopWidgetContent {
        Self.desktopWidgetContent(
            sources: desktopWidgetSources(), dashboard: dashboardAccounts(), dataStore: dataStore,
            pinned: layout.priorityPinIDs, hidingNames: privacy.hideUsageWhileScreenSharing, now: now)
    }

    static func desktopWidgetContent(
        sources: [DesktopWidgetSource], dashboard: [DashboardAccount], dataStore: WidgetDataStore,
        pinned: Set<String>, hidingNames: Bool, now: Date
    ) -> DesktopWidgetContent {
        let cards = Dictionary(uniqueKeysWithValues: dashboard.map { ($0.id, $0) })
        var unreadable = Set<String>()
        var accounts: [DesktopWidgetAccount] = []
        for source in sources {
            let cardID = source.cardID
            let binding = dataStore.claimRefreshBinding(providerID: cardID)
            let permits = DesktopWidgetProjection.permitsReading(
                profile: source.profile, binding: binding, local: dataStore.localSnapshots[cardID]
            )
            if !permits { unreadable.insert(cardID) }
            let snapshot = permits ? dataStore.snapshots[cardID] : nil
            let observed = snapshot?.freshnessDate
            let staleAt = observed?.addingTimeInterval(RefreshSetting.interval(for: cardID) * 2)
            let state = DesktopWidgetProjection.state(
                available: binding != nil, refreshFailed: dataStore.usageRefreshFailed(for: cardID),
                staleAt: staleAt, now: now
            )
            let lines = Dictionary(uniqueKeysWithValues: (cards[cardID]?.lines ?? []).map { ($0.id, $0) })
            let metrics = source.descriptors.map { descriptor in
                DesktopWidgetProjection.metric(
                    descriptor, line: permits ? lines[descriptor.id] : nil, now: now
                )
            }
            accounts.append(
                DesktopWidgetAccount(
                    id: source.id, providerID: source.family, providerName: source.providerName,
                    name: source.displayName(in: sources, hidingNames: hidingNames),
                    state: state, observedAt: observed, staleAt: staleAt, metrics: metrics
                ))
        }
        // 조회 결과의 소유자가 바뀌면 기존 수치·고정 행을 먼저 제거하고 새 계정의 조회를 기다림.
        let safeCards = dashboard.map { card in
            guard unreadable.contains(card.id) else { return card }
            return DashboardAccount(
                provider: card.provider, providerName: card.providerName, name: nil, lines: []
            )
        }
        let board = dataStore.priorityBoard(
            accounts: safeCards, pinned: pinned, now: now, hidingEmails: true,
            awaitingIdentity: unreadable
        )
        return DesktopWidgetContent(
            accounts: accounts,
            priority: DesktopWidgetProjection.priority(
                board, enabled: dataStore.displaySettings.hasVisiblePriorityConditions, sources: sources, now: now
            ), language: L10n.language.rawValue
        )
    }

    private func desktopWidgetSources() -> [DesktopWidgetSource] {
        accountListAccounts().flatMap { card -> [DesktopWidgetSource] in
            let profileID = accountProfileID(for: card.id)
            let profile = profileID.flatMap { accountProfiles.profile(id: $0) }
            guard profileID == nil || profile != nil else { return [] }
            return DesktopWidgetSource.make(
                card: card, profile: profile,
                descriptors: Self.dashboardMetricDescriptors(for: card.id, in: layout),
                hasSharedMetrics: layout.orderedSupportedMetrics(for: card.id).contains {
                    ProviderAccountID.isSharedMetric($0.id)
                }
            )
        }
    }
}

/// 확장이 영속하는 계정 키와 현재 조회 카드 사이의 대응. 공통 이력은 선택 계정에서 분리.
struct DesktopWidgetSource {
    let id: String
    let cardID: String
    let family: String
    let providerName: String
    let profile: AccountProfile?
    let shared: Bool
    let descriptors: [WidgetDescriptor]

    static func make(
        card: DashboardAccount, profile: AccountProfile?, descriptors: [WidgetDescriptor], hasSharedMetrics: Bool
    ) -> [Self] {
        let family = ProviderAccountID.family(of: card.id)
        guard profile.map({ !$0.isArchived && $0.family == family }) ?? (card.id == family) else { return [] }
        let splitShared = ProviderAccountID.families.contains(family)
        let personalID =
            profile.map { DesktopWidgetAccountID.profile(providerID: family, profileID: $0.id) }
            ?? DesktopWidgetAccountID.current(providerID: family)
        var sources = [
            Self(
                id: personalID, cardID: card.id, family: family, providerName: card.providerName, profile: profile,
                shared: false,
                descriptors: descriptors.filter { !splitShared || !ProviderAccountID.isSharedMetric($0.id) }
            )
        ]
        if splitShared, card.id == family, hasSharedMetrics {
            sources.append(
                Self(
                    id: DesktopWidgetAccountID.shared(providerID: family), cardID: card.id, family: family,
                    providerName: card.providerName, profile: profile, shared: true,
                    descriptors: descriptors.filter { ProviderAccountID.isSharedMetric($0.id) }
                ))
        }
        return sources
    }

    func displayName(in sources: [Self], hidingNames: Bool) -> String {
        if shared { return L10n.accounts("Shared Usage") }
        guard let profile else { return L10n.accounts("Current Login") }
        let profiles = sources.filter { $0.family == family && !$0.shared }.compactMap(\.profile)
        let safeLabel = !hidingNames && !profile.label.contains("@") ? profile.label : nil
        let matching = profiles.filter {
            if let safeLabel { return $0.label == safeLabel }
            return hidingNames || $0.label.contains("@")
        }.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
        if let safeLabel, matching.count <= 1 { return safeLabel }
        let ordinal = (matching.firstIndex { $0.id == profile.id } ?? 0) + 1
        return safeLabel.map { L10n.accounts("%@ · Account %lld", $0, ordinal) }
            ?? L10n.accounts("Account %lld", ordinal)
    }
}
