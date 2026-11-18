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
    static let menuBarStyleKey = "openusage.layout.v1.menuBarStyle"
    static let menuBarLimitKey = "menuBarLimit"
    static let menuBarSelectionKey = "menuBarSelection"
    static let menuBarExtrasKey = "menuBarExtras"
    static let legacyMenuBarAlwaysShowsKey = "menuBarAlwaysShows"
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

    var menuBarStyle: MenuBarStyle {
        didSet { defaults.set(menuBarStyle.rawValue, forKey: Self.menuBarStyleKey) }
    }

    var menuBarLimit: MenuBarLimit {
        didSet { defaults.set(menuBarLimit.rawValue, forKey: Self.menuBarLimitKey) }
    }

    var menuBarSelection: MenuBarSelection {
        didSet { defaults.set(menuBarSelection.rawValue, forKey: Self.menuBarSelectionKey) }
    }

    var showsMenuBarExtras: Bool {
        didSet { defaults.set(showsMenuBarExtras, forKey: Self.menuBarExtrasKey) }
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
        menuBarStyle = defaults.enumValue(forKey: Self.menuBarStyleKey, default: .text)
        menuBarLimit = defaults.enumValue(forKey: Self.menuBarLimitKey, default: .upToThree)
        let legacySelection: MenuBarSelection = defaults.bool(forKey: Self.legacyMenuBarAlwaysShowsKey, default: false) ? .priority : .runningOut
        menuBarSelection = defaults.enumValue(forKey: Self.menuBarSelectionKey, default: legacySelection)
        showsMenuBarExtras = defaults.bool(forKey: Self.menuBarExtrasKey, default: true)
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
