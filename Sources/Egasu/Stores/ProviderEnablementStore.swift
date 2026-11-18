import Foundation
import Observation

/// 프로바이더 활성화 상태 — 활성 목록 키가 없으면 구형 비활성 목록을 읽어 저장 형식 호환.
/// 알려진 프로바이더 목록으로 사용자의 비활성화와 신규 프로바이더 구분.
/// 새 프로바이더 탐지는 알려진 목록에 없는 항목만 처리하여 이미 확인한 항목의 사용자 선택 보존.
@MainActor
@Observable
final class ProviderEnablementStore {
    private static let disabledStorageKey = "openusage.disabledProviders.v1"
    private static let enabledStorageKey = "openusage.enabledProviders.v1"
    private static let knownStorageKey = "openusage.knownProviders.v1"
    private static let initialDetectionPendingKey = "openusage.initialProviderDetectionPending.v1"

    /// 활성 프로바이더 목록이 실제 변경되면 알림 게시 — 갱신 루프의 조기 재개 신호.
    /// 전체 UserDefaults 변경 알림은 구독하지 않음 — 무관한 저장으로 불필요한 갱신 방지.
    /// 불변 Sendable 상수이므로 nonisolated에서 메인 액터 전환 없이 접근 가능.
    nonisolated static let didChangeNotification = Notification.Name("ProviderEnablementDidChange")

    /// 비활성 프로바이더를 켤 때 호출 — 갱신 재개 전에 일반 실패 대기를 해제.
    var onProviderEnabled: (@MainActor (String) -> Void)?
    /// 활성화 변경 후 호출 — 갱신 계획과 Reset Watch 상태를 갱신하고 iCloud 문서 쓰기 예약.
    var onChange: (@MainActor () -> Void)?

    /// 구형 방식의 비활성 프로바이더 목록 — 활성 목록 방식에서는 빈 집합.
    private(set) var disabledIDs: Set<String>
    /// 활성 프로바이더 목록 — nil이면 구형 비활성 목록 방식.
    private(set) var enabledIDs: Set<String>?
    /// 이 설치에서 확인한 프로바이더 ID — 설정 이전·첫 실행 초기화 후 새 항목을 계속 추가.
    private(set) var knownIDs: Set<String>
    private(set) var isInitialDetectionPending: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let enabled = defaults.stringArray(forKey: Self.enabledStorageKey) {
            self.enabledIDs = Set(enabled)
            self.disabledIDs = []
        } else {
            self.enabledIDs = nil
            self.disabledIDs = Set(defaults.stringArray(forKey: Self.disabledStorageKey) ?? [])
        }
        self.knownIDs = Set(defaults.stringArray(forKey: Self.knownStorageKey) ?? [])
        self.isInitialDetectionPending = defaults.bool(forKey: Self.initialDetectionPendingKey)
    }

    func setInitialDetectionPending(_ pending: Bool) {
        isInitialDetectionPending = pending
        defaults.set(pending, forKey: Self.initialDetectionPendingKey)
    }

    func isEnabled(_ id: String) -> Bool {
        if let enabledIDs { return enabledIDs.contains(id) }
        return !disabledIDs.contains(id)
    }

    func setEnabled(_ enabled: Bool, for id: String) {
        if var ids = enabledIDs {
            if enabled { ids.insert(id) } else { ids.remove(id) }
            // 상태가 그대로이면 저장·갱신 알림 없이 반환.
            guard ids != enabledIDs else { return }
            enabledIDs = ids
            defaults.set(Array(ids), forKey: Self.enabledStorageKey)
        } else {
            let before = disabledIDs
            if enabled {
                disabledIDs.remove(id)
            } else {
                disabledIDs.insert(id)
            }
            guard disabledIDs != before else { return }
            defaults.set(Array(disabledIDs), forKey: Self.disabledStorageKey)
        }
        // 갱신 재개 알림 전에 일반 실패 대기를 해제하여 재시도 가능 상태로 전환.
        if enabled { onProviderEnabled?(id) }
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 전달된 ID를 알려진 목록에 기록하고 새 항목 반환 — 활성화 변경·알림 없음.
    @discardableResult
    func registerKnownProviders(_ ids: Set<String>) -> Set<String> {
        let new = ids.subtracting(knownIDs)
        guard !new.isEmpty else { return [] }
        knownIDs.formUnion(new)
        defaults.set(Array(knownIDs), forKey: Self.knownStorageKey)
        return new
    }

    /// 활성 목록 방식으로 전환하여 전달된 ID만 활성화 — 신규 설치 초기화용.
    /// 새로 켠 프로바이더마다 onProviderEnabled 호출 후 변경 알림 게시.
    func seedEnabledProviders(_ ids: Set<String>) {
        let newlyEnabled = ids.filter { !isEnabled($0) }
        let changed = enabledIDs != ids
        enabledIDs = ids
        disabledIDs = []
        defaults.set(Array(ids), forKey: Self.enabledStorageKey)
        guard changed else { return }
        for id in newlyEnabled.sorted() { onProviderEnabled?(id) }
        onChange?()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
