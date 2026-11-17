import Foundation

// MARK: - Severity · runway · pace mark

extension WidgetData {
    /// 막대 색·Priority 소진 임박 판정 — 남은 비율(반올림 %)만 사용, 시간 무관.
    /// Reset Watch 예측 행은 한도가 아니므로 normal.
    var severity: MeterSeverity {
        guard hasData, !isForecast, let limit, limit > 0 else { return .normal }
        let percentLeft = Int((remainingFraction * 100).rounded())
        if percentLeft <= priorityLimits.critical { return .critical }
        return percentLeft <= priorityLimits.warning ? .warning : .normal
    }

    /// 막대·링 채움 색 — Reset Watch는 확률 구간 색(40% 미만 회색, 40~59 파랑, 60~69 주황, 70+ 빨강).
    var fillSeverity: MeterSeverity {
        guard isForecast else { return severity }
        guard hasData, let limit, limit > 0 else { return .neutral }
        let percent = (min(max(used / limit, 0), 1) * 100).rounded()
        if percent >= 70 { return .critical }
        if percent >= 60 { return .warning }
        if percent >= 40 { return .normal }
        return .neutral
    }

    /// 막대 호버 툴팁 — 초기화 시점의 예상 사용량.
    func paceTooltip(now: Date = Date()) -> String? {
        guard !isForecast else { return nil }
        return meterState(now: now).tooltip
    }

    /// 현재 속도로 한도까지 남은 시간 — 속도를 판정할 수 없으면 nil.
    func runway(now: Date = Date()) -> TimeInterval? {
        guard let ctx = paceContext, !isFreshSessionWindow(now: now),
            let result = Pace.evaluate(
                used: used, limit: ctx.limit, resetsAt: ctx.resetsAt,
                periodDuration: ctx.period, now: now)
        else { return nil }
        // 초반 정수 백분율의 거친 값으로 잘못 예측하지 않도록 사용량 5% 미만은 제외.
        guard result.status == .ahead || used / ctx.limit >= 0.05 else { return nil }
        let projectedFraction = result.projectedUsage / ctx.limit
        guard projectedFraction > 0 else { return nil }
        return max(0, 1 - used / ctx.limit) * ctx.period / projectedFraction
    }

    /// 고른 속도라면 지금 도달했을 막대 위치(0…1) — Pace Marks가 켜져 있고 남은 양이 있을 때만.
    func paceMark(now: Date = Date()) -> Double? {
        guard showsPaceMarks, let ctx = paceContext, !isFreshSessionWindow(now: now) else { return nil }
        if case .spent = meterState(now: now) { return nil }
        let windowStart = ctx.resetsAt.addingTimeInterval(-ctx.period)
        let elapsed = now.timeIntervalSince(windowStart)
        guard elapsed >= Pace.minimumElapsed(periodDuration: ctx.period), now < ctx.resetsAt else { return nil }
        let share = min(max(elapsed / ctx.period, 0), 1)
        return displayMode == .remaining ? 1 - share : share
    }
}
