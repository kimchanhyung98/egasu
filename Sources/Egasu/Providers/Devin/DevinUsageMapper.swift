import Foundation

struct DevinMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum DevinUsageMapper {
    static let dayPeriodMs = MetricPeriod.dayMs
    static let weekPeriodMs = MetricPeriod.weekMs

    static func mapUserStatusResponse(_ response: HTTPResponse) throws -> DevinMappedUsage {
        guard let body = ProviderParse.jsonObject(response.body),
              let userStatus = body["userStatus"] as? [String: Any]
        else {
            throw DevinUsageError.invalidResponse
        }
        return try mapUserStatus(userStatus)
    }

    static func mapUserStatus(_ userStatus: [String: Any]) throws -> DevinMappedUsage {
        let planStatus = userStatus["planStatus"] as? [String: Any] ?? [:]
        let planInfo = planStatus["planInfo"] as? [String: Any] ?? [:]
        let plan = readTrimmedString(planInfo["planName"]) ?? "Unknown"
        let hideDailyQuota = ProviderParse.bool(planInfo["hideDailyQuota"]) == true
        let hideWeeklyQuota = ProviderParse.bool(planInfo["hideWeeklyQuota"]) == true

        let dailyRemaining = ProviderParse.number(planStatus["dailyQuotaRemainingPercent"])
        let weeklyRemaining = ProviderParse.number(planStatus["weeklyQuotaRemainingPercent"])
        let dailyReset = hideDailyQuota ? nil : unixSecondsToDate(planStatus["dailyQuotaResetAtUnix"])
        let weeklyReset = unixSecondsToDate(planStatus["weeklyQuotaResetAtUnix"])
        let extraUsageBalance = dollarsFromMicros(planStatus["overageBalanceMicros"])

        var lines: [MetricLine] = []
        if !hideDailyQuota,
           let dailyRemaining {
            lines.append(quotaLine(
                label: "Daily quota",
                remaining: dailyRemaining,
                resetsAt: dailyReset,
                periodDurationMs: dayPeriodMs
            ))
        }

        if !hideWeeklyQuota,
           let weeklyRemaining {
            lines.append(quotaLine(
                label: "Weekly quota",
                remaining: weeklyRemaining,
                resetsAt: weeklyReset,
                periodDurationMs: weekPeriodMs
            ))
        } else if !hideWeeklyQuota, hideDailyQuota,
                  let dailyRemaining {
            // 호환용 주간 행에는 일간 잔여 비율만 있으므로 주간 속도·소프트 한도 계산에서 제외.
            lines.append(quotaLine(
                label: "Weekly quota",
                remaining: dailyRemaining,
                resetsAt: weeklyReset,
                    periodDurationMs: nil
            ))
        }

        if let extraUsageBalance {
            // 숫자는 원값으로 전달. 축약 표시는 `MetricFormatter` 담당.
            lines.append(.values(label: "Extra usage balance", values: [MetricValue(number: extraUsageBalance, kind: .dollars)]))
        }

        guard !lines.isEmpty else {
            throw DevinUsageError.quotaUnavailable
        }

        return DevinMappedUsage(plan: plan, lines: lines)
    }

    /// 잔여 비율을 `100 - remaining`으로 사용 비율로 바꾸고 0…100 범위로 제한.
    private static func quotaLine(label: String, remaining: Double, resetsAt: Date?, periodDurationMs: Int?)
        -> MetricLine
    {
        .progress(
            label: label,
            used: ProviderParse.clampPercent(100 - remaining),
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodDurationMs
        )
    }

    private static func unixSecondsToDate(_ value: Any?) -> Date? {
        guard let seconds = ProviderParse.number(value) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// 마이크로달러 단위의 추가 사용 잔액을 달러로 변환.
    /// 값이 없거나 잘못된 숫자면 nil. 보고된 0은 유지.
    private static func dollarsFromMicros(_ value: Any?) -> Double? {
        guard let micros = ProviderParse.number(value) else { return nil }
        return max(0, micros) / 1_000_000
    }

    private static func readTrimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

enum DevinUsageError: Error, LocalizedError, Equatable {
    case invalidResponse
    case quotaUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidResponse, .quotaUnavailable:
            return "Devin quota data unavailable. Try again later."
        }
    }
}
