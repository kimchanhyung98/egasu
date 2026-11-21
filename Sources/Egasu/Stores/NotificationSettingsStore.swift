import Foundation
import Observation

/// quota pace와 Codex Reset Watch 알림 설정 — master switch 없이 조건별 선택.
/// 전부 기본 OFF — 첫 trigger on 시점에 알림 권한 요청, 신규 설치는 opt-in 전까지 조용함
@MainActor
@Observable
final class NotificationSettingsStore {
    private let defaults: UserDefaults

    private static let codexResetWatchKey = "openusage.notifications.codexResetWatch"

    var onCodexResetWatchChange: (@MainActor () -> Void)?

    /// 남은 양이 Priority Critical 기준 이하 — 저장 키는 옛 Almost Out 그대로.
    var critical: Bool {
        didSet { defaults.set(critical, forKey: PaceMilestone.critical.settingKey) }
    }

    /// 남은 양이 Priority Warning 기준 이하 — 저장 키는 옛 Cutting It Close 그대로.
    var warning: Bool {
        didSet { defaults.set(warning, forKey: PaceMilestone.warning.settingKey) }
    }

    /// 지금 속도면 초기화 전 소진.
    var closeToRunningOut: Bool {
        didSet { defaults.set(closeToRunningOut, forKey: PaceMilestone.closeToRunningOut.settingKey) }
    }

    /// 하루 초과 주기에서 초기화 하루 전 50% 넘게 남음.
    var useItOrLoseIt: Bool {
        didSet { defaults.set(useItOrLoseIt, forKey: PaceMilestone.useItOrLoseIt.settingKey) }
    }

    var quotaRecovered: Bool {
        didSet { defaults.set(quotaRecovered, forKey: PaceMilestone.quotaRecovered.settingKey) }
    }

    var codexResetWatch: Bool {
        didSet {
            guard oldValue != codexResetWatch else { return }
            defaults.set(codexResetWatch, forKey: Self.codexResetWatchKey)
            onCodexResetWatchChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.critical = defaults.bool(forKey: PaceMilestone.critical.settingKey, default: false)
        self.warning = defaults.bool(forKey: PaceMilestone.warning.settingKey, default: false)
        self.closeToRunningOut = defaults.bool(forKey: PaceMilestone.closeToRunningOut.settingKey, default: false)
        self.useItOrLoseIt = defaults.bool(forKey: PaceMilestone.useItOrLoseIt.settingKey, default: false)
        self.quotaRecovered = defaults.bool(forKey: PaceMilestone.quotaRecovered.settingKey)
        self.codexResetWatch = defaults.bool(forKey: Self.codexResetWatchKey, default: false)
    }

    func isOn(_ milestone: PaceMilestone) -> Bool {
        switch milestone {
        case .quotaRecovered: quotaRecovered
        case .critical: critical
        case .warning: warning
        case .closeToRunningOut: closeToRunningOut
        case .useItOrLoseIt: useItOrLoseIt
        }
    }

    /// trigger 하나 이상 on 여부 — 권한 요청 시점과 Settings 권한 notice 표시 판단에 사용
    var anyEnabled: Bool { PaceMilestone.allCases.contains(where: isOn) || codexResetWatch }
}
