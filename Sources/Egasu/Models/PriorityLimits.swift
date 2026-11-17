import Foundation

/// 남은 비율(%)이 이 값 이하이면 Warning(주황)·Critical(빨강).
/// Critical은 항상 Warning보다 아래 — 한쪽을 겹치게 옮기면 다른 쪽이 한 단계 밀림.
struct PriorityLimits: Hashable, Sendable {
    static let step = 5
    static let warningRange = 20...70
    static let criticalRange = 5...25
    static let standard = PriorityLimits(warning: 30, critical: 10)

    static let warningOptions = Array(
        stride(from: warningRange.upperBound, through: warningRange.lowerBound, by: -step))
    static let criticalOptions = Array(
        stride(from: criticalRange.upperBound, through: criticalRange.lowerBound, by: -step))

    var warning: Int {
        didSet { if critical >= warning { critical = warning - Self.step } }
    }

    var critical: Int {
        didSet { if warning <= critical { warning = critical + Self.step } }
    }

    init(warning: Int, critical: Int) {
        self.warning = Self.snapped(warning, to: Self.warningRange)
        self.critical = min(Self.snapped(critical, to: Self.criticalRange), self.warning - Self.step)
    }

    private static func snapped(_ value: Int, to range: ClosedRange<Int>) -> Int {
        let stepped = Int((Double(value) / Double(step)).rounded()) * step
        return min(max(stepped, range.lowerBound), range.upperBound)
    }
}
