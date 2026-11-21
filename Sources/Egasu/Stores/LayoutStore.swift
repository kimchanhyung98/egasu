import SwiftUI
import Observation

/// Mutable 레이아웃 상태 — enabled widget 집합(`placed`), provider 순서, provider별 custom metric 순서.
@MainActor
@Observable
final class LayoutStore {
    // Swift의 private은 file-scope — `LayoutStore+Customization.swift`와 공유하는 멤버는 module-internal 유지.
    var placed: [PlacedWidget]

    var draggingID: UUID?
    /// Persist되는 provider 표시 순서(provider id) — dashboard group과 Customize section 공용.
    var providerOrder: [String]
    /// 프로바이더·계정 카드별 지표 순서 — 숨김 변경과 별개로 위치 유지.
    var metricOrderByProvider: [String: [String]]

    /// Priority 고정 — 개인 지표는 계정 카드, 공통 지표는 프로바이더 기준으로 저장.
    private(set) var priorityPinIDs: Set<String>

    /// 레이아웃 customization용 bounded 앱 전역 undo stack — 비persist(세션 내 affordance),
    /// entry는 변경 전 `LayoutSnapshot`, `undo()`가 pop·복원.
    private var undoHistory = LayoutUndoHistory()
    /// `undo()` replay 중 flag — replay가 유발한 mutation의 stack 재기록 차단(undo는 새 undoable action이 아님).
    private var isApplyingUndo = false

    private(set) var registry: WidgetRegistry
    private let persistence: LayoutPersistence
    private let migrationBaselineMetricIDs: [String]
    private let defaultMetricIDs: [String]?
    private let knownCardIDs: Set<String>
    private let defaultPinnedMetricIDs: [String]
    let isProviderEnabled: @MainActor (String) -> Bool

    init(
        registry: WidgetRegistry,
        defaults: UserDefaults = .standard,
        storageKey: String = "openusage.layout.v1",
        defaultMetricIDs: [String]? = nil,
        migrationBaselineMetricIDs: [String] = DefaultLayout.migrationBaselineMetricIDs,
        defaultPinnedMetricIDs: [String] = DefaultLayout.pinnedMetricIDs,
        knownCardIDs: Set<String> = [],
        profileIDsByCardID: [String: String] = [:],
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true }
    ) {
        self.registry = registry
        let persistence = LayoutPersistence(defaults: defaults, storageKey: storageKey)
        self.persistence = persistence
        // 기본값은 프로바이더 기준으로 비교하고 개인 지표는 카드 ID로 저장.
        self.migrationBaselineMetricIDs = migrationBaselineMetricIDs
        self.defaultMetricIDs = defaultMetricIDs
        self.knownCardIDs = knownCardIDs
        self.defaultPinnedMetricIDs = defaultPinnedMetricIDs
        self.isProviderEnabled = isProviderEnabled
        persistence.reconcileAccountProfiles(profileIDsByCardID, registry: registry)

        let initial = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: defaultMetricIDs ?? DefaultLayout.metricIDs(in: registry),
                migrationBaselineMetricIDs: migrationBaselineMetricIDs
            ),
            knownCardIDs: knownCardIDs
        )
        placed = initial.placed
        providerOrder = initial.providerOrder
        metricOrderByProvider = initial.metricOrderByProvider
        priorityPinIDs = Self.loadPriorityPins(from: persistence, registry: registry)

        if initial.shouldPersistMetricOrder { persistMetricOrder() }
        if initial.shouldPersistVisibility { persistence.saveDisabledMetrics(initial.disabledMetricIDs) }
        if initial.shouldClearOnDemandState { persistence.clearOnDemandState() }
        syncPlacedOrder(persistChanges: false)
    }

    /// 새 카드·프로필 연결에 맞춰 저장된 숨김·순서를 다시 읽고 화면 연결 유지.
    /// 개인 한도와 공통 이력을 구분하고, 프로필 변경 시 undo 이력 초기화.
    func replaceRegistry(_ registry: WidgetRegistry, profileIDsByCardID: [String: String]? = nil) {
        let profilesChanged = profileIDsByCardID.map { persistence.reconcileAccountProfiles($0, registry: registry) } ?? false
        guard profilesChanged || registry.providers != self.registry.providers || registry.descriptors != self.registry.descriptors else {
            return
        }
        self.registry = registry

        let reloaded = LayoutBootstrap.load(
            registry: registry,
            persistence: persistence,
            defaults: LayoutDefaultSet(
                metricIDs: defaultMetricIDs ?? DefaultLayout.metricIDs(in: registry),
                migrationBaselineMetricIDs: migrationBaselineMetricIDs
            ),
            knownCardIDs: knownCardIDs
        )
        placed = reloaded.placed
        providerOrder = reloaded.providerOrder
        metricOrderByProvider = reloaded.metricOrderByProvider
        priorityPinIDs = Self.loadPriorityPins(from: persistence, registry: registry)
        undoHistory.clear()
        cancelDrag()

        if reloaded.shouldPersistMetricOrder { persistMetricOrder() }
        if reloaded.shouldPersistVisibility { persistence.saveDisabledMetrics(reloaded.disabledMetricIDs) }
        if reloaded.shouldClearOnDemandState { persistence.clearOnDemandState() }
        syncPlacedOrder(persistChanges: false)
    }

    /// 기본 프로바이더 지표 ID — 공통 지표와 기존 별표 비교용.
    static func canonical(_ metricID: String) -> String {
        ProviderAccountID.canonicalMetricID(metricID)
    }



    // MARK: - Customize mutations

    /// metric on/off toggle — Customize 스위치가 구동하는 단일 seam, 앱의 add/remove 경로와 공유.
    /// 개인 한도는 해당 카드에, 공통 이력은 같은 프로바이더의 카드 전체에 반영.
    func setMetricEnabled(_ descriptorID: String, _ enabled: Bool) {
        let canonicalID = Self.canonical(descriptorID)
        let settingsID = ProviderAccountID.isSharedMetric(descriptorID) ? canonicalID : descriptorID
        recordingUndoStep {
            if enabled {
                add(settingsID)
            } else if let widget = placed.first(where: { $0.descriptorID == settingsID }) {
                remove(widget.id)
                if priorityPinIDs.remove(settingsID) != nil { persistence.savePriorityPins(priorityPinIDs) }
            }
        }
    }

    // MARK: - Undo

    /// undo 가능 여부 — Customize Undo 버튼 표시와 앱 전역 ⌘Z handler의 no-op guard 구동.
    var canUndo: Bool { undoHistory.canUndo }

    private func currentSnapshot() -> LayoutSnapshot {
        LayoutSnapshot(
            placed: placed,
            providerOrder: providerOrder,
            metricOrderByProvider: metricOrderByProvider,
            priorityPinIDs: priorityPinIDs
        )
    }

    /// 사용자 레이아웃 mutation을 undo step 1개로 기록하며 실행 — 실제 변경이 있을 때만 사전 snapshot을
    /// push(no-op action은 빈 step 미기록). 재진입 호출과 undo replay는 `isApplyingUndo`로 외부 단일 step에 coalesce.
    func recordingUndoStep<T>(_ body: () -> T) -> T {
        // 이미 undoable scope 내부(또는 undo replay 중) — 바깥 scope가 단일 step을 소유, undo는 자신을 기록하지 않음.
        guard !isApplyingUndo else { return body() }
        let before = currentSnapshot()
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        let result = body()
        if currentSnapshot() != before {
            undoHistory.record(before)
        }
        return result
    }

    /// 최근 customization step 롤백 — 없으면 false. 반복 호출로 계속 후퇴; 앱 전역에서 사용 가능.
    @discardableResult
    func undo() -> Bool {
        guard let snapshot = undoHistory.popLast() else { return false }
        isApplyingUndo = true
        defer { isApplyingUndo = false }
        restore(snapshot)
        return true
    }

    /// 실행 취소 대상 필드를 복원하고 같은 저장 경로에 반영.
    private func restore(_ snapshot: LayoutSnapshot) {
        cancelDrag()
        placed = snapshot.placed
        providerOrder = snapshot.providerOrder
        metricOrderByProvider = snapshot.metricOrderByProvider
        priorityPinIDs = snapshot.priorityPinIDs
        persist()
        persistProviderOrder()
        persistMetricOrder()
        persistence.savePriorityPins(priorityPinIDs)
    }

    // MARK: - Priority pins

    /// 가져온 고정값에서 알려진 고정 불가 지표만 제거하고, 현재 카탈로그에 없는 지표는 복귀를 위해 보관.
    private static func loadPriorityPins(from persistence: LayoutPersistence, registry: WidgetRegistry) -> Set<String> {
        let saved = Set(persistence.loadPriorityPins() ?? [])
        let valid = saved.filter { registry.descriptor(id: $0)?.pinnable != false }
        if valid != saved { persistence.savePriorityPins(valid) }
        return valid
    }

    /// 기존 별표의 사용자 지정분을 알려진 계정으로 1회 이전 — Priority 저장값이 있으면 생략.
    func migrateMenuBarStars(isHiddenOnCard: (String, String) -> Bool = { _, _ in false }) -> Int? {
        guard !persistence.hasStoredPriorityPins else { return nil }
        defer { persistence.savePriorityPins(priorityPinIDs) }
        guard let saved = persistence.loadPins() else { return nil }
        // 프로바이더가 꺼져 있어도 별표는 남겨 두고 다시 켰을 때 표시.
        let stars = Set(saved.map(Self.canonical)).filter(registry.hasCanonicalMetric)
        let defaults = Set(defaultPinnedMetricIDs).filter(registry.hasCanonicalMetric)
        guard stars != defaults else { return nil }
        var pins = Set<String>()
        for star in stars {
            let family = LayoutOrdering.family(ofMetric: star)
            for provider in registry.providers where ProviderAccountID.family(of: provider.id) == family {
                let cardMetricID = LayoutOrdering.cardMetricID(star, on: provider.id)
                if registry.descriptor(id: cardMetricID)?.pinnable == true,
                   isMetricEnabled(cardMetricID), !isHiddenOnCard(cardMetricID, provider.id) {
                    pins.insert(ProviderAccountID.isSharedMetric(cardMetricID) ? Self.canonical(cardMetricID) : cardMetricID)
                }
            }
        }
        priorityPinIDs = pins
        return pins.isEmpty ? nil : pins.count
    }

    /// 계정별 고정 조회 — 공통 지표는 프로바이더 설정으로 조회.
    func isMetricPinned(_ descriptorID: String) -> Bool {
        let settingsID = ProviderAccountID.isSharedMetric(descriptorID) ? Self.canonical(descriptorID) : descriptorID
        return registry.descriptor(id: descriptorID) != nil && priorityPinIDs.contains(settingsID)
    }

    /// 표시 중인 고정 가능 지표만 고정 — 개인·공통 범위에 저장하고 실행 취소 지원.
    func setMetric(_ descriptorID: String, pinned: Bool) {
        let settingsID = ProviderAccountID.isSharedMetric(descriptorID) ? Self.canonical(descriptorID) : descriptorID
        recordingUndoStep {
            if pinned {
                guard registry.descriptor(id: descriptorID)?.pinnable == true, isMetricEnabled(descriptorID),
                      priorityPinIDs.insert(settingsID).inserted else { return }
            } else {
                guard priorityPinIDs.remove(settingsID) != nil else { return }
            }
            persistence.savePriorityPins(priorityPinIDs)
        }
    }








    // MARK: - Mutations

    func add(_ descriptorID: String) {
        guard registry.descriptor(id: descriptorID) != nil else { return }
        let settingsID = ProviderAccountID.isSharedMetric(descriptorID) ? Self.canonical(descriptorID) : descriptorID
        guard !placed.contains(where: { $0.descriptorID == settingsID }) else { return }
        cancelDrag()
        placed.append(PlacedWidget(descriptorID: settingsID))
        syncPlacedOrder()
    }

    func remove(_ id: UUID) {
        guard let index = placed.firstIndex(where: { $0.id == id }) else { return }
        cancelDrag()
        placed.remove(at: index)
        persist()
    }

    func resetToDefault() {
        cancelDrag()
        // reset은 그 자체로 deliberate action — pre-reset 레이아웃을 가리키는 undo stack 전체 폐기.
        undoHistory.clear()
        let currentDefaults = Set(defaultMetricIDs ?? DefaultLayout.metricIDs(in: registry))
        placed = registry.descriptors.filter {
            !ProviderAccountID.isSharedMetricAlias($0.id)
                && currentDefaults.contains(Self.canonical($0.id))
        }.map { PlacedWidget(descriptorID: $0.id) }
        providerOrder = registry.providers.map(\.id)
        persistProviderOrder()
        metricOrderByProvider = LayoutOrdering.defaultMetricOrder(registry: registry)
        persistMetricOrder()
        priorityPinIDs = []
        persistence.savePriorityPins(priorityPinIDs)
        persistence.clearOnDemandState()
        persistence.saveDisabledMetrics([])
        persist()
    }

    /// 한 provider의 customization만 default로 reset(enabled metric·metric 순서·Priority 고정) —
    /// 다른 provider와 전체 provider 순서는 유지. `resetToDefault`의 per-provider 대응; 미지 provider는 no-op.
    /// account 카드 id로 호출해도 family 설정 1벌을 reset — 같은 family의 모든 카드가 함께 복귀.
    func resetProvider(_ providerID: String) {
        guard registry.provider(id: providerID) != nil else { return }
        cancelDrag()
        // reset은 undoable edit이 아님 — snapshot이 whole-layout이라 per-provider trim 대신 stack 전체 clear.
        undoHistory.clear()

        // 이 family의 canonical metric 전집 — 아래 membership set들의 scope.
        let family = ProviderAccountID.family(of: providerID)
        let canonicalIDs = registry.canonicalMetricIDs(family: family)
        let owned = Set(canonicalIDs)
        func defaults(_ ids: [String]) -> [String] {
            ids.filter { owned.contains($0) }
        }

        // enabled metric: 이 family의 placed 제거 후 default-on set 재seed — 타 provider widget은
        // identity·위치 유지, 마지막 `syncPlacedOrder`가 전체를 provider+metric 순서로 재정렬.
        let currentDefaults = Set(defaults(defaultMetricIDs ?? DefaultLayout.metricIDs(in: registry)))
        let familyDescriptors = registry.descriptors.filter {
            LayoutOrdering.family(ofMetric: $0.id) == family && !ProviderAccountID.isSharedMetricAlias($0.id)
        }
        let layoutOwned = Set(familyDescriptors.map(\.id))
        placed = placed.filter { !layoutOwned.contains($0.descriptorID) }
            + familyDescriptors.filter { currentDefaults.contains(Self.canonical($0.id)) }
                .map { PlacedWidget(descriptorID: $0.id) }

        // metric 순서는 이 family만 registry 순서로 복귀.
        metricOrderByProvider[family] = canonicalIDs
        for provider in registry.providers where ProviderAccountID.family(of: provider.id) == family && provider.id != family {
            metricOrderByProvider[provider.id] = familyDescriptors.filter { $0.providerID == provider.id }.map(\.id)
        }
        persistMetricOrder()

        // 해당 프로바이더의 Priority 고정만 해제.
        priorityPinIDs = priorityPinIDs.filter { ProviderAccountID.family(of: ProviderAccountID.providerID(ofMetric: $0)) != family }
        persistence.savePriorityPins(priorityPinIDs)

        syncPlacedOrder() // `placed` persist 포함
    }

    func cancelDrag() {
        draggingID = nil
    }

    func persist() {
        guard let saved = persistence.loadDisabledMetrics() else { return }
        let current = Set(registry.descriptors.map(\.id).filter { !ProviderAccountID.isSharedMetricAlias($0) })
        let shown = Set(placed.map(\.descriptorID))
        persistence.saveDisabledMetrics(Set(saved).subtracting(current).union(current.subtracting(shown)))
    }

    func persistProviderOrder() {
        persistence.saveProviderOrder(providerOrder)
    }

    func persistMetricOrder() {
        persistence.saveMetricOrder(metricOrderByProvider)
    }


    /// 카드별 개인 지표 순서 — 공통 이력의 계정별 복사본 제외.
    func metricOrder(for providerID: String) -> [String] {
        let valid = registry.descriptors(for: providerID).map(\.id)
            .filter { !ProviderAccountID.isSharedMetricAlias($0) }
        return LayoutOrdering.normalizedMetricIDs(metricOrderByProvider[providerID] ?? [], validIDs: valid)
    }

    /// 기본 프로바이더 지표 순서 — 기존 화면의 공통 이력 배치 기준.
    func canonicalMetricOrder(for providerID: String) -> [String] {
        let family = ProviderAccountID.family(of: providerID)
        let valid = registry.canonicalMetricIDs(family: family)
        let saved = metricOrderByProvider[family] ?? []
        return LayoutOrdering.normalizedMetricIDs(saved, validIDs: valid)
    }

    func syncPlacedOrder(persistChanges: Bool = true) {
        let byDescriptor = Dictionary(
            placed.map { ($0.descriptorID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var ordered: [PlacedWidget] = []
        for providerID in orderedProviderIDs() {
            ordered.append(contentsOf: metricOrder(for: providerID).compactMap { byDescriptor[$0] })
        }
        let orderedIDs = Set(ordered.map(\.id))
        ordered.append(contentsOf: placed.filter { !orderedIDs.contains($0.id) })
        placed = ordered
        if persistChanges { persist() }
    }

}
