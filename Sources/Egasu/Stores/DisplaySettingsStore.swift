import Foundation
import Observation

enum DashboardLayoutStyle: String, CaseIterable, Sendable {
    case minimal
    case cards

    var label: String {
        switch self {
        case .minimal: L10n.settings("Minimal")
        case .cards: L10n.settings("Cards")
        }
    }
}

/// 대시보드·메뉴 막대 표시 설정 — 막대 색, Priority 탭, 메뉴 막대, 알림이 같은 임계값을 공유.
@MainActor
@Observable
final class DisplaySettingsStore {
    static let dashboardLayoutKey = "allUsageLayout"
    static let priorityWarningKey = "priorityWarning"
    static let priorityCriticalKey = "priorityCritical"
    static let priorityBurningFastKey = "priorityBurningFast"
    static let priorityUseItOrLoseItKey = "priorityUseItOrLoseIt"
    static let paceMarksKey = "paceMarks"
    /// 이전 "Always Show Pacing" — 사용자가 직접 정한 값만 Pace Marks로 이어받음.
    static let legacyAlwaysShowPacingKey = "alwaysShowPacing"

    @ObservationIgnored private let defaults: UserDefaults

    var dashboardLayout: DashboardLayoutStyle {
        didSet { defaults.set(dashboardLayout.rawValue, forKey: Self.dashboardLayoutKey) }
    }

    var priorityLimits: PriorityLimits {
        didSet {
            defaults.set(priorityLimits.warning, forKey: Self.priorityWarningKey)
            defaults.set(priorityLimits.critical, forKey: Self.priorityCriticalKey)
        }
    }

    var showsBurningFast: Bool {
        didSet { defaults.set(showsBurningFast, forKey: Self.priorityBurningFastKey) }
    }

    var showsUseItOrLoseIt: Bool {
        didSet { defaults.set(showsUseItOrLoseIt, forKey: Self.priorityUseItOrLoseItKey) }
    }

    var showsPaceMarks: Bool {
        didSet { defaults.set(showsPaceMarks, forKey: Self.paceMarksKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        dashboardLayout = defaults.enumValue(forKey: Self.dashboardLayoutKey, default: .minimal)
        priorityLimits = PriorityLimits(
            warning: defaults.object(forKey: Self.priorityWarningKey) as? Int ?? PriorityLimits.standard.warning,
            critical: defaults.object(forKey: Self.priorityCriticalKey) as? Int ?? PriorityLimits.standard.critical
        )
        showsBurningFast = defaults.bool(forKey: Self.priorityBurningFastKey, default: true)
        showsUseItOrLoseIt = defaults.bool(forKey: Self.priorityUseItOrLoseItKey, default: true)
        showsPaceMarks =
            defaults.object(forKey: Self.paceMarksKey) as? Bool
            ?? defaults.object(forKey: Self.legacyAlwaysShowPacingKey) as? Bool
            ?? false
    }
}
