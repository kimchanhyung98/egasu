extension LayoutStore {
    func provider(id: String) -> Provider? { registry.provider(id: id) }

    func descriptor(for widget: PlacedWidget) -> WidgetDescriptor? {
        registry.descriptor(id: widget.descriptorID)
    }

    /// 배치된 지표의 프로바이더 ID — 등록 목록에 없는 지표는 nil.
    private func providerID(of widget: PlacedWidget) -> String? {
        registry.descriptor(id: widget.descriptorID)?.providerID
    }

    var visiblePlaced: [PlacedWidget] {
        placed.filter { widget in
            guard let providerID = providerID(of: widget) else { return true }
            return isProviderEnabled(providerID)
        }
    }

    func isMetricEnabled(_ descriptorID: String) -> Bool {
        let settingsID = ProviderAccountID.isSharedMetric(descriptorID) ? Self.canonical(descriptorID) : descriptorID
        return registry.descriptor(id: descriptorID) != nil
            && placed.contains { $0.descriptorID == settingsID }
    }


    /// Total Spend 카드의 capability gate — 일별 이력·지출 타일·전용 기간 합계를 지원하는 활성 provider 존재 여부.
    /// registry descriptor 기준(refresh 데이터 무관)이라 데이터 없는 아침에도 "No spend data" 상태로 표시.
    var hasSpendCapableProvider: Bool {
        !spendCapableProviders.isEmpty
    }

    /// 일별 이력·지출 타일·전용 기간 합계를 지원하는 활성 provider(사용자 provider 순서) —
    /// Total Spend가 집계하는 정확한 집합. `displayGroups`가 아닌 이유: metric을 전부 숨긴 provider도
    /// 지출은 계속되므로 포함, capability 없는 provider의 유사 dollar 행은 제외.
    var spendCapableProviders: [Provider] {
        let capableIDs = Set(registry.descriptors.filter(\.isSpendTile).map(\.providerID))
            .union(registry.historyDescriptorsByProvider.keys)
        return orderedProviders().filter {
            (capableIDs.contains($0.id) || $0.usesDedicatedSpendLines) && isProviderEnabled($0.id)
        }
    }

    // MARK: - Provider grouping

    /// 저장된 순서의 known provider + 아직 못 본 provider는 registry 순서로 append — 신규 provider도 표시.
    func orderedProviderIDs() -> [String] {
        registry.orderedProviderIDs(savedOrder: providerOrder)
    }

    private func orderedProviders() -> [Provider] {
        orderedProviderIDs().compactMap { registry.provider(id: $0) }
    }

    /// provider별로 묶인 enabled widget(사용자 provider 순서·custom metric 순서) — grouped dashboard
    /// 목록 구동, visible metric 없는 provider는 제외.
    var displayGroups: [ProviderGroup] {
        let widgetsByID = Dictionary(
            placed.map { ($0.descriptorID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        return orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            let widgets = metricOrder(for: provider.id).compactMap { widgetsByID[$0] }
            guard !widgets.isEmpty else { return nil }
            return ProviderGroup(provider: provider, widgets: widgets)
        }
    }

    /// 렌더 중인 모든 카드의 descriptor(표시 순서) — refresh 순서와 quota 알림 평가의 입력.
    /// `placed`는 canonical이라 여기서 카드별 id로 확장 — 그러지 않으면 선택 계정의 metric이 알림에서 빠짐.
    func orderedRenderedDescriptors() -> [WidgetDescriptor] {
        displayGroups.flatMap(\.widgets).compactMap { descriptor(for: $0) }
    }

    /// 추가 데이터 조회에 사용할 표시 지표를 대시보드 순서로 반환.
    func orderedRefreshDescriptors() -> [WidgetDescriptor] {
        orderedRenderedDescriptors()
    }

    /// enabled provider 전체와 각자가 지원하는 *모든* metric(저장된 metric 순서) — enabled/disabled 행
    /// 자리 유지, switch는 가시성만 제어.
    var customizeGroups: [ProviderMetrics] {
        orderedProviders().compactMap { provider in
            guard isProviderEnabled(provider.id) else { return nil }
            let metrics = orderedSupportedMetrics(for: provider.id)
            guard !metrics.isEmpty else { return nil }
            return ProviderMetrics(provider: provider, metrics: metrics)
        }
    }

    /// L1 Customize 목록 — enablement 무관 모든 known provider(사용자 순서). disabled provider도 포함해
    /// 재활성·detail 진입 가능(`customizeGroups`와 달리 미필터); 행에 enablement flag와 metric 수 포함.
    var customizeProviderRows: [ProviderRow] {
        orderedProviders().map { provider in
            ProviderRow(
                provider: provider,
                isEnabled: isProviderEnabled(provider.id),
                metricCount: metricCount(for: provider.id)
            )
        }
    }

    /// provider가 지원하는 metric 총수 — L1 행 badge 숫자, enabled 수와 무관한 registry descriptor count.
    func metricCount(for providerID: String) -> Int {
        registry.descriptors(for: providerID).count
    }


    /// custom 순서의 지원 metric — 각 metric의 enabled 여부와 무관.
    func orderedSupportedMetrics(for providerID: String) -> [WidgetDescriptor] {
        var personal = metricOrder(for: providerID).filter { !ProviderAccountID.isSharedMetric($0) }.makeIterator()
        let ids = canonicalMetricOrder(for: providerID).compactMap { id -> String? in
            if ProviderAccountID.isSharedMetric(id) {
                return LayoutOrdering.cardMetricID(id, on: providerID)
            }
            return personal.next()
        } + Array(personal)
        return ids.compactMap { registry.descriptor(id: $0) }
    }

    func accountSettingsMetrics(for cardID: String) -> [WidgetDescriptor] {
        orderedSupportedMetrics(for: cardID).filter { !ProviderAccountID.isSharedMetric($0.id) }
    }

    func sharedSettingsMetrics(for cardID: String) -> [WidgetDescriptor] {
        orderedSupportedMetrics(for: ProviderAccountID.family(of: cardID))
            .filter { ProviderAccountID.isSharedMetric($0.id) }
    }


    /// provider header drag drop으로 provider 전체 reorder — 현재 표시 중(enabled) 순서 기준.
    /// 이동 단위는 family — 한 provider의 계정 카드가 흩어지면 선택 계정에 따라 섹션 위치가 달라짐.
    /// 반환값은 실제 변경 여부(drag gesture의 haptics 키).
    @discardableResult
    func reorderProvider(dragged: String, target: String) -> Bool {
        recordingUndoStep {
            var seen = Set<String>()
            let rows = customizeProviderRows.filter(\.isEnabled)
            let shown = rows.map { ProviderAccountID.family(of: $0.id) }
                .filter { seen.insert($0).inserted }
            let draggedFamily = ProviderAccountID.family(of: dragged)
            let targetFamily = ProviderAccountID.family(of: target)
            guard let next = Self.reordered(shown, dragged: draggedFamily, target: targetFamily) else { return false }

            // persist된 raw 순서에서 visible slot만 재배열 — unknown id(이 launch registry에 없는 account
            // 카드)와 disabled provider는 정확한 위치를 유지한 채 visible family만 그 사이를 이동.
            var membersByFamily: [String: [String]] = [:]
            for providerID in providerOrder + orderedProviderIDs() {
                let family = ProviderAccountID.family(of: providerID)
                if membersByFamily[family]?.contains(providerID) != true {
                    membersByFamily[family, default: []].append(providerID)
                }
            }
            let shownSet = Set(shown)
            var replacements = next.makeIterator()
            var rebuilt: [String] = []
            var placedFamilies = Set<String>()
            for providerID in providerOrder {
                let family = ProviderAccountID.family(of: providerID)
                guard shownSet.contains(family) else {
                    rebuilt.append(providerID)
                    continue
                }
                // family 블록은 첫 등장 slot에서 통째로 배치 — 나머지 멤버는 그 블록에 이미 포함.
                guard placedFamilies.insert(family).inserted, let replacement = replacements.next() else { continue }
                rebuilt.append(contentsOf: membersByFamily[replacement] ?? [replacement])
            }
            while let replacement = replacements.next() {
                rebuilt.append(contentsOf: membersByFamily[replacement] ?? [replacement])
            }
            for providerID in orderedProviderIDs() where !rebuilt.contains(providerID) {
                rebuilt.append(providerID)
            }
            providerOrder = rebuilt
            persistProviderOrder()
            syncPlacedOrder()
            return true
        }
    }



    /// 숨긴 지표를 포함해 카드의 지표를 재정렬하고 실제 변경 여부 반환.
    @discardableResult
    func reorderMetric(dragged: String, target: String, in providerID: String) -> Bool {
        recordingUndoStep { reorderMetricImpl(dragged: dragged, target: target, in: providerID) }
    }

    private func reorderMetricImpl(
        dragged: String, target: String, in providerID: String
    ) -> Bool {
        func settingsID(_ id: String) -> String {
            ProviderAccountID.isSharedMetric(id) ? Self.canonical(id) : id
        }
        let dragged = settingsID(dragged)
        let target = settingsID(target)
        let family = ProviderAccountID.family(of: providerID)
        guard dragged != target else { return false }
        let ordered = orderedSupportedMetrics(for: providerID).map { settingsID($0.id) }
        guard ordered.contains(dragged), ordered.contains(target) else { return false }

        guard let next = Self.reordered(ordered, dragged: dragged, target: target) else { return false }
        if providerID == family {
            metricOrderByProvider[family] = next
        } else {
            var personal = canonicalMetricOrder(for: family).filter { !ProviderAccountID.isSharedMetric($0) }.makeIterator()
            metricOrderByProvider[family] = next.compactMap {
                ProviderAccountID.isSharedMetric($0) ? Self.canonical($0) : personal.next()
            } + Array(personal)
            metricOrderByProvider[providerID] = next.filter { !ProviderAccountID.isSharedMetric($0) }
        }
        persistMetricOrder()
        syncPlacedOrder()
        return true
    }




    /// 순수 reorder — `dragged` 제거 후 `target` 인접에 재삽입(아래로 이동 시 뒤, 위로 이동 시 앞).
    /// id 누락·동일이면 nil. crafcat7/Peakmon(Apache-2.0)의 검증된 macOS drag-reorder 로직 이식.
    static func reordered(_ ids: [String], dragged: String, target: String) -> [String]? {
        guard dragged != target,
              let from = ids.firstIndex(of: dragged),
              let to = ids.firstIndex(of: target) else { return nil }
        var next = ids
        next.remove(at: from)
        guard let adjusted = next.firstIndex(of: target) else { return nil }
        let insert = from < to ? adjusted + 1 : adjusted
        next.insert(dragged, at: min(insert, next.count))
        return next
    }
}
