import CryptoKit
import Foundation

struct UsageTimerObservation: Equatable, Sendable {
    enum StartRule: Sendable {
        case movingReset, missingReset
    }
    static let resetTimeTolerance: TimeInterval = 60
    static let verificationInterval = resetTimeTolerance + 5

    var accountKey: String
    var usedPercent: Double
    var resetsAt: Date?
    var observedAt: Date
    var rawResetAt: Date? = nil
    var timerID = "codex.default.weekly"
    var duration: TimeInterval = 7 * 24 * 60 * 60
    var startRule: StartRule = .movingReset

    /// 기존 Codex 주간 기록의 해시 입력 유지. 다른 풀·기간은 별도 키 사용.
    var storageKey: String {
        timerID == "codex.default.weekly" ? accountKey : "\(timerID)\u{0}\(accountKey)"
    }

    var budgetWindow: TimeInterval { min(duration, 24 * 60 * 60) }

    func canStart(at date: Date) -> Bool {
        guard usedPercent == 0 else { return false }
        switch startRule {
        case .movingReset: return rawResetAt.map { $0 > date } == true
        case .missingReset: return rawResetAt.map { $0 <= date } ?? true
        }
    }

    static func resetTimesMatch(_ first: Date?, _ second: Date?) -> Bool {
        guard let first, let second else { return false }
        return abs(first.timeIntervalSince(second)) <= resetTimeTolerance
    }

    static func from(
        lines: [MetricLine], label: String = "Session", accountKey: String,
        timerID: String, duration: TimeInterval = 18_000, observedAt: Date,
        startRule: StartRule = .movingReset
    ) -> UsageTimerObservation? {
        guard let line = lines.first(where: { $0.label == label }),
              case .progress(_, let used, let limit, .percent, let reset, let period, _) = line,
              used.isFinite, limit.isFinite, limit > 0, used >= 0, used < limit,
              period == Int(duration * 1000) else { return nil }
        return .init(accountKey: accountKey, usedPercent: used / limit * 100, resetsAt: reset,
                     observedAt: observedAt, rawResetAt: reset, timerID: timerID,
                     duration: duration, startRule: startRule)
    }

    static func accountKey(family: String, identity: String) -> String {
        SHA256.hash(data: Data("\(family)\u{0}\(identity)".utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func hasExhaustedQuota(_ lines: [MetricLine]) -> Bool {
        lines.contains {
            if case .progress(_, let used, let limit, .percent, _, _, _) = $0 { return limit > 0 && used >= limit }
            return false
        }
    }
}

protocol UsageTimerPreparedSession: Sendable {
    var observation: UsageTimerObservation { get }
}

struct UsageTimerExecutionResult: Sendable {
    var launched: Bool
    var completed: Bool
    var failureDescription: String? = nil
    var verificationCanClearFailure = true
}

struct UsageTimerSession: UsageTimerPreparedSession {
    var observation: UsageTimerObservation
    var send: @MainActor @Sendable (@escaping @MainActor () async -> Bool) async -> UsageTimerExecutionResult
    var verify: @MainActor @Sendable () async throws -> UsageTimerObservation?
}

@MainActor
protocol UsageTimerProviding: ProviderRuntime {
    var usageTimerObservations: [UsageTimerObservation] { get }
    func prepareUsageTimer(
        _ observation: UsageTimerObservation, executors: UsageTimerExecutors
    ) async throws -> UsageTimerSession?
}

@MainActor
struct UsageTimerExecutors {
    var codex: any CodexWeeklyTimerExecuting
}
