import Foundation

/// 실행 중인 ProviderRuntime으로 구성하는 읽기 전용 프로바이더·지표 목록.
/// 구성 후 불변 — 렌더링마다 순차 탐색하지 않도록 조회 사전 한 번 생성.
struct WidgetRegistry: Sendable {
    let providers: [Provider]
    let descriptors: [WidgetDescriptor]

    private let descriptorsByID: [String: WidgetDescriptor]
    private let providersByID: [String: Provider]
    /// 프로바이더별 지표 선언 — 화면 지표 순서에 쓰는 원본 순서 유지.
    private let descriptorsByProvider: [String: [WidgetDescriptor]]
    /// 저장된 레이아웃이 참조하는 프로바이더 기준 지표 ID — 카드별 중복 제거 후 첫 등장 순서 보존.
    private let canonicalMetricIDsByFamily: [String: [String]]

    init(providers: [Provider], descriptors: [WidgetDescriptor]) {
        self.providers = providers
        self.descriptors = descriptors
        self.descriptorsByID = Dictionary(
            descriptors.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        self.providersByID = Dictionary(
            providers.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var byProvider: [String: [WidgetDescriptor]] = [:]
        var canonicalByFamily: [String: [String]] = [:]
        var seenCanonical = Set<String>()
        for descriptor in descriptors {
            byProvider[descriptor.providerID, default: []].append(descriptor)
            let canonicalID = ProviderAccountID.canonicalMetricID(descriptor.id)
            if seenCanonical.insert(canonicalID).inserted {
                canonicalByFamily[ProviderAccountID.family(of: descriptor.providerID), default: []].append(canonicalID)
            }
        }
        self.descriptorsByProvider = byProvider
        self.canonicalMetricIDsByFamily = canonicalByFamily
    }

    func descriptor(id: String) -> WidgetDescriptor? { descriptorsByID[id] }
    func provider(id: String) -> Provider? { providersByID[id] }
    func descriptors(for providerID: String) -> [WidgetDescriptor] {
        descriptorsByProvider[providerID] ?? []
    }

    /// 프로바이더가 지원하는 공통 지표 ID — 기본 카드 없이 추가 계정 카드만 있어도 제공.
    func canonicalMetricIDs(family: String) -> [String] {
        canonicalMetricIDsByFamily[family] ?? []
    }

    /// 프로바이더 기준 지표 ID의 지원 여부 — 저장된 레이아웃 항목 검증용.
    func hasCanonicalMetric(_ canonicalID: String) -> Bool {
        let family = ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: canonicalID))
        return canonicalMetricIDsByFamily[family]?.contains(canonicalID) ?? false
    }

    /// 현재 등록된 프로바이더만 저장 순서대로 유지 — 새 프로바이더는 등록 순서대로 추가.
    /// 같은 프로바이더의 카드가 있으면 새 계정을 그중 마지막 카드 뒤에 삽입. 대시보드·로컬 API·CLI 공용.
    func orderedProviderIDs(savedOrder: [String]) -> [String] {
        let defaults = providers.map(\.id)
        let known = Set(defaults)
        let saved = savedOrder.filter { known.contains($0) }
        let savedIDs = Set(saved)
        var result = saved
        for id in defaults where !savedIDs.contains(id) {
            let family = ProviderAccountID.family(of: id)
            if ProviderAccountID.isAccountCard(id),
               let anchor = result.lastIndex(where: { ProviderAccountID.family(of: $0) == family }) {
                result.insert(id, at: result.index(after: anchor))
            } else {
                result.append(id)
            }
        }
        return result
    }

    var limitDescriptorsByProvider: [String: [WidgetDescriptor]] {
        descriptorsByProvider.mapValues { $0.filter { !$0.limitResources.isEmpty } }
    }

    var historyDescriptorsByProvider: [String: UsageHistoryDescriptor] {
        descriptorsByProvider.compactMapValues { descriptors in
            descriptors.compactMap(\.historyResource).first
        }
    }

    @MainActor
    static func from(_ runtimes: [ProviderRuntime]) -> WidgetRegistry {
        let providers = runtimes.map(\.provider)
        let metrics = runtimes.flatMap(\.widgetDescriptors)
        return WidgetRegistry(providers: providers, descriptors: metrics)
    }
}
