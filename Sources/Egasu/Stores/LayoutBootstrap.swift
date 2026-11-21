import Foundation

struct LayoutDefaultSet {
    let metricIDs: [String]
    let migrationBaselineMetricIDs: [String]
}

struct LayoutInitialState {
    let placed: [PlacedWidget]
    let providerOrder: [String]
    let metricOrderByProvider: [String: [String]]
    let disabledMetricIDs: Set<String>
    let shouldPersistVisibility: Bool
    let shouldPersistMetricOrder: Bool
    let shouldClearOnDemandState: Bool
}

/// 기본 켜짐에서 명시적 숨김만 제외. 이전 켜짐 목록은 보이는 상태를 바꾸지 않고 한 번 변환.
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
        let hasOnDemandState = persistence.hasOnDemandState
        // Priority 도입 버전은 단일 목록을 표시하므로 저장된 순서 유지.
        if hasOnDemandState && !persistence.hasStoredPriorityPins {
            let onDemand = LayoutOrdering.foldingExpansion(persistence.loadExpandedMetrics() ?? [])
                .union(LayoutOrdering.foldingExpansion(persistence.loadExpandOnEnable() ?? []))
            order = LayoutOrdering.flatteningOnDemand(order, onDemand: onDemand)
        }
        for (cardID, ids) in order {
            let family = ProviderAccountID.family(of: cardID)
            let valid = registry.canonicalMetricIDs(family: family)
            order[cardID] = LayoutOrdering.insertingNewAnchoredMetrics(into: ids, validIDs: valid, cardID: cardID)
        }
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
                // 이전 켜짐 목록에 존재할 수 없었던 지표는 새 지표의 표시 기본값 적용.
                let seededDefaults = persistence.loadSeededDefaults()
                let known = Set(
                    (savedOrder.values.flatMap { $0 } + (seededDefaults ?? []))
                        .map(ProviderAccountID.canonicalMetricID))
                let newMetrics = Set(defaults.metricIDs).intersection(LayoutOrdering.anchoredMetrics.map(\.id)).subtracting(
                    known)
                disabled = disabled.filter { !newMetrics.contains(ProviderAccountID.canonicalMetricID($0)) }
                if let seeded = seededDefaults {
                    let unseenDefaults = Set(defaults.metricIDs)
                        .intersection(DefaultLayout.legacyV1DefaultMetricIDs)
                        .subtracting(seeded.map(ProviderAccountID.canonicalMetricID))
                    disabled = disabled.filter {
                        !unseenDefaults.contains(ProviderAccountID.canonicalMetricID($0))
                    }
                }
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
        return LayoutInitialState(
            placed: placed, providerOrder: providerOrder, metricOrderByProvider: order,
            disabledMetricIDs: disabled, shouldPersistVisibility: mayPersist,
            shouldPersistMetricOrder: order != savedOrder,
            shouldClearOnDemandState: hasOnDemandState
        )
    }
}

/// startup과 라이브 layout 변경이 공유하는 순수 ordering·default helper
enum LayoutOrdering {
    // 선행 행부터 삽입해 기존 버전을 건너뛰어도 주간 → 월간 → 개인 크레딧 순서 유지.
    static let anchoredMetrics = [
        (id: "codex.monthly", after: "codex.weekly"), (id: "codex.individualCredits", after: "codex.monthly"),
        (id: "codex.sparkMonthly", after: "codex.sparkWeekly"), (id: "grok.monthly", after: "grok.weekly"),
        (id: "zai.monthly", after: "zai.weekly")
    ]

    /// 저장 순서와 공통 행을 복원한 뒤 선행 행 바로 아래에 새 지표 삽입.
    static func deferringAnchoredMetrics(_ canonicalIDs: [String]) -> [String] {
        canonicalIDs.filter { id in
            !anchoredMetrics.contains { $0.id == id && canonicalIDs.contains($0.after) }
        }
    }

    /// 이미 저장된 지표는 사용자가 정한 위치 유지.
    static func insertingNewAnchoredMetrics(into saved: [String], validIDs: [String], cardID: String) -> [String] {
        var result = saved
        let known = Set(saved.map(ProviderAccountID.canonicalMetricID))
        for (id, after) in anchoredMetrics where !known.contains(id) && validIDs.contains(id) {
            guard let index = result.firstIndex(where: { ProviderAccountID.canonicalMetricID($0) == after }) else {
                continue
            }
            result.insert(cardMetricID(id, on: cardID), at: result.index(after: index))
        }
        return result
    }

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

    /// 옛 On Demand 소속을 뒤로 모으되 각 구역의 상대 순서 유지.
    static func flatteningOnDemand(_ order: [String: [String]], onDemand: Set<String>) -> [String: [String]] {
        order.mapValues { ids in
            ids.filter { !onDemand.contains(ProviderAccountID.canonicalMetricID($0)) }
                + ids.filter { onDemand.contains(ProviderAccountID.canonicalMetricID($0)) }
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
            // 새 월간 행은 옛 On Demand 순서를 평탄화한 다음 대응 주간 뒤에 삽입.
            let valid = deferringAnchoredMetrics(registry.canonicalMetricIDs(family: family))
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
