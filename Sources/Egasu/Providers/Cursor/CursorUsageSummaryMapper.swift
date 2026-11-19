import Foundation

/// Enterprise·팀 사용량 결합 — 요청 응답의 포함 한도와 요약 응답의 사용률·추가 지출·청구 기간 사용.
enum CursorUsageSummaryMapper {
    static func hasUsableSummaryPayload(_ summary: [String: Any]) -> Bool {
        let start = (summary["billingCycleStart"] as? String).flatMap(EgasuISO8601.date(from:))
        let end = (summary["billingCycleEnd"] as? String).flatMap(EgasuISO8601.date(from:))
        if let start, let end, end > start {
            return true
        }

        let individual = summary["individualUsage"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        if ["totalPercentUsed", "autoPercentUsed", "apiPercentUsed"].contains(where: {
            CursorPlanUsageFacts.percent(plan?[$0]) != nil
        }) {
            return true
        }
        return [individual?["onDemand"], individual?["overall"], team?["onDemand"], team?["pooled"]]
            .contains(where: usableDollarBucket)
    }

    static func hasUsableRequestPayload(_ usage: [String: Any]) -> Bool {
        if CursorUsageMapper.includedRequests(in: usage) != nil {
            return true
        }
        return (usage["startOfMonth"] as? String).flatMap(EgasuISO8601.date(from:)) != nil
    }

    static func map(
        summary: [String: Any]?,
        requestUsage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        let cycle = billingCycle(summary)
        var lines: [MetricLine] = []

        let requests = CursorUsageMapper.includedRequests(in: requestUsage)
        let hasWeeklySummary =
            cycle.periodDurationMs.map { SoftLimitWindow.weekly.matches(periodDurationMs: $0, allowsDSTOffset: true) }
            ?? false
        if requests == nil || hasWeeklySummary {
            appendSummaryTotal(summary, cycle: cycle, to: &lines)
        }
        if let requests {
            let labels = lines.isEmpty ? ["Total usage", "Requests"] : ["Requests"]
            let requestCycle = CursorUsageMapper.requestBillingCycle(requestUsage)
            for label in labels {
                lines.append(
                    .progress(
                        label: label, used: requests.used, limit: requests.limit,
                        format: .count(suffix: "requests"), resetsAt: requestCycle.resetsAt,
                        periodDurationMs: requestCycle.periodDurationMs))
            }
        }
        appendStructuredPercentages(summary, cycle: cycle, to: &lines)
        appendOnDemand(summary, cycle: cycle, to: &lines)

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(
            plan: planLabel(planName) ?? planLabel(summary?["membershipType"] as? String),
            lines: lines,
            incompleteQuotaWindows: incompleteQuotaWindows(summary: summary, requestUsage: requestUsage, cycle: cycle)
        )
    }

    private static func incompleteQuotaWindows(
        summary: [String: Any]?, requestUsage: [String: Any]?, cycle: CursorUsageMapper.BillingCycle
    ) -> Set<SoftLimitWindow> {
        let individual = summary?["individualUsage"] as? [String: Any]
        let plan = individual?["plan"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        let requestMeter = CursorUsageMapper.includedRequests(in: requestUsage)
        let requestPeriod = CursorUsageMapper.requestBillingCycle(requestUsage).periodDurationMs
        let recoversTotal =
            requestMeter != nil && requestPeriod != nil && cycle.possibleSoftLimitWindows.contains(.monthly)
        let hasTotal = CursorPlanUsageFacts.percent(plan?["totalPercentUsed"]) != nil || recoversTotal
        let incompletePool = [individual?["overall"], team?["pooled"]].contains { value in
            guard let bucket = value as? [String: Any], ProviderParse.bool(bucket["enabled"]) != false,
                (ProviderParse.number(bucket["limit"]) ?? 0) > 0
            else { return false }
            return dollarMeter(bucket) == nil
        }
        var windows: Set<SoftLimitWindow> = []
        if incompletePool || !CursorPlanUsageFacts.incompleteQuotaLabels(in: plan, hasTotal: hasTotal).isEmpty {
            windows = cycle.possibleSoftLimitWindows
        }
        let requests = requestUsage?["gpt-4"] as? [String: Any]
        if (ProviderParse.number(requests?["maxRequestUsage"]) ?? 0) > 0,
            requestMeter == nil
        {
            windows.insert(.monthly)
        }
        return windows
    }

    /// 유효한 요청 한도가 없을 때 요약 사용량으로 대체.
    /// `limitType`이 `team`이면 유효한 팀 `pooled` 우선. 그 외에는 개인 `plan`, 개인 `overall`, 팀 `pooled` 순으로 선택.
    private static func appendSummaryTotal(
        _ summary: [String: Any]?,
        cycle: CursorUsageMapper.BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        let limitType = (summary?["limitType"] as? String)?.lowercased()

        if limitType == "team", let pooled = dollarMeter(team?["pooled"]) {
            appendDollarProgress(pooled, label: "Total usage", cycle: cycle, to: &lines)
            return
        }
        if let percent = CursorPlanUsageFacts.percent((individual?["plan"] as? [String: Any])?["totalPercentUsed"]) {
            lines.append(.progress(
                label: "Total usage",
                used: percent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
            return
        }
        if let overall = dollarMeter(individual?["overall"]) {
            appendDollarProgress(overall, label: "Total usage", cycle: cycle, to: &lines)
            return
        }
        if let pooled = dollarMeter(team?["pooled"]) {
            appendDollarProgress(pooled, label: "Total usage", cycle: cycle, to: &lines)
        }
    }

    private static func appendStructuredPercentages(
        _ summary: [String: Any]?,
        cycle: CursorUsageMapper.BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let plan = ((summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])
        for (key, label) in [("autoPercentUsed", "Auto usage"), ("apiPercentUsed", "API usage")] {
            guard let percent = CursorPlanUsageFacts.percent(plan?[key]) else { continue }
            lines.append(.progress(
                label: label,
                used: percent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }
    }

    /// 개인 추가 지출 우선. 표시 가능한 개인 지표가 없을 때만 팀 집계 사용.
    private static func appendOnDemand(
        _ summary: [String: Any]?,
        cycle: CursorUsageMapper.BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        if appendOnDemandBucket(individual?["onDemand"], cycle: cycle, to: &lines) {
            return
        }
        _ = appendOnDemandBucket(team?["onDemand"], cycle: cycle, to: &lines)
    }

    /// 비활성 항목, 유효한 상한과 양수 사용액이 모두 없는 항목은 건너뜀. 지표 추가 여부로 팀 집계 전환 판단.
    private static func appendOnDemandBucket(
        _ value: Any?,
        cycle: CursorUsageMapper.BillingCycle,
        to lines: inout [MetricLine]
    ) -> Bool {
        guard let bucket = value as? [String: Any], bucket["enabled"] as? Bool != false else {
            return false
        }
        if let meter = dollarMeter(bucket) {
            appendDollarProgress(meter, label: "On-demand", cycle: cycle, to: &lines)
            return true
        }
        if let usedCents = ProviderParse.number(bucket["used"]), usedCents > 0 {
            lines.append(.values(
                label: "On-demand",
                values: [MetricValue(number: ProviderParse.centsToDollars(usedCents), kind: .dollars)]
            ))
            return true
        }
        return false
    }

    private static func dollarMeter(_ value: Any?) -> (used: Double, limit: Double)? {
        guard let bucket = value as? [String: Any],
              bucket["enabled"] as? Bool != false,
              let limit = ProviderParse.number(bucket["limit"]),
              limit > 0
        else {
            return nil
        }
        let reportedUsed = ProviderParse.number(bucket["used"])
        if let reportedUsed, reportedUsed > 0 { return (reportedUsed, limit) }
        if let remaining = ProviderParse.number(bucket["remaining"]), remaining >= 0 {
            return (max(0, limit - remaining), limit)
        }
        return reportedUsed == 0 ? (0, limit) : nil
    }

    private static func usableDollarBucket(_ value: Any?) -> Bool {
        guard let bucket = value as? [String: Any], bucket["enabled"] as? Bool != false else {
            return false
        }
        return dollarMeter(bucket) != nil || (ProviderParse.number(bucket["used"]) ?? 0) > 0
    }

    private static func appendDollarProgress(
        _ meter: (used: Double, limit: Double),
        label: String,
        cycle: CursorUsageMapper.BillingCycle,
        to lines: inout [MetricLine]
    ) {
        lines.append(.progress(
            label: label,
            used: ProviderParse.centsToDollars(meter.used),
            limit: ProviderParse.centsToDollars(meter.limit),
            format: .dollars,
            resetsAt: cycle.resetsAt,
            periodDurationMs: cycle.periodDurationMs
        ))
    }

    private static func billingCycle(_ summary: [String: Any]?) -> CursorUsageMapper.BillingCycle {
        let start = (summary?["billingCycleStart"] as? String).flatMap(EgasuISO8601.date(from:))
        let end = (summary?["billingCycleEnd"] as? String).flatMap(EgasuISO8601.date(from:))
        if let start, let end, end > start {
            return CursorUsageMapper.BillingCycle(
                resetsAt: end, periodDurationMs: Int((end.timeIntervalSince(start) * 1000).rounded())
            )
        }

        return CursorUsageMapper.BillingCycle(resetsAt: end)
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.titleCased(separator: \.isWhitespace)
    }
}
