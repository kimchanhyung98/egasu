import Foundation

/// 대시보드 탭 — 앱 시작 시 Default Tab 적용, 패널을 다시 열면 마지막 선택 유지.
enum DashboardTab: String, Hashable, Sendable, CaseIterable {
    static let defaultKey = "defaultDashboardTab"

    case priority
    case allUsage

    static func preferred(in defaults: UserDefaults = .standard) -> Self {
        defaults.enumValue(forKey: defaultKey, default: .priority)
    }

    var label: String {
        switch self {
        case .priority: L10n.dashboard("Priority")
        case .allUsage: L10n.dashboard("All Usage")
        }
    }
}
