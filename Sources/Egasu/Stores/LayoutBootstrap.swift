import Foundation

/// owner 승인 기본값과 seed marker 없는 기존 사용자용 legacy baseline 묶음
struct LayoutDefaultSet {
    let metricIDs: [String]
    let migrationBaselineMetricIDs: [String]
    let pinnedMetricIDs: [String]
    let expandedMetricIDs: [String]
}

/// startup 종료 시점에 `LayoutStore`가 필요로 하는 전체 상태와 초기화 후 수행할 migration 쓰기 목록
struct LayoutInitialState {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let pinnedMetricIDs: Set<String>
    let expandedMetricIDs: Set<String>
    let expandedProviderIDs: Set<String>
    let defaultExpandedOnEnableIDs: Set<String>
    let menuBarStyle: MenuBarStyle
    let disabledMetricIDs: Set<String>
    let shouldPersistVisibility: Bool

    let shouldPersistPlaced: Bool
    let shouldPersistExpanded: Bool
    let shouldPersistExpandOnEnable: Bool
    let shouldPersistPins: Bool
    let shouldPersistMetricOrder: Bool
    let shouldPersistExpandedProviders: Bool
    let seededDefaultsToPersist: Set<String>?
}

/// 신규 설치·기존 사용자용 layout 로드
/// startup·default-upgrade 정책을 한곳에 모으고, 초기화 이후 라이브 액션은 `LayoutStore` 담당
@MainActor
enum LayoutBootstrap {
    static func load(
        registry: WidgetRegistry,
        persistence: LayoutPersistence,
        defaults: LayoutDefaultSet,
        knownCardIDs: Set<String> = []
    ) -> LayoutInitialState {
        let providerOrder = persistence.loadProviderOrder() ?? registry.providers.map(\.id)
        let savedOrder = persistence.loadMetricOrder() ?? [:]
        let legacyCards = persistence.loadSeededCards().map(Set.init)
        let copiesFamily = !persistence.hasStoredDisabledMetrics && legacyCards == nil
        let pinnedCards = (persistence.loadPriorityPins() ?? []).map(ProviderAccountID.providerID(ofMetric:))
        let cards = Set(registry.providers.map(\.id) + providerOrder + pinnedCards + Array(savedOrder.keys))
            .union(knownCardIDs).union(legacyCards ?? [])
        var order = copiesFamily
            ? LayoutOrdering.normalizedMetricOrder(savedOrder, registry: registry) : savedOrder
        if copiesFamily {
            order = LayoutOrdering.copyingOrderToCards(order, accountCards: cards.filter(ProviderAccountID.isAccountCard).sorted())
        }

        let currentIDs = Set(registry.descriptors.map(\.id).filter { !ProviderAccountID.isSharedMetricAlias($0) })
        var disabled: Set<String>
        var mayPersist = true
        var legacyPlaced: [PlacedWidget] = []
        if persistence.hasStoredDisabledMetrics {
            if let saved = persistence.loadDisabledMetrics() {
                disabled = Set(saved)
            } else {
                // 손상된 숨김 설정을 모두 켜짐으로 덮어쓰지 않고 원본 보존.
                disabled = currentIDs
                mayPersist = false
            }
        } else if persistence.hasStoredLayout {
            if let saved = persistence.loadPlaced() {
                legacyPlaced = copiesFamily
                    ? LayoutOrdering.copyingToCards(LayoutOrdering.foldingToCanonical(saved),
                                                    accountCards: cards.filter(ProviderAccountID.isAccountCard).sorted())
                    : saved
                let enabled = Set(legacyPlaced.map(\.descriptorID))
                // 등록된 적 없는 새 카드는 기본 켜짐. 부재 중인 기존 카드의 숨김도 함께 보존.
                let existingCards = legacyCards ?? cards
                var existingIDs = Set(order.filter { existingCards.contains($0.key) }.values.flatMap { $0 })
                for card in existingCards {
                    let family = ProviderAccountID.family(of: card)
                    for id in registry.canonicalMetricIDs(family: family) {
                        if ProviderAccountID.isSharedMetric(id) && card != family { continue }
                        existingIDs.insert(LayoutOrdering.cardMetricID(id, on: card))
                    }
                }
                disabled = existingIDs.subtracting(enabled)
            } else {
                disabled = currentIDs
                mayPersist = false
            }
        } else {
            let defaults = Set(defaults.metricIDs.map(ProviderAccountID.canonicalMetricID))
            disabled = Set(currentIDs.filter { !defaults.contains(ProviderAccountID.canonicalMetricID($0)) })
        }
        if !persistence.hasStoredDisabledMetrics {
            disabled = disabled.filter { !ProviderAccountID.isSharedMetricAlias($0) }
        }
        let legacyByID = Dictionary(legacyPlaced.map { ($0.descriptorID, $0) }, uniquingKeysWith: { first, _ in first })
        var placed = registry.descriptors.compactMap { descriptor -> PlacedWidget? in
            guard currentIDs.contains(descriptor.id), !disabled.contains(descriptor.id) else { return nil }
            return legacyByID[descriptor.id] ?? PlacedWidget(descriptorID: descriptor.id)
        }
        placed.append(contentsOf: legacyPlaced.filter { !currentIDs.contains($0.descriptorID) })
        let hasStoredLayout = persistence.hasStoredLayout || persistence.hasStoredDisabledMetrics
        let metricOrderByProvider = order
        let seededResult = seedNewDefaultMetrics(
            into: LayoutOrdering.foldingToCanonical(persistence.loadPlaced() ?? []),
            persistence: persistence, hasStoredLayout: hasStoredLayout,
            registry: registry, defaults: defaults
        )

        // 저장값(모두 unpin한 빈 배열 포함) 우선, 미지의 저장 id는 부재 중 계정 card용 tombstone으로 보존
        let pinnedMetricIDs: Set<String>
        var shouldPersistPins = false
        if let savedPins = persistence.loadPins() {
            // 카드별 pin은 canonical로 합친 뒤 provider 상한 재적용 — fold가 조용히 상한을 넘기지 않도록
            pinnedMetricIDs = LayoutOrdering.foldingPins(
                savedPins,
                order: metricOrderByProvider,
                limit: LayoutStore.maxPinsPerProvider
            )
            shouldPersistPins = pinnedMetricIDs != Set(savedPins)
        } else {
            pinnedMetricIDs = Set(defaults.pinnedMetricIDs.filter { registry.hasCanonicalMetric($0) })
        }

        // expanded 소속은 신규 설치 전용 default — 기능 도입 전 기존 layout은 전부 caret 위 유지
        var shouldPersistExpanded = false
        var expandedMetricIDs: Set<String>
        if let savedExpanded = persistence.loadExpandedMetrics() {
            expandedMetricIDs = LayoutOrdering.foldingExpansion(savedExpanded)
            shouldPersistExpanded = expandedMetricIDs != Set(savedExpanded)
        } else if hasStoredLayout {
            expandedMetricIDs = []
        } else {
            expandedMetricIDs = Set(defaults.expandedMetricIDs.filter { registry.hasCanonicalMetric($0) })
            shouldPersistExpanded = true
        }

        let savedExpandedProviders = persistence.loadExpandedProviders()
        let expandedProviderIDs = Set((savedExpandedProviders ?? []).map(ProviderAccountID.family))
        let shouldPersistExpandedProviders = savedExpandedProviders.map {
            expandedProviderIDs != Set($0)
        } ?? false

        // 새로 배포된 default metric만 caret 아래로 시작 가능 — 사용자가 이미 보던 metric은 숨기지 않는 규칙
        let newlyExpanded = Set(seededResult.newlyPlaced)
            .intersection(defaults.expandedMetricIDs)
            .filter { registry.hasCanonicalMetric($0) }
        if !newlyExpanded.isSubset(of: expandedMetricIDs) {
            expandedMetricIDs.formUnion(newlyExpanded)
            shouldPersistExpanded = true
        }

        // optional default-expanded metric은 최초 enable 시 caret 아래 진입 — 저장 queue 우선으로 사용자 이동 재생성 방지
        let placedIDs = Set(seededResult.placed.map(\.descriptorID))
        let expandedNow = expandedMetricIDs
        let isExpandOnEnableCandidate: (String) -> Bool = { [registry] id in
            registry.hasCanonicalMetric(id) && !expandedNow.contains(id) && !placedIDs.contains(id)
        }
        let savedOnEnable = persistence.loadExpandOnEnable()
        let defaultExpandedOnEnableIDs: Set<String>
        var shouldPersistExpandOnEnable = savedOnEnable == nil
        if let savedOnEnable {
            // 알려진 metric은 유효 후보여야 하나, 미지 id는 부재 중 계정 card 소속일 수 있어 descriptor 복귀까지 보존
            defaultExpandedOnEnableIDs = LayoutOrdering.foldingExpansion(savedOnEnable).filter { id in
                !registry.hasCanonicalMetric(id) || isExpandOnEnableCandidate(id)
            }
            shouldPersistExpandOnEnable = defaultExpandedOnEnableIDs != Set(savedOnEnable)
        } else {
            defaultExpandedOnEnableIDs = Set(defaults.expandedMetricIDs.filter(isExpandOnEnableCandidate))
        }

        return LayoutInitialState(
            placed: placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            pinnedMetricIDs: pinnedMetricIDs,
            expandedMetricIDs: expandedMetricIDs,
            expandedProviderIDs: expandedProviderIDs,
            defaultExpandedOnEnableIDs: defaultExpandedOnEnableIDs,
            menuBarStyle: persistence.loadMenuBarStyle(),
            disabledMetricIDs: disabled,
            shouldPersistVisibility: mayPersist,
            shouldPersistPlaced: false,
            shouldPersistExpanded: shouldPersistExpanded,
            shouldPersistExpandOnEnable: shouldPersistExpandOnEnable,
            shouldPersistPins: shouldPersistPins,
            shouldPersistMetricOrder: order != savedOrder,
            shouldPersistExpandedProviders: shouldPersistExpandedProviders,
            seededDefaultsToPersist: seededResult.shouldPersistSeededDefaults
                ? seededResult.seededDefaults
                : nil
        )
    }

    private struct SeededDefaultsResult {
        let placed: [PlacedWidget]
        let seededDefaults: Set<String>
        let shouldPersistPlaced: Bool
        let shouldPersistSeededDefaults: Bool
        let newlyPlaced: [String]
    }

    private static func seedNewDefaultMetrics(
        into placed: [PlacedWidget],
        persistence: LayoutPersistence,
        hasStoredLayout: Bool,
        registry: WidgetRegistry,
        defaults: LayoutDefaultSet
    ) -> SeededDefaultsResult {
        let knownDefaults = LayoutOrdering.knownMetricIDs(defaults.metricIDs, registry: registry)
        let knownDefaultSet = Set(knownDefaults)
        let hasStoredSeededDefaults = persistence.hasStoredSeededDefaults

        let seededDefaults: Set<String>
        var shouldPersistSeededDefaults = false
        if let saved = persistence.loadSeededDefaults() {
            // registry에 provider가 없는 metric의 marker도 유지 — prune하면 card 복귀 시 사용자가 끈 default metric이 신규로 오인되어 재활성화됨
            // 카드 scoped marker는 canonical로 접어 유지 — 접지 않으면 family metric이 신규로 오인됨
            seededDefaults = Set(saved.map(ProviderAccountID.canonicalMetricID))
            shouldPersistSeededDefaults = seededDefaults != Set(saved)
        } else if hasStoredLayout {
            seededDefaults = Set(LayoutOrdering.knownMetricIDs(defaults.migrationBaselineMetricIDs, registry: registry))
            shouldPersistSeededDefaults = true
        } else {
            seededDefaults = knownDefaultSet
            shouldPersistSeededDefaults = true
        }

        let placedIDs = Set(placed.map(\.descriptorID))
        let toAdd = knownDefaults.filter { !seededDefaults.contains($0) && !placedIDs.contains($0) }
        let nextSeededDefaults = seededDefaults.union(knownDefaultSet)
        shouldPersistSeededDefaults = shouldPersistSeededDefaults
            || !hasStoredSeededDefaults
            || nextSeededDefaults != seededDefaults

        return SeededDefaultsResult(
            placed: placed + toAdd.map { PlacedWidget(descriptorID: $0) },
            seededDefaults: nextSeededDefaults,
            shouldPersistPlaced: !toAdd.isEmpty,
            shouldPersistSeededDefaults: shouldPersistSeededDefaults,
            newlyPlaced: toAdd
        )
    }
}

/// startup과 라이브 layout 변경이 공유하는 순수 ordering·default helper
enum LayoutOrdering {
    /// 지표의 패밀리 — `claude@work.trend` → `claude`.
    static func family(ofMetric metricID: String) -> String {
        ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: metricID))
    }

    /// 프로바이더 지표를 계정 카드 지표로 변환 — 기본 카드는 유지, claude.trend + claude@work → claude@work.trend.
    static func cardMetricID(_ metricID: String, on cardID: String) -> String {
        let canonicalID = ProviderAccountID.canonicalMetricID(metricID)
        let family = family(ofMetric: canonicalID)
        guard ProviderAccountID.family(of: cardID) == family, cardID != family else { return canonicalID }
        return "\(cardID)\(canonicalID.dropFirst(family.count))"
    }

    /// 프로바이더 배치는 유지하고 개인 지표만 같은 프로바이더의 계정 카드마다 복사.
    static func copyingToCards(_ placed: [PlacedWidget], accountCards: [String]) -> [PlacedWidget] {
        placed + accountCards.flatMap { card in
            placed.filter {
                !ProviderAccountID.isSharedMetric($0.descriptorID)
                    && family(ofMetric: $0.descriptorID) == ProviderAccountID.family(of: card)
            }
                .map { PlacedWidget(descriptorID: cardMetricID($0.descriptorID, on: card)) }
        }
    }

    /// 개인 지표 순서만 같은 패밀리 계정 카드마다 복사.
    static func copyingOrderToCards(_ order: [String: [String]], accountCards: [String]) -> [String: [String]] {
        var result = order
        for card in accountCards {
            guard let familyOrder = order[ProviderAccountID.family(of: card)] else { continue }
            result[card] = familyOrder.filter { !ProviderAccountID.isSharedMetric($0) }
                .map { cardMetricID($0, on: card) }
        }
        return result
    }

    static func knownMetricIDs(_ ids: [String], registry: WidgetRegistry) -> [String] {
        var seen = Set<String>()
        return ids.filter { id in
            guard registry.hasCanonicalMetric(id), !seen.contains(id) else { return false }
            seen.insert(id)
            return true
        }
    }

    /// 저장된 카드 scoped 항목을 family 설정으로 축약 — 중복은 첫 항목이 위치와 identity를 유지
    static func foldingToCanonical(_ placed: [PlacedWidget]) -> [PlacedWidget] {
        var seen = Set<String>()
        return placed.compactMap { widget in
            guard !ProviderAccountID.isSharedMetricAlias(widget.descriptorID) else { return nil }
            let canonicalID = ProviderAccountID.canonicalMetricID(widget.descriptorID)
            guard seen.insert(canonicalID).inserted else { return nil }
            return PlacedWidget(id: widget.id, descriptorID: canonicalID)
        }
    }

    /// 카드별 caret 소속을 family 설정으로 축약 — family 자체 항목이 있으면 그것만, 없으면 카드 항목을 승격
    /// (카드 화면에서만 caret을 편집한 설치가 fold 때문에 그 선택을 잃지 않도록)
    static func foldingExpansion(_ saved: [String]) -> Set<String> {
        let familiesWithOwnEntry = Set(
            saved.filter { !ProviderAccountID.isAccountCard($0) }
                .map { ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: $0)) }
        )
        var result = Set<String>()
        for id in saved {
            let canonicalID = ProviderAccountID.canonicalMetricID(id)
            let family = ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: canonicalID))
            guard !ProviderAccountID.isAccountCard(id) || !familiesWithOwnEntry.contains(family) else { continue }
            result.insert(canonicalID)
        }
        return result
    }

    /// 카드별 pin을 family pin으로 합치고 provider 상한을 metric 순서대로 재적용
    /// 순위가 같거나 없으면 저장 순서로 결정 — 매 launch 같은 pin이 남도록
    static func foldingPins(
        _ pins: [String],
        order: [String: [String]],
        limit: Int
    ) -> Set<String> {
        var byFamily: [String: [(id: String, position: Int)]] = [:]
        var seen = Set<String>()
        for (position, pin) in pins.enumerated() {
            let canonicalID = ProviderAccountID.canonicalMetricID(pin)
            guard seen.insert(canonicalID).inserted else { continue }
            let family = ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: canonicalID))
            byFamily[family, default: []].append((canonicalID, position))
        }
        var result = Set<String>()
        for (family, familyPins) in byFamily {
            guard familyPins.count > limit else {
                result.formUnion(familyPins.map(\.id))
                continue
            }
            // 상한 초과분은 metric 순서 앞쪽을 남김 — 메뉴바 strip이 그리는 순서와 동일
            let ranking = order[family] ?? []
            let sorted = familyPins.sorted { lhs, rhs in
                let lhsRank = ranking.firstIndex(of: lhs.id) ?? Int.max
                let rhsRank = ranking.firstIndex(of: rhs.id) ?? Int.max
                return lhsRank == rhsRank ? lhs.position < rhs.position : lhsRank < rhsRank
            }
            result.formUnion(sorted.prefix(limit).map(\.id))
        }
        return result
    }

    static func defaultMetricOrder(registry: WidgetRegistry) -> [String: [String]] {
        var result: [String: [String]] = [:]
        for provider in registry.providers {
            let family = ProviderAccountID.family(of: provider.id)
            result[family] = registry.canonicalMetricIDs(family: family)
        }
        return result
    }

    static func normalizedMetricOrder(
        _ saved: [String: [String]],
        registry: WidgetRegistry
    ) -> [String: [String]] {
        // 저장된 key 전체에서 시작해 부재 중 계정 card의 ordering 유지, 현재 family는 dedupe 후
        // 신규 metric append — 렌더링 전 live registry 필터링은 `LayoutStore` 담당
        var fallback: [String: [String]] = [:]
        for (providerID, ids) in saved {
            let family = ProviderAccountID.family(of: providerID)
            // bare key가 곧 family 설정 — 카드 key는 family 항목이 없을 때만 승격
            if fallback[family] == nil || providerID == family {
                fallback[family] = ids.filter { !ProviderAccountID.isSharedMetricAlias($0) }
                    .map(ProviderAccountID.canonicalMetricID)
            }
        }
        for provider in registry.providers {
            let family = ProviderAccountID.family(of: provider.id)
            let valid = registry.canonicalMetricIDs(family: family)
            if let savedIDs = fallback[family] {
                var seen = Set<String>()
                var retained = savedIDs.filter { seen.insert($0).inserted }
                retained.append(contentsOf: valid.filter { seen.insert($0).inserted })
                fallback[family] = retained
            } else {
                fallback[family] = valid
            }
        }
        return fallback
    }

    /// 저장된 canonical 순서를 대상 id 공간(카드 scoped 또는 canonical)으로 투영
    static func normalizedMetricIDs(_ saved: [String], validIDs: [String]) -> [String] {
        var byCanonical: [String: String] = [:]
        for id in validIDs {
            byCanonical[ProviderAccountID.canonicalMetricID(id)] = id
        }
        var seen = Set<String>()
        var ordered: [String] = []
        for id in saved {
            guard let concrete = byCanonical[ProviderAccountID.canonicalMetricID(id)],
                  seen.insert(concrete).inserted else { continue }
            ordered.append(concrete)
        }
        ordered.append(contentsOf: validIDs.filter { !seen.contains($0) })
        return ordered
    }
}
