import Foundation

/// 상한 있는 행의 초기화 시각 표시 설정 — 남은 시간 또는 날짜·시각.
/// 대시보드의 초기화 라벨 또는 Settings의 Reset Times에서 선택.
enum ResetDisplayMode: String, Hashable, Sendable, CaseIterable {
    case relative
    case absolute

    var label: String {
        switch self {
        case .relative: return L10n.settings("Countdown")
        case .absolute: return L10n.settings("Exact Time")
        }
    }

    mutating func toggle() {
        self = self == .relative ? .absolute : .relative
    }
}
