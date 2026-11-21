import Foundation

/// `LayoutStore`의 저장 담당 절반 — key 이름·encoding·UserDefaults 접근 소유
@MainActor
final class LayoutPersistence {
    private let defaults: UserDefaults
    private let keys: Keys

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.keys = Keys(storageKey: storageKey)
    }

    /// 존재 여부는 decode 성공과 별개 — 손상된 데이터도 기존 layout이므로
    /// startup이 corruption을 신규 설치로 오인해 신규 전용 default를 적용하지 않도록 하는 규칙
    var hasStoredLayout: Bool { defaults.object(forKey: keys.placed) != nil }
    var hasStoredSeededDefaults: Bool { defaults.data(forKey: keys.seededDefaults) != nil }

    var hasStoredDisabledMetrics: Bool { defaults.object(forKey: keys.disabledMetrics) != nil }

    func loadDisabledMetrics() -> [String]? {
        guard hasStoredDisabledMetrics else { return nil }
        guard let ids = defaults.stringArray(forKey: keys.disabledMetrics) else {
            AppLog.error(.config, "Saved metric visibility is invalid. Existing settings were preserved.")
            return nil
        }
        return ids
    }

    func saveDisabledMetrics(_ ids: Set<String>) {
        defaults.set(ids.sorted(), forKey: keys.disabledMetrics)
    }

    func loadPlaced() -> [PlacedWidget]? { decode([PlacedWidget].self, forKey: keys.placed) }
    func loadProviderOrder() -> [String]? { decode([String].self, forKey: keys.providerOrder) }
    func loadMetricOrder() -> [String: [String]]? {
        decode([String: [String]].self, forKey: keys.metricOrder)
    }
    func loadSeededDefaults() -> [String]? { decode([String].self, forKey: keys.seededDefaults) }

    /// 첫 레이아웃을 받은 카드 — 키가 없으면 패밀리 공용 레이아웃 시절의 저장값.
    func loadSeededCards() -> [String]? { defaults.stringArray(forKey: keys.seededCards) }
    func saveSeededCards(_ value: Set<String>) { defaults.set(Array(value).sorted(), forKey: keys.seededCards) }

    var hasStoredPriorityPins: Bool { defaults.object(forKey: keys.priorityPins) != nil }
    func loadPriorityPins() -> [String]? { defaults.stringArray(forKey: keys.priorityPins) }
    func loadPins() -> [String]? { defaults.stringArray(forKey: keys.pins) }
    func loadExpandedMetrics() -> [String]? { defaults.stringArray(forKey: keys.expandedMetrics) }
    func loadExpandOnEnable() -> [String]? { defaults.stringArray(forKey: keys.expandOnEnable) }

    var hasOnDemandState: Bool {
        [keys.expandedMetrics, keys.expandOnEnable, keys.expandedProviders].contains {
            defaults.object(forKey: $0) != nil
        }
    }

    func savePlaced(_ value: [PlacedWidget]) { encode(value, forKey: keys.placed) }
    func saveProviderOrder(_ value: [String]) { encode(value, forKey: keys.providerOrder) }
    func saveMetricOrder(_ value: [String: [String]]) { encode(value, forKey: keys.metricOrder) }
    func saveSeededDefaults(_ value: Set<String>) {
        encode(Array(value).sorted(), forKey: keys.seededDefaults)
    }

    func savePriorityPins(_ value: Set<String>) { defaults.set(Array(value).sorted(), forKey: keys.priorityPins) }

    /// 레거시 On Demand 키 제거. 호출 전에 변환한 지표 순서 저장.
    func clearOnDemandState() {
        for key in [keys.expandedMetrics, keys.expandOnEnable, keys.expandedProviders] {
            defaults.removeObject(forKey: key)
        }
    }

    /// 공유 홈 카드가 다른 등록 계정을 가리키면 개인 설정만 같은 프로필의 새 카드로 이동.
    /// 공통 설정은 기본 프로바이더 ID에 유지하고, 부재 중 프로필은 스냅샷 카드 ID로 보관.
    @discardableResult
    func reconcileAccountProfiles(_ profileIDsByCard: [String: String], registry: WidgetRegistry) -> Bool {
        let previous = decode([String: String].self, forKey: keys.accountProfilesByCard)
        let knownCards = Set(profileIDsByCard.keys).union(previous?.keys.map { $0 } ?? []).union(loadSeededCards() ?? [])
        let sharedMetricsChanged = removeSharedMetricAliases(knownCards: knownCards)
        guard previous != profileIDsByCard else { return sharedMetricsChanged }
        defer { encode(profileIDsByCard, forKey: keys.accountProfilesByCard) }
        guard let previous else { return sharedMetricsChanged }

        func cardsByProfile(_ mapping: [String: String]) -> [String: String] {
            var result: [String: String] = [:]
            for (cardID, profileID) in mapping {
                let family = ProviderAccountID.family(of: cardID)
                let stableID = AccountUsageCardPlanner.cardID(family: family, profileID: profileID)
                // 공유 홈과 스냅샷이 같은 계정이면 화면에 쓰는 공유 홈 카드가 기준.
                if result[stableID] == nil || cardID == family { result[stableID] = cardID }
            }
            return result
        }
        let oldCards = cardsByProfile(previous)
        let newCards = cardsByProfile(profileIDsByCard)
        var moves: [String: String] = [:]
        for stableID in Set(oldCards.keys).union(newCards.keys) {
            let source = oldCards[stableID] ?? stableID
            let target = newCards[stableID] ?? stableID
            if source != target { moves[source] = target }
        }
        guard !moves.isEmpty else { return true }
        let replacedCards = Set(moves.values).subtracting(moves.keys)
        func metricID(_ id: String) -> String? {
            if ProviderAccountID.isSharedMetric(id) { return id }
            let cardID = ProviderAccountID.providerID(ofMetric: id)
            guard !replacedCards.contains(cardID) else { return nil }
            guard let target = moves[cardID] else { return id }
            return LayoutOrdering.cardMetricID(id, on: target)
        }
        if let disabled = loadDisabledMetrics() {
            saveDisabledMetrics(Set(disabled.compactMap(metricID)))
        }
        if !hasStoredDisabledMetrics, let placed = loadPlaced() {
            savePlaced(placed.compactMap { widget in
                metricID(widget.descriptorID).map { PlacedWidget(id: widget.id, descriptorID: $0) }
            })
        }
        if let order = loadMetricOrder() {
            var nextOrder: [String: [String]] = Dictionary(uniqueKeysWithValues: order.compactMap { cardID, ids in
                guard !replacedCards.contains(cardID) else { return nil }
                let personalIDs = knownCards.contains(cardID)
                    ? ids.filter { !ProviderAccountID.isSharedMetric($0) } : ids
                return (moves[cardID] ?? cardID, personalIDs.compactMap(metricID))
            })
            for (cardID, ids) in order where !ProviderAccountID.isAccountCard(cardID) && knownCards.contains(cardID) {
                guard ids.contains(where: ProviderAccountID.isSharedMetric) else { continue }
                // 기본 카드의 공통 지표 위치에 새 계정의 개인 순서를 끼워 넣어 양쪽 상대순서 유지.
                let defaultIDs = registry.descriptors(for: cardID)
                    .filter { !ProviderAccountID.isSharedMetric($0.id) }.map(\.id)
                let savedIDs = nextOrder[cardID] ?? []
                var personalIDs = LayoutOrdering.normalizedMetricIDs(
                    savedIDs, validIDs: LayoutOrdering.deferringMonthlyMetrics(defaultIDs) + savedIDs
                ).makeIterator()
                nextOrder[cardID] = ids.compactMap { id in
                    ProviderAccountID.isSharedMetric(id) ? id : personalIDs.next()
                } + Array(personalIDs)
            }
            saveMetricOrder(nextOrder)
        }
        if let pins = loadPriorityPins() { savePriorityPins(Set(pins.compactMap(metricID))) }
        if let seededCards = loadSeededCards() {
            saveSeededCards(Set(seededCards.compactMap { cardID in
                replacedCards.contains(cardID) ? nil : moves[cardID] ?? cardID
            }))
        }
        return true
    }

    /// 추가 계정의 공통 저장값 제거 — 기본 카드의 꺼짐·고정 해제를 다른 계정 값으로 덮어쓰지 않음.
    private func removeSharedMetricAliases(knownCards: Set<String>) -> Bool {
        func isAlias(_ id: String) -> Bool {
            ProviderAccountID.isSharedMetricAlias(id)
                && (!hasStoredDisabledMetrics || knownCards.contains(ProviderAccountID.providerID(ofMetric: id)))
        }
        var changed = false
        if let disabled = loadDisabledMetrics() {
            let normalized = disabled.filter { !isAlias($0) }
            if normalized != disabled {
                saveDisabledMetrics(Set(normalized))
                changed = true
            }
        }
        if !hasStoredDisabledMetrics, let placed = loadPlaced() {
            let normalized = placed.filter { !ProviderAccountID.isSharedMetricAlias($0.descriptorID) }
            if normalized != placed {
                savePlaced(normalized)
                changed = true
            }
        }
        if let order = loadMetricOrder() {
            let normalized = order.mapValues { $0.filter { !isAlias($0) } }
            if normalized != order {
                saveMetricOrder(normalized)
                changed = true
            }
        }
        if let pins = loadPriorityPins() {
            let normalized = pins.filter { !isAlias($0) }
            if normalized != pins {
                savePriorityPins(Set(normalized))
                changed = true
            }
        }
        return changed
    }

    /// encode 실패는 loud하게 기록 — 조용히 삼키면 layout 변경 유실이 무신호로 발생
    private func encode<T: Encodable>(_ value: T, forKey key: String) {
        do {
            defaults.set(try JSONEncoder().encode(value), forKey: key)
        } catch {
            AppLog.warn(.config, "failed to persist layout '\(key)': \(error.localizedDescription)")
        }
    }

    /// 데이터 없음은 정상 첫 launch, 있는데 못 읽으면 로그 후 fallback — 손상된 저장 layout의 무음 은폐 방지
    private func decode<T: Decodable>(_ type: T.Type, forKey key: String) -> T? {
        guard defaults.object(forKey: key) != nil else { return nil }
        guard let data = defaults.data(forKey: key) else {
            AppLog.error(.config, "Saved layout '\(key)' has an invalid storage type.")
            return nil
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            AppLog.warn(.config, "saved layout '\(key)' failed to decode; reseeding default: \(error.localizedDescription)")
            return nil
        }
    }

    private struct Keys {
        let placed: String
        let disabledMetrics: String
        let providerOrder: String
        let metricOrder: String
        let seededDefaults: String
        let seededCards: String
        let accountProfilesByCard: String
        let pins: String
        let priorityPins: String
        let expandedMetrics: String
        let expandOnEnable: String
        let expandedProviders: String

        init(storageKey: String) {
            placed = storageKey
            disabledMetrics = "\(storageKey).disabledMetrics"
            providerOrder = "\(storageKey).providerOrder"
            metricOrder = "\(storageKey).metricOrderByProvider"
            seededDefaults = "\(storageKey).seededDefaults"
            seededCards = "\(storageKey).seededCards"
            accountProfilesByCard = "\(storageKey).accountProfilesByCard"
            pins = "\(storageKey).menuBarPins"
            priorityPins = "\(storageKey).priorityPins"
            expandedMetrics = "\(storageKey).expandedMetrics"
            expandOnEnable = "\(storageKey).expandOnEnable"
            expandedProviders = "\(storageKey).expandedProviders"
        }
    }
}
