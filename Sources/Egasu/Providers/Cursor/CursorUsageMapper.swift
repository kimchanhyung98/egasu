import Foundation

struct CursorMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

/// Cursor의 untyped `usage` payload에서 3개 plan-usage 결정(map guard, request-based fallback, generic fallback)이 읽는 사실들.
/// 한곳에서 1회 decode — predicate들이 어긋나지 않게 함(과거 두 파일에 같은 검사가 중복).
struct CursorPlanUsageFacts {
    /// `usage.enabled`는 명시적 `false`일 때만 "off" — 부재는 enabled로 해석.
    let isEnabled: Bool
    let hasPlanUsage: Bool
    /// 숫자일 때의 `planUsage.limit`.
    let limit: Double?
    /// 숫자일 때의 `planUsage.totalPercentUsed`.
    let totalPercentUsed: Double?
    /// 소문자화한 `spendLimitUsage.limitType`.
    let spendLimitType: String?
    /// `spendLimitUsage.pooledLimit` (부재 시 0).
    let pooledLimit: Double

    init(usage: [String: Any]) {
        isEnabled = usage["enabled"] as? Bool != false
        let planUsage = usage["planUsage"] as? [String: Any]
        hasPlanUsage = planUsage != nil
        limit = planUsage.flatMap { ProviderParse.number($0["limit"]) }
        totalPercentUsed = planUsage.flatMap { ProviderParse.number($0["totalPercentUsed"]) }
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        spendLimitType = (spendLimitUsage?["limitType"] as? String)?.lowercased()
        pooledLimit = ProviderParse.number(spendLimitUsage?["pooledLimit"]) ?? 0
    }

    var hasLimit: Bool { limit != nil }
    var hasTotalUsagePercent: Bool { totalPercentUsed != nil }
    /// `planUsage`는 있으나 쓸 만한 limit 없음 — fallback들이 기준 삼는 "존재하나 무용" 상태.
    var planUsageLimitMissing: Bool { hasPlanUsage && !hasLimit }
    var planUsageUnusable: Bool { !hasPlanUsage || planUsageLimitMissing }
    /// plan 이름과 무관하게 spend-limit 형태만으로 추론한 team 계정.
    var isTeamByShape: Bool { spendLimitType == "team" || pooledLimit > 0 }
    /// generic request-based fallback 트리거: limit도 total-percent도 없는 `planUsage`를 가진 enabled 계정.
    var shouldTryGenericRequestFallback: Bool {
        isEnabled && hasPlanUsage && !hasLimit && !hasTotalUsagePercent
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

    static func mapUsage(
        usage: [String: Any],
        planName: String?,
        creditGrants: [String: Any]?,
        stripeBalanceCents: Double
    ) throws -> CursorMappedUsage {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled,
              let planUsage = usage["planUsage"] as? [String: Any]
        else {
            throw CursorUsageError.noActiveSubscription
        }

        let normalizedPlan = planName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""

        guard facts.hasLimit || facts.hasTotalUsagePercent else {
            throw CursorUsageError.totalUsageLimitMissing
        }

        var lines: [MetricLine] = []
        appendCredits(creditGrants: creditGrants, stripeBalanceCents: stripeBalanceCents, to: &lines)

        let planUsedCents = ProviderParse.number(planUsage["totalSpend"])
            ?? ((facts.limit ?? 0) - (ProviderParse.number(planUsage["remaining"]) ?? 0))
        let computedPercentUsed = facts.limit.flatMap { limit -> Double? in
            guard limit > 0 else { return nil }
            return planUsedCents / limit * 100
        } ?? 0
        let totalUsagePercent = facts.totalPercentUsed ?? computedPercentUsed

        let cycle = billingCycle(from: usage)
        let spendLimitUsage = usage["spendLimitUsage"] as? [String: Any]
        let isTeamAccount = normalizedPlan == "team" || facts.isTeamByShape

        if isTeamAccount {
            guard let limitCents = facts.limit else {
                throw CursorUsageError.requestBasedUnavailable("Cursor request-based usage data unavailable. Try again later.")
            }
            lines.append(.progress(
                label: "Total usage",
                used: ProviderParse.centsToDollars(planUsedCents),
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        } else {
            lines.append(.progress(
                label: "Total usage",
                used: totalUsagePercent,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let autoPercentUsed = ProviderParse.number(planUsage["autoPercentUsed"]) {
            lines.append(.progress(
                label: "Auto usage",
                used: autoPercentUsed,
                limit: 100,
                format: .percent,
                resetsAt: cycle.resetsAt,
                periodDurationMs: cycle.periodDurationMs
            ))
        }

        if let apiPercentUsed = ProviderParse.number(planUsage["apiPercentUsed"]) {
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
            let remaining = ProviderParse.number(spendLimitUsage["individualRemaining"]) ?? ProviderParse.number(spendLimitUsage["pooledRemaining"]) ?? 0
            let spent = onDemandSpendCents(from: spendLimitUsage, limit: limit, remaining: remaining)
            if limit > 0 {
                lines.append(.progress(
                    label: "On-demand",
                    used: ProviderParse.centsToDollars(spent),
                    limit: ProviderParse.centsToDollars(limit),
                    format: .dollars
                ))
            } else if spent > 0 {
                lines.append(.values(
                    label: "On-demand",
                    values: [MetricValue(number: ProviderParse.centsToDollars(spent), kind: .dollars)]
                ))
            }
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
    }

    private static func onDemandSpendCents(from spendLimitUsage: [String: Any], limit: Double, remaining: Double) -> Double {
        let reported = [
            ProviderParse.number(spendLimitUsage["individualUsed"]),
            ProviderParse.number(spendLimitUsage["pooledUsed"]),
            ProviderParse.number(spendLimitUsage["totalSpend"])
        ].compactMap { $0 }
        if let positive = reported.first(where: { $0 > 0 }) {
            return positive
        }
        let inferred = max(0, limit - remaining)
        return inferred > 0 ? inferred : (reported.first ?? 0)
    }

    static func mapRequestBasedUsage(
        _ usage: [String: Any]?,
        planName: String?,
        unavailableMessage: String
    ) throws -> CursorMappedUsage {
        var lines: [MetricLine] = []
        if let gpt4 = usage?["gpt-4"] as? [String: Any],
           let limit = ProviderParse.number(gpt4["maxRequestUsage"]),
           limit > 0 {
            let used = ProviderParse.number(gpt4["numRequests"]) ?? 0
            let cycleStart = (usage?["startOfMonth"] as? String).flatMap(EgasuISO8601.date(from:))
            lines.append(.progress(
                label: "Requests",
                used: used,
                limit: limit,
                format: .count(suffix: "requests"),
                resetsAt: cycleStart?.addingTimeInterval(TimeInterval(billingPeriodMs) / 1000),
                periodDurationMs: billingPeriodMs
            ))
        }

        guard !lines.isEmpty else {
            throw CursorUsageError.requestBasedUnavailable(unavailableMessage)
        }

        return CursorMappedUsage(plan: planLabel(planName), lines: lines)
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

        if facts.planUsageUnusable && normalizedPlan == "enterprise" {
            return (true, "Enterprise usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && normalizedPlan == "team" {
            return (true, "Team request-based usage data unavailable. Try again later.")
        }
        if facts.planUsageUnusable && !facts.hasTotalUsagePercent && normalizedPlan.isEmpty && planInfoUnavailable {
            return (true, "Cursor request-based usage data unavailable. Try again later.")
        }

        if facts.isTeamByShape && facts.planUsageLimitMissing {
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

    private static func billingCycle(from usage: [String: Any]) -> (resetsAt: Date?, periodDurationMs: Int) {
        let cycleStart = ProviderParse.number(usage["billingCycleStart"])
        let cycleEnd = ProviderParse.number(usage["billingCycleEnd"])
        guard let cycleStart,
              let cycleEnd,
              cycleEnd > cycleStart
        else {
            return (cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) }, billingPeriodMs)
        }
        return (
            Date(timeIntervalSince1970: cycleEnd / 1000),
            Int(cycleEnd - cycleStart)
        )
    }

    private static func planLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.titleCased(separator: \.isWhitespace)
    }
}
