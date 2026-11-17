import Foundation

/// 남은 양과 무관하게 초기화 전에 소진될 속도인 한도.
/// 초기화 시점의 예상 사용량이 한도의 90% 이하로 내려가면 빠른 소진 상태 해제 — 경계 부근의 반복 전환 방지.
/// Burning Fast 알림도 같은 회복 기준에서 다시 활성화.
struct BurningFast: Equatable {
    /// 마지막 읽기에서 빠른 소진이던 지표와 그 기간의 초기화 시각.
    var latched: [String: Date] = [:]

    func contains(_ line: DashboardLine, now: Date) -> Bool {
        Self.isBurning(line.data, now: now, wasBurning: wasBurning(line.id, line.data, now: now))
    }

    /// 새 기간은 이전 기간과 무관하게 새로 시작.
    func wasBurning(_ id: String, _ data: WidgetData, now: Date) -> Bool {
        guard let reset = latched[id] else { return false }
        return !PaceNotificationLogic.resetWindowAdvanced(resetsAt: data.resetsAt, previousReset: reset, now: now)
    }

    static func isBurning(_ data: WidgetData, now: Date, wasBurning: Bool) -> Bool {
        guard !data.isForecast else { return false }
        switch data.meterState(now: now) {
        case .runningOut: return true
        case .closeToLimit: return wasBurning
        case .noData, .spent, .healthy, .level: return false
        }
    }
}
