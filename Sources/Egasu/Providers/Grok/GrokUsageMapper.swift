import Foundation

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
    var metricPresentations: [String: LocalizedMessage] = [:]
}

enum GrokUsageMapper {
    /// 크레딧 청구 응답을 주간 한도와 추가 지출 상태로 변환.
    /// 현재 기간이 주간이 아니면 Weekly 생략. 월간 한도의 주간 오표기 방지.
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        if config.periodType == GrokCreditsConfigDecoder.weeklyPeriodType {
            lines.append(.progress(
                label: "Weekly limit",
                used: ProviderParse.clampPercent(config.usedPercent),
                limit: 100,
                format: .percent,
                resetsAt: config.periodEnd,
                periodDurationMs: config.periodDurationMs
            ))
        }
        // `onDemandCap` 부재는 proto-JSON의 0 생략으로 처리하여 추가 지출 비활성 표시.
        let cap = Formatters.currency(ProviderParse.centsToDollars(config.onDemandCap))
        lines.append(.badge(
            label: "Pay as you go",
            text: config.onDemandCap > 0 ? "\(cap) cap" : "Disabled",
            colorHex: config.onDemandCap > 0 ? "#22c55e" : "#a3a3a3"
        ))
        let presentations: [String: LocalizedMessage] = config.onDemandCap > 0
            ? ["Pay as you go": LocalizedMessage("%@ cap", [cap], table: "Metrics")]
            : [:]
        return GrokMappedUsage(lines: lines, metricPresentations: presentations)
    }

    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body),
              let plan = body["subscription_tier_display"] as? String
        else {
            return nil
        }
        let trimmed = plan.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

}
