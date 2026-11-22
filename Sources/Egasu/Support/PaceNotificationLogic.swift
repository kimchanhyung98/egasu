import Foundation

/// 사용량 알림 — 조건별 설정과 관측 상태로 중복 방지·재알림 제어.
/// Critical·Warning은 Priority 기준(남은 양), Burning Fast는 속도, Use It or Lose It은 초기화 직전 남은 양.
enum PaceMilestone: String, CaseIterable, Hashable, Sendable {
    /// 기존 Almost Out·Cutting It Close의 저장 키를 유지하여 알림 설정 보존.
    case critical = "underTenPercent"
    case warning = "healthyToClose"
    case closeToRunningOut
    case useItOrLoseIt
    case quotaRecovered
}

extension PaceMilestone {
    var settingKey: String { "openusage.notifications.\(rawValue)" }

    /// 속도로 판정하는 알림 — 나머지는 남은 양 기준.
    var isPace: Bool { self == .closeToRunningOut }

    /// Priority 단계 알림 — 두 임계값을 한 번에 지나면 활성화된 조건 중 잔여 비율이 더 낮은 임계값 우선.
    var isLevel: Bool { self == .critical || self == .warning }

    /// Settings 행과 알림 제목 — 누른 알림이 Settings의 한 행으로 이어지게 같은 이름.
    var settingLabel: String {
        switch self {
        case .critical: return L10n.metrics("Critical")
        case .warning: return L10n.metrics("Warning")
        case .closeToRunningOut: return L10n.dashboard("Burning Fast")
        case .quotaRecovered: return L10n.metrics("Quota Available Again")
        case .useItOrLoseIt: return L10n.metrics("Use It or Lose It")
        }
    }

    var notificationTitle: String { settingLabel }

    /// Settings 행 ⓘ 설명.
    var tooltip: String {
        switch self {
        case .critical: return L10n.metrics("Alert when a limit drops critically low")
        case .warning: return L10n.metrics("Alert when a limit requires your attention")
        case .closeToRunningOut: return L10n.metrics("A limit may run out before its reset")
        case .quotaRecovered:
            return L10n.metrics(
                "Notify when fresh Claude, Codex, or Cursor usage confirms the same account has quota again")
        case .useItOrLoseIt: return L10n.metrics("Over 50% left a day before its reset")
        }
    }

    /// 알림 본문 — 부제목이 프로바이더·지표를 실으므로 어떤 지표에도 맞는 일반형.
    func body(_ limits: PriorityLimits) -> String {
        switch self {
        case .critical: return L10n.metrics("%lld%% or less left for this window.", limits.critical)
        case .warning: return L10n.metrics("%lld%% or less left for this window.", limits.warning)
        case .closeToRunningOut: return L10n.metrics("May run out before the limit resets.")
        case .quotaRecovered: return L10n.metrics("This quota is available again.")
        case .useItOrLoseIt: return L10n.metrics("Over 50% left, resets in under 24 hours.")
        }
    }
}

/// `MeterState`에서 파생한 속도 단계 — 믿을 만한 속도가 없으면 `untracked`.
enum PaceBucket: Int, Comparable, Hashable, Sendable {
    case untracked = -1
    case healthy
    case close
    case runningOut

    static func < (lhs: PaceBucket, rhs: PaceBucket) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 지표별 중복 방지 상태 — 갱신 사이에 유지하며 새 주기·상태 회복 시 알림 조건별 재활성화.
struct NotificationState: Equatable, Sendable {
    /// 보낸 기록이 속한 주기의 초기화 시각 — 새 주기로 넘어가면 기록을 비움.
    var resetsAt: Date?
    var firedMilestones: Set<PaceMilestone> = []
    var previousBucket: PaceBucket = .untracked
    var previousSeverity: WidgetData.MeterSeverity = .normal
    var exhaustedAccounts: [QuotaRecoveryScope: String] = [:]
    var positiveUsageObservedAt: Date?
    /// 사용량이 먼저 0으로 돌아온 관측 — 이후 확인한 주기의 시작과 종료를 비교.
    struct Recovery: Equatable, Sendable {
        let lastPositiveAt: Date
        let priorReset: Date
    }
    var pendingRecovery: Recovery?
    /// 첫 실제 관측을 기준선으로 기록했는지 — 실행 직후 이미 나쁜 지표는 알리지 않음.
    var primed: Bool = false
}

/// 순수 알림 판정(SwiftUI·UserNotifications 없음) — 스위치와 무관하게 후보를 내고, 보낼지는 호출자가 결정.
enum PaceNotificationLogic {
    enum WindowChange {
        case unchanged, newWindow, delayedRecovery
    }

    struct Transition: Equatable {
        var fire: [PaceMilestone]
        var newState: NotificationState
    }

    static func bucket(for state: WidgetData.MeterState, used: Double, hasPaceContext: Bool) -> PaceBucket {
        switch state {
        case .noData: return .untracked
        case .level: return used == 0 ? .healthy : .untracked
        case .healthy: return .healthy
        case .closeToLimit: return .close
        case .runningOut: return .runningOut
        case .spent: return hasPaceContext ? .runningOut : .untracked
        }
    }

    /// 이번 평가의 알림 후보와 다음에 이어 갈 상태.
    /// 후보 순서: Burning Fast → Critical → Warning → Use It or Lose It.
    static func transitions(
        state: WidgetData.MeterState,
        severity: WidgetData.MeterSeverity,
        used: Double,
        resetsAt: Date?,
        windowChange: WindowChange,
        hasPaceContext: Bool,
        unusedNearReset: Bool,
        previous: NotificationState,
        now: Date
    ) -> Transition {
        // 데이터 없는 일시 상태는 기록을 건드리지 않음 — 개선·악화로 읽히면 안 됨.
        if state == .noData {
            return Transition(fire: [], newState: previous)
        }
        var next = carriedOver(previous, used: used, resetsAt: resetsAt, change: windowChange, now: now)
        let currentBucket = bucket(for: state, used: used, hasPaceContext: hasPaceContext)

        // 실행 후 첫 관측은 기준선만 — 이미 초기화 직전인 지표는 이번 주기에 보낸 것으로 침.
        if !next.primed {
            next.primed = true
            // 처음부터 소진한 상태는 같은 주기의 기간 정보가 뒤늦게 채워져도 새 악화로 알리지 않음.
            next.previousBucket = state == .spent ? .runningOut : currentBucket
            next.previousSeverity = severity
            next.firedMilestones = unusedNearReset ? [.useItOrLoseIt] : []
            return Transition(fire: [], newState: next)
        }

        var fire: [PaceMilestone] = []
        func candidate(_ milestone: PaceMilestone) {
            if !next.firedMilestones.contains(milestone) { fire.append(milestone) }
        }

        if currentBucket != .untracked {
            if currentBucket >= .runningOut, next.previousBucket < .runningOut { candidate(.closeToRunningOut) }
            // 예상 기말 사용량이 한도의 90% 이하이거나 실제 사용량이 0이면 속도 알림 재활성화.
            if currentBucket == .healthy { next.firedMilestones.remove(.closeToRunningOut) }
            next.previousBucket = currentBucket
        }

        if severity == .critical, next.previousSeverity != .critical { candidate(.critical) }
        if severity != .normal, next.previousSeverity == .normal { candidate(.warning) }
        if severity != .critical { next.firedMilestones.remove(.critical) }
        if severity == .normal { next.firedMilestones.remove(.warning) }
        next.previousSeverity = severity

        if unusedNearReset { candidate(.useItOrLoseIt) }

        return Transition(fire: fire, newState: next)
    }

    static func windowChange(
        from previous: NotificationState, used: Double, resetsAt: Date?, period: TimeInterval?, now: Date
    ) -> WindowChange {
        guard let oldReset = previous.resetsAt, let resetsAt else { return .unchanged }
        if let recovery = previous.pendingRecovery, let period,
            resetsAt.timeIntervalSince(recovery.priorReset) > resetWindowJitterTolerance
        {
            let start = resetsAt.addingTimeInterval(-period)
            if start >= recovery.lastPositiveAt.addingTimeInterval(-resetWindowJitterTolerance),
                start < recovery.priorReset.addingTimeInterval(-resetWindowJitterTolerance),
                start <= now.addingTimeInterval(resetWindowJitterTolerance)
            {
                return .delayedRecovery
            }
        }
        let usageReset = used == 0 && previous.positiveUsageObservedAt != nil
        return resetWindowAdvanced(resetsAt: resetsAt, previousReset: oldReset, now: now, usageReset: usageReset)
            ? .newWindow : .unchanged
    }

    static func carriedOver(
        _ previous: NotificationState, used: Double, resetsAt: Date?, change: WindowChange, now: Date
    ) -> NotificationState {
        var next = previous
        switch change {
        case .newWindow:
            next.firedMilestones = []
            next.previousSeverity = .normal
            next.previousBucket = .untracked
            next.pendingRecovery = nil
        case .delayedRecovery:
            // 0 회복으로 이미 재활성화된 단계·속도 알림은 새 시각 도착 전에 전송됐을 수 있음.
            next.firedMilestones.remove(.useItOrLoseIt)
            next.pendingRecovery = nil
        case .unchanged:
            if used == 0, let positiveAt = previous.positiveUsageObservedAt, let priorReset = previous.resetsAt {
                next.pendingRecovery = .init(lastPositiveAt: positiveAt, priorReset: priorReset)
            }
        }
        next.resetsAt = resetsAt ?? previous.resetsAt
        next.positiveUsageObservedAt = used > 0 ? now : nil
        return next
    }

    static let useItOrLoseItLead: TimeInterval = 24 * 60 * 60

    /// Use It or Lose It — 하루 초과 주기에서 24시간 안에 초기화되고 50% 넘게 남은 한도.
    /// 세션과 달러 상한은 제외 — 지출 상한은 초기화 때 잃는 것이 없음.
    static func isUnusedNearReset(_ data: WidgetData, now: Date) -> Bool {
        guard data.hasData, !data.isForecast, data.kind != .dollars, let resetsAt = data.resetsAt,
              let periodDurationMs = data.periodDurationMs, periodDurationMs > MetricPeriod.dayMs else { return false }
        let untilReset = resetsAt.timeIntervalSince(now)
        return untilReset > 0 && untilReset <= useItOrLoseItLead && Int((data.remainingFraction * 100).rounded()) > 50
    }

    /// 초기화 시각의 프로바이더 쪽 밀리초 흔들림 허용치 — 의미 있는 전진만 새 주기로.
    static let resetWindowJitterTolerance: TimeInterval = 1

    /// 시각만 밀리면 기존 주기 유지. 실제 0 회복과 시각 전진이 함께 관측되면 조기 초기화 허용.
    static func resetWindowAdvanced(resetsAt: Date?, previousReset: Date?, now: Date, usageReset: Bool = false) -> Bool {
        guard let resetsAt else { return false }
        guard let previousReset else { return true }
        return resetsAt.timeIntervalSince(previousReset) > resetWindowJitterTolerance
            && (previousReset <= now || usageReset)
    }
}
