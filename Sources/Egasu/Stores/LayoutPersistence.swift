import Foundation

/// `LayoutStore`의 저장 담당 절반 — key 이름·encoding·UserDefaults 접근 소유
@MainActor
final class LayoutPersistence {
    private let defaults: UserDefaults
    private let keys: Keys
    private let importsUpstreamLayout: Bool
    private var unresolvedProfileCards: Set<String> = []
    private var pendingProfileIDsByCard: [String: String]?
    private(set) var hasUnresolvedProfileMapping = false

    init(defaults: UserDefaults, storageKey: String) {
        self.defaults = defaults
        self.keys = Keys(storageKey: storageKey)
        self.importsUpstreamLayout = storageKey == "openusage.layout.v1"
    }

    /// 존재 여부는 decode 성공과 별개 — 손상된 데이터도 기존 layout이므로
    /// startup이 corruption을 신규 설치로 오인해 신규 전용 default를 적용하지 않도록 하는 규칙
    var hasStoredLayout: Bool { defaults.object(forKey: keys.placed) != nil }
    var hasStoredSeededDefaults: Bool { defaults.object(forKey: keys.seededDefaults) != nil }
    var hasStoredMetricOrder: Bool { defaults.object(forKey: keys.metricOrder) != nil }
    var isUpstreamImportPending: Bool {
        importsUpstreamLayout && defaults.bool(forKey: SettingsMigrator.upstreamLayoutImportPendingKey)
    }

    func finishPendingUpstreamImport() {
        guard importsUpstreamLayout else { return }
        if let pendingProfileIDsByCard { encode(pendingProfileIDsByCard, forKey: keys.accountProfilesByCard) }
        defaults.removeObject(forKey: SettingsMigrator.upstreamLayoutImportPendingKey)
        pendingProfileIDsByCard = nil
    }

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
        let retained = (defaults.stringArray(forKey: keys.disabledMetrics) ?? []).filter(isUnresolvedMetric)
        let changed = hasStoredDisabledMetrics ? ids.filter { !isUnresolvedMetric($0) } : ids
        defaults.set(changed.union(retained).sorted(), forKey: keys.disabledMetrics)
    }

    var deferredVisibility: [String: Bool] {
        get { defaults.dictionary(forKey: keys.deferredVisibility) as? [String: Bool] ?? [:] }
        set {
            if newValue.isEmpty {
                if defaults.object(forKey: keys.deferredVisibility) != nil {
                    defaults.removeObject(forKey: keys.deferredVisibility)
                }
            } else {
                defaults.set(newValue, forKey: keys.deferredVisibility)
            }
        }
    }

    /// 구형 가시성 이전을 끝내기 전에는 명시적으로 편집한 항목만 보관.
    func recordDeferredVisibility(_ choices: [String: Bool]) {
        guard !hasStoredDisabledMetrics, !isUpstreamImportPending else { return }
        let resolved = choices.filter { !isUnresolvedMetric($0.key) }
        guard !resolved.isEmpty else { return }
        deferredVisibility.merge(resolved) { _, edited in edited }
    }

    func finishVisibilityMigration(_ ids: Set<String>) {
        saveDisabledMetrics(ids)
        deferredVisibility = [:]
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
    func loadDeferredMenuBarStars() -> [String]? { defaults.stringArray(forKey: keys.deferredMenuBarStars) }

    func saveDeferredMenuBarStars(_ ids: Set<String>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: keys.deferredMenuBarStars)
        } else {
            defaults.set(ids.sorted(), forKey: keys.deferredMenuBarStars)
        }
        saveDeclinedMenuBarStars(
            loadDeclinedMenuBarStars().filter { ids.contains(ProviderAccountID.canonicalMetricID($0)) })
    }

    func loadDeclinedMenuBarStars() -> Set<String> {
        Set(defaults.stringArray(forKey: keys.declinedMenuBarStars) ?? [])
    }

    func saveDeclinedMenuBarStars(_ ids: Set<String>) {
        if ids.isEmpty {
            defaults.removeObject(forKey: keys.declinedMenuBarStars)
        } else {
            defaults.set(ids.sorted(), forKey: keys.declinedMenuBarStars)
        }
    }

    func recordExplicitPinChoice(_ id: String, pinned: Bool) {
        guard !isUnresolvedMetric(id),
            loadDeferredMenuBarStars()?.contains(ProviderAccountID.canonicalMetricID(id)) == true
        else { return }
        var declined = loadDeclinedMenuBarStars()
        if pinned { declined.remove(id) } else { declined.insert(id) }
        saveDeclinedMenuBarStars(declined)
    }

    func clearDeferredMenuBarStars(family: String? = nil) {
        saveDeferredMenuBarStars(
            Set(
                (loadDeferredMenuBarStars() ?? []).filter {
                    family != nil && LayoutOrdering.family(ofMetric: $0) != family
                }))
    }

    var hasOnDemandState: Bool {
        [keys.expandedMetrics, keys.expandOnEnable, keys.expandedProviders].contains {
            defaults.object(forKey: $0) != nil
        }
    }

    func savePlaced(_ value: [PlacedWidget]) { encode(value, forKey: keys.placed) }
    func saveProviderOrder(_ value: [String]) { encode(value, forKey: keys.providerOrder) }
    func saveMetricOrder(_ value: [String: [String]]) {
        var next = value
        if !unresolvedProfileCards.isEmpty {
            let original = loadMetricOrder() ?? [:]
            for card in unresolvedProfileCards {
                guard let requested = next[card] else { next[card] = original[card]; continue }
                var shared = requested.filter(ProviderAccountID.isSharedMetric).makeIterator()
                next[card] =
                    (original[card] ?? []).compactMap {
                        ProviderAccountID.isSharedMetric($0) ? shared.next() : $0
                    } + Array(shared)
            }
        }
        encode(next, forKey: keys.metricOrder)
    }
    func saveSeededDefaults(_ value: Set<String>) {
        encode(Array(value).sorted(), forKey: keys.seededDefaults)
    }

    func savePriorityPins(_ value: Set<String>) {
        let retained = (loadPriorityPins() ?? []).filter(isUnresolvedMetric)
        defaults.set(value.filter { !isUnresolvedMetric($0) }.union(retained).sorted(), forKey: keys.priorityPins)
    }

    /// 매핑을 복구하기 전에는 소유자가 불명인 개인 설정을 다른 프로필에 적용하지 않음.
    func isUnresolvedMetric(_ id: String) -> Bool {
        !ProviderAccountID.isSharedMetric(id)
            && unresolvedProfileCards.contains(ProviderAccountID.providerID(ofMetric: id))
    }

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
        if isUpstreamImportPending {
            let changed = pendingProfileIDsByCard != profileIDsByCard
            pendingProfileIDsByCard = profileIDsByCard
            return changed
        }
        let previous = decode([String: String].self, forKey: keys.accountProfilesByCard)
        if previous == nil, defaults.object(forKey: keys.accountProfilesByCard) != nil {
            hasUnresolvedProfileMapping = true
            unresolvedProfileCards = Set(profileIDsByCard.keys)
            return false
        }
        let resolvedMapping = hasUnresolvedProfileMapping
        hasUnresolvedProfileMapping = false
        unresolvedProfileCards = []
        let knownCards = Set(profileIDsByCard.keys).union(previous?.keys.map { $0 } ?? []).union(loadSeededCards() ?? [])
        let sharedMetricsChanged = removeSharedMetricAliases(knownCards: knownCards)
        guard previous != profileIDsByCard else { return sharedMetricsChanged || resolvedMapping }
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
        let choices = deferredVisibility
        if !choices.isEmpty {
            var remapped: [String: Bool] = [:]
            for (id, enabled) in choices {
                if let target = metricID(id) { remapped[target] = enabled }
            }
            deferredVisibility = remapped
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
                    savedIDs, validIDs: LayoutOrdering.deferringAnchoredMetrics(defaultIDs) + savedIDs
                ).makeIterator()
                nextOrder[cardID] = ids.compactMap { id in
                    ProviderAccountID.isSharedMetric(id) ? id : personalIDs.next()
                } + Array(personalIDs)
            }
            saveMetricOrder(nextOrder)
        }
        if let pins = loadPriorityPins() { savePriorityPins(Set(pins.compactMap(metricID))) }
        let declined = loadDeclinedMenuBarStars()
        if !declined.isEmpty { saveDeclinedMenuBarStars(Set(declined.compactMap(metricID))) }
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
        let deferredVisibility: String
        let disabledMetrics: String
        let providerOrder: String
        let metricOrder: String
        let seededDefaults: String
        let seededCards: String
        let accountProfilesByCard: String
        let pins: String
        let priorityPins: String
        let deferredMenuBarStars: String
        let declinedMenuBarStars: String
        let expandedMetrics: String
        let expandOnEnable: String
        let expandedProviders: String

        init(storageKey: String) {
            placed = storageKey
            deferredVisibility = "\(storageKey).deferredVisibility"
            disabledMetrics = "\(storageKey).disabledMetrics"
            providerOrder = "\(storageKey).providerOrder"
            metricOrder = "\(storageKey).metricOrderByProvider"
            seededDefaults = "\(storageKey).seededDefaults"
            seededCards = "\(storageKey).seededCards"
            accountProfilesByCard = "\(storageKey).accountProfilesByCard"
            pins = "\(storageKey).menuBarPins"
            priorityPins = "\(storageKey).priorityPins"
            deferredMenuBarStars = "\(storageKey).deferredMenuBarStars"
            declinedMenuBarStars = "\(storageKey).declinedMenuBarStars"
            expandedMetrics = "\(storageKey).expandedMetrics"
            expandOnEnable = "\(storageKey).expandOnEnable"
            expandedProviders = "\(storageKey).expandedProviders"
        }
    }
}
