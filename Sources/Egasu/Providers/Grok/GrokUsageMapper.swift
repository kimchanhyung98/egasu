import Foundation

struct GrokMappedUsage: Equatable, Sendable {
    var lines: [MetricLine]
    var metricPresentations: [String: LocalizedMessage] = [:]
}

enum GrokUsageMapper {
    /// 크레딧 청구 응답의 기간 단위에 맞는 구독 한도와 추가 지출 상태 생성.
    static func mapCreditsConfig(_ response: HTTPResponse) throws -> GrokMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: GrokAuthError.expired,
            requestFailed: { GrokUsageError.requestFailed($0) }
        )
        let config = try GrokCreditsConfigDecoder.decode(responseBody: response.body)

        var lines: [MetricLine] = []
        let label: String? =
            switch config.periodType {
            case GrokCreditsConfigDecoder.weeklyPeriodType: "Weekly limit"
            case GrokCreditsConfigDecoder.monthlyPeriodType: "Monthly limit"
            default: nil
            }
        if let label {
            lines.append(.progress(
                    label: label,
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

    /// 요금제 이름은 선택 항목. 조회·해석 실패는 사용량과 별도로 기록.
    static func planName(from response: HTTPResponse) -> String? {
        guard (200..<300).contains(response.statusCode) else {
            AppLog.warn(
                LogTag.plugin("grok"),
                "optional plan request failed status=\(response.statusCode) category=\(ErrorCategory.http(response.statusCode).rawValue)"
            )
            return nil
        }
        guard let body = ProviderParse.jsonObject(response.body) else {
            AppLog.warn(LogTag.plugin("grok"), "optional plan response invalid stage=decode category=decoding")
            return nil
        }
        guard let field = body["subscription_tier_display"], !(field is NSNull) else { return nil }
        guard let plan = field as? String else {
            AppLog.warn(LogTag.plugin("grok"), "optional plan response invalid stage=tier_type category=decoding")
            return nil
        }
        return plan.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

}
