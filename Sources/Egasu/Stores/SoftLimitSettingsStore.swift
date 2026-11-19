import Foundation
import Observation

@MainActor
@Observable
final class SoftLimitSettingsStore {
    static let thresholdRange = 1...100
    static let defaultThresholdPercent = 90

    private let defaults: UserDefaults
    private static let enabledKey = "openusage.softLimit.cancellationEnabled.v2"
    private static let windowKey = "openusage.softLimit.window.v1"
    private static let thresholdKey = "openusage.softLimit.thresholdPercent.v1"
    private var storedEnabled: Bool
    private var storedThresholdPercent: Int
    private(set) var labsAvailable: Bool
    @ObservationIgnored var onChange: (@MainActor () -> Void)?

    var enabled: Bool {
        get { storedEnabled }
        set {
            guard (!newValue || labsAvailable), newValue != storedEnabled else { return }
            storedEnabled = newValue
            defaults.set(newValue, forKey: Self.enabledKey)
            onChange?()
        }
    }

    var isActive: Bool { labsAvailable && enabled }

    var window: SoftLimitWindowSelection {
        didSet {
            defaults.set(window.rawValue, forKey: Self.windowKey)
            if window != oldValue { onChange?() }
        }
    }

    var thresholdPercent: Int {
        get { storedThresholdPercent }
        set {
            let normalized = Self.normalizedThreshold(newValue)
            let changed = storedThresholdPercent != normalized
            storedThresholdPercent = normalized
            defaults.set(normalized, forKey: Self.thresholdKey)
            if changed { onChange?() }
        }
    }

    init(defaults: UserDefaults = .standard, labsAvailable: Bool) {
        self.defaults = defaults
        self.labsAvailable = labsAvailable
        self.storedEnabled = defaults.bool(forKey: Self.enabledKey, default: false)
        self.window = defaults.enumValue(forKey: Self.windowKey, default: .all)
        if defaults.string(forKey: Self.windowKey) == "fiveHours" {
            defaults.set(SoftLimitWindowSelection.all.rawValue, forKey: Self.windowKey)
        }
        self.storedThresholdPercent = Self.normalizedThreshold(
            defaults.object(forKey: Self.thresholdKey) as? Int ?? Self.defaultThresholdPercent
        )
        applyLabsAvailability()
    }

    func setLabsAvailable(_ available: Bool) {
        guard available != labsAvailable else { return }
        labsAvailable = available
        applyLabsAvailability()
    }

    private func applyLabsAvailability() {
        if !labsAvailable && enabled {
            enabled = false
            AppLog.info(.config, "Soft Limit disabled because Beta Updates is off")
        } else {
            onChange?()
        }
    }

    func setThreshold(from text: String) -> Bool {
        guard let percent = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              Self.thresholdRange.contains(percent) else {
            AppLog.warn(.config, "Invalid Soft Limit threshold: expected a whole percentage from 1 to 100")
            return false
        }
        thresholdPercent = percent
        return true
    }

    func usedFraction(for descriptor: WidgetDescriptor, periodDurationMs: Int?) -> Double? {
        guard isActive, descriptor.supportsSoftLimit(window, periodDurationMs: periodDurationMs) else {
            return nil
        }
        return Double(thresholdPercent) / 100
    }

    private static func normalizedThreshold(_ value: Int) -> Int {
        min(max(value, thresholdRange.lowerBound), thresholdRange.upperBound)
    }
}
