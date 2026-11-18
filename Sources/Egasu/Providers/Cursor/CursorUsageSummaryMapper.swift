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
            ProviderParse.number(plan?[$0]) != nil
        }) {
            return true
        }
        return [individual?["onDemand"], individual?["overall"], team?["onDemand"], team?["pooled"]]
            .contains(where: usableDollarBucket)
    }

    static func hasUsableRequestPayload(_ usage: [String: Any]) -> Bool {
        if let requests = usage["gpt-4"] as? [String: Any],
           let limit = ProviderParse.number(requests["maxRequestUsage"]), limit > 0 {
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
        let cycle = billingCycle(summary: summary, requestUsage: requestUsage)
        var lines: [MetricLine] = []

        let hasRequests = appendRequests(requestUsage, cycle: cycle, to: &lines)
        if !hasRequests {
            appendSummaryTotal(summary, cycle: cycle, to: &lines)
        }
        appendStructuredPercentages(summary, cycle: cycle, to: &lines)
        appendOnDemand(summary, cycle: cycle, to: &lines)

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(
            plan: planLabel(planName) ?? planLabel(summary?["membershipType"] as? String),
            lines: lines
        )
    }

    /// 포함 요청 한도를 Total Usage·Requests 두 지표 행으로 생성하여 저장된 지표 선택을 보존.
    private static func appendRequests(
        _ usage: [String: Any]?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) -> Bool {
        guard let requests = usage?["gpt-4"] as? [String: Any],
              let limit = ProviderParse.number(requests["maxRequestUsage"]),
              limit > 0
        else {
            return false
        }
        let used = max(
            0,
            ProviderParse.number(requests["numRequests"])
                ?? ProviderParse.number(requests["numRequestsTotal"])
                ?? 0
        )
        for label in ["Total usage", "Requests"] {
            lines.append(.progress(
                label: label,
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }
        return true
    }

    /// 유효한 요청 한도가 없을 때 요약 사용량으로 대체.
    /// `limitType`이 `team`이면 유효한 팀 `pooled` 우선. 그 외에는 개인 `plan`, 개인 `overall`, 팀 `pooled` 순으로 선택.
    private static func appendSummaryTotal(
        _ summary: [String: Any]?,
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let individual = summary?["individualUsage"] as? [String: Any]
        let team = summary?["teamUsage"] as? [String: Any]
        let limitType = (summary?["limitType"] as? String)?.lowercased()

        if limitType == "team", let pooled = dollarMeter(team?["pooled"]) {
            appendDollarProgress(pooled, label: "Total usage", cycle: cycle, to: &lines)
            return
        }
        if let percent = ProviderParse.number((individual?["plan"] as? [String: Any])?["totalPercentUsed"]) {
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
        cycle: BillingCycle,
        to lines: inout [MetricLine]
    ) {
        let plan = ((summary?["individualUsage"] as? [String: Any])?["plan"] as? [String: Any])
        for (key, label) in [("autoPercentUsed", "Auto usage"), ("apiPercentUsed", "API usage")] {
            guard let percent = ProviderParse.number(plan?[key]) else { continue }
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
        cycle: BillingCycle,
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
        cycle: BillingCycle,
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
        let inferredUsed = max(0, limit - (ProviderParse.number(bucket["remaining"]) ?? limit))
        let used = reportedUsed.flatMap { $0 > 0 ? $0 : nil } ?? inferredUsed
        return (max(0, used), limit)
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
        cycle: BillingCycle,
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

    private static func billingCycle(
        summary: [String: Any]?,
        requestUsage: [String: Any]?
    ) -> BillingCycle {
        let start = (summary?["billingCycleStart"] as? String).flatMap(EgasuISO8601.date(from:))
        let end = (summary?["billingCycleEnd"] as? String).flatMap(EgasuISO8601.date(from:))
        if let start, let end, end > start {
            return BillingCycle(
                resetsAt: end,
                periodDurationMs: Int(end.timeIntervalSince(start) * 1000)
            )
        }

        let requestStart = (requestUsage?["startOfMonth"] as? String).flatMap(EgasuISO8601.date(from:))
        return BillingCycle(
            resetsAt: requestStart?.addingTimeInterval(TimeInterval(CursorUsageMapper.billingPeriodMs) / 1000),
            periodDurationMs: CursorUsageMapper.billingPeriodMs
        )
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed.titleCased(separator: \.isWhitespace)
    }

    private struct BillingCycle {
        var resetsAt: Date?
        var periodDurationMs: Int
    }
}
