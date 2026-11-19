import Foundation

struct CursorMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    var incompleteQuotaWindows: Set<SoftLimitWindow> = []
}

/// Cursor의 untyped `usage` payload에서 3개 plan-usage 결정(map guard, request-based fallback, generic fallback)이 읽는 사실들.
/// 한곳에서 1회 decode — predicate들이 어긋나지 않게 함(과거 두 파일에 같은 검사가 중복).
struct CursorPlanUsageFacts {
    /// `usage.enabled`는 명시적 `false`일 때만 "off" — 부재는 enabled로 해석.
    let isEnabled: Bool
    let hasPlanUsage: Bool
    /// 숫자일 때의 `planUsage.limit`.
    let limit: Double?
    let usedCents: Double?
    /// 직접 보고한 사용률 우선. 없으면 같은 응답의 사용량·한도로 산출.
    let totalPercentUsed: Double?
    let autoPercentUsed: Double?
    let apiPercentUsed: Double?
    let incompleteQuotaLabels: Set<String>
    /// 소문자화한 `spendLimitUsage.limitType`.
    let spendLimitType: String?
    /// `spendLimitUsage.pooledLimit` (부재 시 0).
    let pooledLimit: Double

    init(usage: [String: Any]) {
        isEnabled = usage["enabled"] as? Bool != false
        let planUsage = usage["planUsage"] as? [String: Any]
        hasPlanUsage = planUsage != nil
        let reportedLimit = ProviderParse.number(planUsage?["limit"])
        limit = reportedLimit.flatMap { $0 > 0 ? $0 : nil }
        if let spent = ProviderParse.number(planUsage?["totalSpend"]), spent >= 0 {
            usedCents = spent
        } else if let limit, let remaining = ProviderParse.number(planUsage?["remaining"]), remaining >= 0 {
            usedCents = max(0, limit - remaining)
        } else {
            usedCents = nil
        }
        if let percent = Self.percent(planUsage?["totalPercentUsed"]) {
            totalPercentUsed = percent
        } else if let usedCents, let limit {
            let percent = usedCents / limit * 100
            totalPercentUsed = percent.isFinite ? percent : nil
        } else {
            totalPercentUsed = nil
        }
        autoPercentUsed = Self.percent(planUsage?["autoPercentUsed"])
        apiPercentUsed = Self.percent(planUsage?["apiPercentUsed"])
        incompleteQuotaLabels = Self.incompleteQuotaLabels(in: planUsage, hasTotal: totalPercentUsed != nil)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        spendLimitType = (spendLimitUsage?["limitType"] as? String)?.lowercased()
        pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
    }

    static func percent(_ value: Any?) -> Double? {
        guard let percent = ProviderParse.number(value), percent >= 0 else { return nil }
        return percent
    }

    static func incompleteQuotaLabels(in plan: [String: Any]?, hasTotal: Bool) -> Set<String> {
        guard let plan, ProviderParse.bool(plan["enabled"]) != false else { return [] }
        var labels: Set<String> = []
        if !hasTotal, (ProviderParse.number(plan["limit"]) ?? 0) > 0 { labels.insert("Total usage") }
        for (key, label) in [
            ("totalPercentUsed", "Total usage"), ("autoPercentUsed", "Auto usage"), ("apiPercentUsed", "API usage")
        ] {
            guard let value = plan[key], !(value is NSNull), percent(value) == nil else { continue }
            if label != "Total usage" || !hasTotal { labels.insert(label) }
        }
        return labels
    }

    var hasUsageMeter: Bool {
        totalPercentUsed != nil || autoPercentUsed != nil || apiPercentUsed != nil
    }
    /// plan 이름과 무관하게 spend-limit 형태만으로 추론한 team 계정.
    var isTeamByShape: Bool { spendLimitType == "team" || pooledLimit > 0 }
    var shouldTryGenericRequestFallback: Bool {
        isEnabled && hasPlanUsage && !hasUsageMeter
    }
}

enum CursorUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    case usageAfterRefreshFailed
    case requestBasedUnavailable(String)
    case totalUsageLimitMissing
    case noActiveSubscription

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .usageAfterRefreshFailed:
            return "Usage request failed after refresh. Try again."
        case .requestBasedUnavailable(let message):
            return message
        case .totalUsageLimitMissing:
            return "Total usage limit missing from API response."
        case .noActiveSubscription:
            return "No active Cursor subscription."
        }
    }
}

enum CursorUsageMapper {
    static let billingPeriodMs = MetricPeriod.monthMs

    struct BillingCycle {
        var resetsAt: Date?
        var periodDurationMs: Int?

        var possibleSoftLimitWindows: Set<SoftLimitWindow> {
            guard let periodDurationMs else { return Set(SoftLimitWindow.allCases) }
            return Set(SoftLimitWindow.allCases.filter { $0.matches(periodDurationMs: periodDurationMs) })
        }
    }

    /// 이전 요청 기반 요금제는 시작 시각에서 UTC 달력의 한 달 뒤에 갱신.
    static func requestBillingCycle(_ usage: [String: Any]?) -> BillingCycle {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        guard let start = (usage?["startOfMonth"] as? String).flatMap(EgasuISO8601.date(from:)),
            let end = calendar.date(byAdding: .month, value: 1, to: start)
        else { return BillingCycle() }
        return BillingCycle(resetsAt: end, periodDurationMs: Int((end.timeIntervalSince(start) * 1000).rounded()))
    }

    static func mapUsage(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> CursorMappedUsage {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled, facts.hasPlanUsage else {
            throw CursorUsageError.noActiveSubscription
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let cycle = billingCycle(from: usage)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let isTeamAccount = normalizedPlan == "team" || facts.isTeamByShape

        if isTeamAccount, let limitCents = facts.limit, let planUsedCents = facts.usedCents {
            lines.append(.progress(
                label: "Total usage",
                used: ProviderParse.centsToDollars(planUsedCents),
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        } else if let totalUsagePercent = facts.totalPercentUsed {
            lines.append(.progress(
                label: "Total usage",
                used: totalUsagePercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let autoPercentUsed = facts.autoPercentUsed {
            lines.append(.progress(
                label: "Auto usage",
                used: autoPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let apiPercentUsed = facts.apiPercentUsed {
            lines.append(.progress(
                label: "API usage",
                used: apiPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let spendLimitUsage {
            let limit = ProviderParse.number(spendLimitUsage["individualLimit"]) ?? ProviderParse.number(spendLimitUsage["pooledLimit"]) ?? 0
            let remaining =
                ProviderParse.number(spendLimitUsage["individualRemaining"])
                ?? ProviderParse.number(spendLimitUsage["pooledRemaining"])
            let spent = onDemandSpendCents(from: spendLimitUsage, limit: limit, remaining: remaining)
            if let spent, limit > 0 {
                lines.append(.progress(
                    label: "On-demand",
                    used: ProviderParse.centsToDollars(spent),
                    limit: ProviderParse.centsToDollars(limit),
                    format: .dollars
                ))
            } else if let spent, spent > 0 {
                lines.append(.values(
                    label: "On-demand",
                    values: [MetricValue(number: ProviderParse.centsToDollars(spent), kind: .dollars)]
                ))
            }
        }

        guard !lines.isEmpty else {
            throw facts.limit == nil ? CursorUsageError.totalUsageLimitMissing : CursorUsageError.invalidResponse
        }
        return CursorMappedUsage(
            plan: planLabel(planName), lines: lines,
            incompleteQuotaWindows: facts.incompleteQuotaLabels.isEmpty ? [] : cycle.possibleSoftLimitWindows
        )
    }

    private static func onDemandSpendCents(from spendLimitUsage: [String: Any], limit: Double, remaining: Double?)
        -> Double?
    {
        let reported = [
            ProviderParse.number(spendLimitUsage["individualUsed"]),
            ProviderParse.number(spendLimitUsage["pooledUsed"]),
            ProviderParse.number(spendLimitUsage["totalSpend"])
        ].compactMap { $0 }
        if let positive = reported.first(where: { $0 > 0 }) {
            return positive
        }
        if let remaining, remaining >= 0, limit > 0 { return max(0, limit - remaining) }
        return reported.first { $0 == 0 }
    }

    static func mapRequestBasedUsage(
        _ usage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        var lines: [MetricLine] = []
        if let (used, limit) = includedRequests(in: usage) {
            let cycle = requestBillingCycle(usage)
            lines.append(.progress(
                label: "Requests",
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                    resetsAt: cycle.resetsAt,
                    periodDurationMs: cycle.periodDurationMs
            ))
        }

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    static func includedRequests(in usage: [String: Any]?) -> (used: Double, limit: Double)? {
        guard let requests = usage?["gpt-4"] as? [String: Any],
            let limit = ProviderParse.number(requests["maxRequestUsage"]), limit > 0,
            let used = ProviderParse.number(requests["numRequests"])
                ?? ProviderParse.number(requests["numRequestsTotal"]),
            used >= 0
        else { return nil }
        return (used, limit)
    }

    /// 대체 응답에서 같은 기간·지표를 복구한 경우에만 기본 응답의 판정 보류 해제.
    static func includeUnresolvedPlanQuota(from usage: [String: Any], in fallback: inout CursorMappedUsage) {
        let labels = CursorPlanUsageFacts(usage: usage).incompleteQuotaLabels
        guard !labels.isEmpty else { return }
        let cycle = billingCycle(from: usage)
        for label in labels {
            let recovered = fallback.lines.contains { line in
                guard case let .progress(name, _, _, _, _, duration?, _) = line,
                    name == label || (name == "Requests" && label == "Total usage")
                else { return false }
                return cycle.possibleSoftLimitWindows.contains { $0.matches(periodDurationMs: duration) }
            }
            if !recovered {
                fallback.incompleteQuotaWindows.formUnion(cycle.possibleSoftLimitWindows)
                return
            }
        }
    }

    static func shouldUseRequestBasedFallback(
        usage: [String: Any],
        planName: String?,
        planInfoUnavailable: Bool
    ) -> (shouldFallback: Bool, message: String) {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled else {
            return (false, "")
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        let needsPlanFallback = facts.limit == nil || !facts.hasUsageMeter
        if needsPlanFallback && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if needsPlanFallback && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if !facts.hasUsageMeter && normalizedPlan.isEmpty && planInfoUnavailable {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        if facts.isTeamByShape && facts.hasPlanUsage && needsPlanFallback {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        return (false, "")
    }

    /// 서버 보고 비용을 일별로 합산. 별칭은 모델 표시를 묶는 용도로만 사용.
    static func appendSpendLines(
        rows: [CursorUsageEvent],
        now: Date,
        pricing: ModelPricing,
        to lines: inout [MetricLine]
    ) -> ProviderUsageHistory {
        let calendar = Calendar.current
        var costByDay: [String: UsageCostTotal] = [:]
        var tokensByDay: [String: Int] = [:]
        var modelsByDay: [String: [String: ModelAccumulator]] = [:]
        for row in rows where row.costUSD > 0 || row.tokens.totalTokens > 0 {
            let day = DailyUsageAccumulator.dayKey(from: row.date, calendar: calendar)
            let model = row.model.trimmingCharacters(in: .whitespacesAndNewlines)
            costByDay[day, default: UsageCostTotal()].add(row.costUSD)
            tokensByDay[day, default: 0] += row.tokens.totalTokens
            let modelName = model.isEmpty ? ModelUsageEntry.unattributedModelName : model
            let family = model.isEmpty ? modelName : familyName(for: model, pricing: pricing)
            modelsByDay[day, default: [:]][family, default: ModelAccumulator()].add(
                variant: modelName,
                tokens: row.tokens.totalTokens,
                costUSD: row.costUSD
            )
        }

        // 원본 소수 비용을 유지하고 기간·모델 표시 경계에서 한 번만 반올림.
        let daily = tokensByDay.keys.sorted(by: >).map { day in
            DailyUsageEntry(
                date: day,
                totalTokens: tokensByDay[day] ?? 0,
                costUSD: costByDay[day]?.value
            )
        }
        let series = DailyUsageSeries(daily: daily)
        let modelUsage = ModelUsageSeries(daily: modelsByDay.keys.sorted(by: >).map { day in
            DailyModelUsageEntry(
                date: day,
                models: modelsByDay[day, default: [:]].map { model, accumulator in
                    accumulator.entry(model: model)
                }
            )
        })
        SpendTileMapper.appendTokenUsage(
            series, to: &lines, now: now, estimated: false,
            modelUsage: modelUsage,
            modelSourceNote: WidgetData.cursorUsageHistoryNote)
        SpendTileMapper.appendUsageTrend(series, to: &lines, now: now, note: WidgetData.cursorUsageHistoryNote)
        return ProviderUsageHistory(
            series: series,
            modelUsage: modelUsage,
            estimatedCost: false
        )
    }

    /// Cursor 별칭을 우선해 표시 family 결정 — 공급 경로 접두사 제거, Fast는 기본 모델에 합산, 미등록 이름은 원문 유지.
    private static func familyName(for model: String, pricing: ModelPricing) -> String {
        var canonical = pricing.supplement.canonicalName(for: "cursor/" + model)
            ?? pricing.supplement.canonicalName(for: model) ?? model
        if canonical.hasPrefix("cursor/") {
            canonical = String(canonical.dropFirst("cursor/".count))
        }
        if canonical.hasPrefix("gemini/") {
            canonical = String(canonical.dropFirst("gemini/".count))
        }
        if canonical.hasPrefix("fireworks_ai/accounts/fireworks/routers/") {
            canonical = String(canonical.dropFirst("fireworks_ai/accounts/fireworks/routers/".count))
        }
        guard canonical.hasSuffix("-fast") else { return canonical }
        let base = String(canonical.dropLast("-fast".count))
        return base.isEmpty ? canonical : base
    }

    private struct ModelAccumulator {
        var tokens = 0
        var cost = UsageCostTotal()
        var variants: [String: (tokens: Int, cost: UsageCostTotal)] = [:]

        mutating func add(variant: String, tokens: Int, costUSD: Double?) {
            self.tokens += tokens
            cost.add(costUSD)
            var existing = variants[variant] ?? (0, UsageCostTotal())
            existing.tokens += tokens
            existing.cost.add(costUSD)
            variants[variant] = existing
        }

        func entry(model: String) -> ModelUsageEntry {
            // family 자신의 이름을 가진 단일 variant는 breakdown이 아님 — `variants`를 nil로 두어 hover tooltip이 수치만 표시.
            let list = variants.map { ModelUsageVariant(model: $0.key, totalTokens: $0.value.tokens, costUSD: $0.value.cost.value) }
            let isTrivial = list.count == 1 && list[0].model == model
            return ModelUsageEntry(model: model, totalTokens: tokens, costUSD: cost.value,
                                   variants: isTrivial ? nil : list)
        }
    }

    static func stripeBalanceCents(from body: [String: Any]?) -> Double {
        guard let body,
              let balance = ProviderParse.number(body["customerBalance"]),
              balance < 0
        else {
            return 0
        }
        return abs(balance)
    }

    private static func appendCredits(creditGrants: [String: Any]?, stripeBalanceCents: Double, to lines: inout [MetricLine]) {
        let hasCreditGrants = creditGrants?["hasCreditGrants"] as? Bool == true
        let grantTotalCents = hasCreditGrants ? ProviderParse.number(creditGrants?["totalCents"]) ?? 0 : 0
        let grantUsedCents = hasCreditGrants ? ProviderParse.number(creditGrants?["usedCents"]) ?? 0 : 0
        let hasValidGrantData = hasCreditGrants && grantTotalCents > 0
        let combinedTotalCents = (hasValidGrantData ? grantTotalCents : 0) + stripeBalanceCents
        let remainingCents = max(0, combinedTotalCents - (hasValidGrantData ? grantUsedCents : 0))

        guard combinedTotalCents > 0 else { return }
        lines.append(.values(
            label: "Credits",
            values: [MetricValue(number: ProviderParse.centsToDollars(remainingCents), kind: .dollars)]
        ))
    }

    private static func billingCycle(from usage: [String: Any]) -> BillingCycle {
        let cycleStart = ProviderParse.number(usage["billingCycleStart"])
        let cycleEnd = ProviderParse.number(usage["billingCycleEnd"])
        let end = cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }
        guard let cycleStart,
              let cycleEnd,
            cycleEnd > cycleStart, cycleEnd - cycleStart < Double(Int.max)
        else {
            return BillingCycle(resetsAt: end)
        }
        return BillingCycle(resetsAt: end, periodDurationMs: Int((cycleEnd - cycleStart).rounded()))
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}
