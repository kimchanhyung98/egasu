import Foundation
import Observation

/// 모든 계정에서 구독 타이머 자동 메시지에 적용하는 설정.
@MainActor
@Observable
final class UsageTimerSetting {
    private static let key = "openusage.usageTimer.autoStartEnabled"
    private let defaults: UserDefaults
    @ObservationIgnored var onDisable: (() -> Void)?

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.key)
            if !isEnabled { onDisable?() }
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key, default: true)
    }
}
