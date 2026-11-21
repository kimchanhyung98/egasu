import AppKit

/// Force Touch 트랙패드의 햅틱 — 미지원 하드웨어에서는 효과 없음.
/// 드래그 전용 — 클릭 자체의 햅틱과 겹치지 않도록 클릭 동작에서는 호출 금지.
@MainActor
enum Haptics {
    /// 새 순서가 확정된 드래그에서만 햅틱 발생 — 단순 이동에는 미발생.
    /// 빠른 연속 드래그의 진동이 겹치지 않도록 `.levelChange` 호출 사이 최소 간격 적용.
    private static let minimumSnapInterval: TimeInterval = 0.12
    private static var lastSnapAt: TimeInterval = 0

    static func snap() {
        let now = ProcessInfo.processInfo.systemUptime
        guard now - lastSnapAt >= minimumSnapInterval else { return }
        lastSnapAt = now

        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
    }
}
