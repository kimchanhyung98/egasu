import Foundation

/// OpenRouter `/credits`·`/key` 응답을 공통 지표로 변환.
/// 응답을 독립 매핑하여 한쪽 실패에도 다른 쪽 지표 유지.
enum OpenRouterUsageMapper {
    /// 응답의 최상위 `data` 객체 추출.
    static func dataObject(_ body: Data) -> [String: Any]? {
        ProviderParse.jsonObject(body)?["data"] as? [String: Any]
    }

    /// 달러 기준 크레딧 사용량·잔액 생성. 누적 사용액·충전액이 올바르지 않거나 잔액이 유한하지 않으면 빈 배열.
    static func creditsLines(from data: [String: Any]) -> [MetricLine] {
        guard let totalUsage = ProviderParse.number(data["total_usage"]),
              let totalCredits = ProviderParse.number(data["total_credits"]) else { return [] }
        let balance = totalCredits - totalUsage
        guard balance.isFinite else { return [] }

        var lines: [MetricLine] = []
        // 충전액이 양수일 때 사용량 지표 추가. 미충전 계정도 잔액 지표 생성.
        if totalCredits > 0 {
            lines.append(.progress(label: "Credits", used: totalUsage, limit: totalCredits, format: .dollars))
        }
        // 실측 0과 초과 사용에 따른 음수 잔액 모두 유지.
        lines.append(.values(
            label: "Balance",
            values: [MetricValue(number: balance, kind: .dollars)]
        ))
        return lines
    }

    /// 키의 기간별 지출·선택적 상한·요금제 이름 생성.
    static func keyMetrics(
        from data: [String: Any], includePeriodUsage: Bool = true
    ) -> (plan: String?, lines: [MetricLine], hasInvalidKeyLimit: Bool) {
        var lines: [MetricLine] = []
        var hasInvalidKeyLimit = false

        // API가 보고한 기간 지출 사용. 명시적 0은 유지하고 누락 값은 생략.
        if includePeriodUsage {
            appendSpend(data["usage_daily"], label: "Today", into: &lines)
            appendSpend(data["usage_weekly"], label: "This Week", into: &lines)
            appendSpend(data["usage_monthly"], label: "This Month", into: &lines)
        }

        if let limit = ProviderParse.number(data["limit"]), limit > 0 {
            // `usage`는 전체 기간 누적액 — 현재 한도 창의 잔여액으로만 사용량 계산.
            if let remaining = ProviderParse.number(data["limit_remaining"]) {
                lines.append(.progress(
                    label: "Key Limit",
                    used: max(0, limit - max(0, remaining)),
                    limit: limit,
                    format: .dollars
                ))
            } else {
                hasInvalidKeyLimit = true
            }
        }

        let plan = (data["is_free_tier"] as? Bool).map { $0 ? "Free tier" : "Pay as you go" }
        return (plan, lines, hasInvalidKeyLimit)
    }

    private static func appendSpend(_ value: Any?, label: String, into lines: inout [MetricLine]) {
        guard let amount = ProviderParse.number(value) else { return }
        lines.append(.values(label: label, values: [MetricValue(number: max(0, amount), kind: .dollars)]))
    }
}
