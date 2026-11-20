import Foundation

enum SoftLimitWindow: String, Codable, CaseIterable, Sendable {
    case weekly
    case monthly

    func matches(periodDurationMs: Int, allowsDSTOffset: Bool = true) -> Bool {
        guard periodDurationMs > 0 else { return false }
        // 결제 주기의 달력 경계는 서머타임 전환으로 한 시간이 달라질 수 있음.
        let days = self == .weekly ? 7...7 : 28...31
        let tolerance = allowsDSTOffset ? 3_600_000 : 0
        return days.contains { abs(periodDurationMs - $0 * MetricPeriod.dayMs) <= tolerance }
    }
}

enum SoftLimitWindowSelection: String, CaseIterable, Sendable {
    case all
    case weekly
    case monthly

    var label: String {
        switch self {
        case .all: L10n.settings("Weekly and Monthly")
        case .weekly: L10n.metrics("Weekly")
        case .monthly: L10n.metrics("Monthly")
        }
    }

    func includes(_ window: SoftLimitWindow) -> Bool {
        switch self {
        case .all: true
        case .weekly: window == .weekly
        case .monthly: window == .monthly
        }
    }
}

extension WidgetDescriptor {
    func hasMeasuredSoftLimit(in selection: SoftLimitWindowSelection) -> Bool {
        softLimitWindows.contains(where: selection.includes)
            && limitResources.contains { $0.kind == .consumption && !$0.estimated }
    }

    func supportingSoftLimit(
        _ window: SoftLimitWindow, _ otherWindows: SoftLimitWindow..., acceptsMissingDuration: Bool = false,
        allowsDSTOffset: Bool = false
    ) -> WidgetDescriptor {
        var copy = self
        copy.softLimitWindows = Set([window] + otherWindows)
        copy.acceptsMissingSoftLimitDuration = acceptsMissingDuration
        copy.softLimitAllowsDSTOffset = allowsDSTOffset
        return copy
    }

    func supportsSoftLimit(_ selection: SoftLimitWindowSelection, periodDurationMs: Int?) -> Bool {
        softLimitWindows.contains { window in
            guard selection.includes(window) else { return false }
            guard let periodDurationMs else { return acceptsMissingSoftLimitDuration && softLimitWindows.count == 1 }
            return window.matches(periodDurationMs: periodDurationMs, allowsDSTOffset: softLimitAllowsDSTOffset)
        }
    }
}

extension WidgetData {
    var softLimitMarkerFraction: Double? {
        guard isQuotaMeter, hasData, let limit, limit > 0, let softLimitUsedFraction else { return nil }
        let used = min(max(softLimitUsedFraction, 0), 1)
        return displayMode == .remaining ? 1 - used : used
    }

    func meterTooltip(for state: MeterState) -> String? {
        let lines = [state.tooltip, softLimitStatusText].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    var softLimitReachedUntil: Date? {
        guard let softLimitUsedFraction, let limit, limit > 0, used / limit >= softLimitUsedFraction else { return nil }
        return softLimitReadingExpiresAt
    }

    var softLimitStatusText: String? {
        guard hasData, let limit, limit > 0, let softLimitUsedFraction else { return nil }
        let percent = Int((softLimitUsedFraction * 100).rounded())
        return softLimitReachedUntil != nil
            ? L10n.errors("Soft limit reached at %@%% used", String(percent))
            : L10n.errors("Soft limit at %@%% used", String(percent))
    }
}
