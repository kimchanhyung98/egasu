import Foundation

struct ClaudeMappedUsage: Equatable, Sendable, Codable {
    var plan: String?
    var lines: [MetricLine]
    /// usage에 동반되는 provider header notice(amber 삼각형 + tooltip) — clean fetch면 `nil`.
    var warning: String?
    var warningPresentation: LocalizedMessage?
    var hasIncompleteWeeklyQuota: Bool?
    var liveQuotaObservedAt: Date?
    var quotaObservedAt: Date?
    var retryAfter: Date?
}

enum ClaudeUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs

    static func mapUsageResponse(_ response: HTTPResponse, credentials: ClaudeOAuth, now: Date = Date()) throws -> ClaudeMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: ClaudeAuthError.tokenExpired,
            requestFailed: { ClaudeUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw ClaudeUsageError.invalidResponse
        }
        var lines: [MetricLine] = []
        guard appendUsageWindow(body["five_hour"], label: "Session", periodDurationMs: sessionPeriodMs, to: &lines),
            appendUsageWindow(body["seven_day"], label: "Weekly", periodDurationMs: weeklyPeriodMs, to: &lines)
        else { throw ClaudeUsageError.invalidResponse }

        let sonnetComplete = appendUsageWindow(
            body["seven_day_sonnet"], label: "Sonnet", periodDurationMs: weeklyPeriodMs, to: &lines)
        let fableComplete = appendScopedWeeklyLimit(body["limits"], modelName: "Fable", label: "Fable", to: &lines)
        appendExtraUsage(body["extra_usage"], to: &lines)

        let incomplete = !sonnetComplete || !fableComplete
        let warning = incomplete ? "Some Claude weekly limits are unavailable. Try refreshing again later." : nil
        if incomplete {
            AppLog.warn(LogTag.plugin("claude"), "weekly quota response contained an unreadable model limit")
        }
        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: lines,
            warning: warning,
            warningPresentation: warning.map { .init($0) },
            hasIncompleteWeeklyQuota: incomplete ? true : nil
        )
    }

    /// rate-limit 상태에서 last-good 부재 시의 snapshot — status badge + staleness note, 라이브 바 없음.
    static func rateLimitedUsage(credentials: ClaudeOAuth, retryAfterSeconds: Int?) -> ClaudeMappedUsage {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let waitText = retryText.map { "Rate limited, retry in ~\($0)" } ?? "Rate limited, try again later"
        return ClaudeMappedUsage(
            plan: formatPlan(subscriptionType: credentials.subscriptionType, rateLimitTier: credentials.rateLimitTier),
            lines: [
                .badge(label: "Status", text: waitText, colorHex: "#F59E0B"),
                rateLimitedNote(retryAfterSeconds: retryAfterSeconds)
            ],
            warning: rateLimitedWarning(retryAfterSeconds: retryAfterSeconds),
            warningPresentation: rateLimitedWarningPresentation(retryAfterSeconds: retryAfterSeconds)
        )
    }

    /// rate-limited 상태의 provider header 경고 — badge/note 라인이 레이아웃에 없어도 원인 표시,
    /// 수동 refresh 자제 안내(rate limit 연장 방지).
    static func rateLimitedWarning(retryAfterSeconds: Int?) -> String {
        let base = "Usage updates are rate limited by Anthropic. Automatic and manual refreshes will wait."
        guard let retryText = retryAfterSeconds.map(formatRateLimitMinutes) else { return base }
        return "\(base) Retrying in ~\(retryText)."
    }

    static func rateLimitedWarningPresentation(retryAfterSeconds: Int?) -> LocalizedMessage {
        guard let retryAfterSeconds else {
            return .init("Usage updates are rate limited by Anthropic. Automatic and manual refreshes will wait.")
        }
        guard retryAfterSeconds > 0 else {
            return .init("Usage updates are rate limited by Anthropic. Automatic and manual refreshes will wait. Retrying in ~now.")
        }
        let minutes = Int(ceil(Double(retryAfterSeconds) / 60))
        return .init("Usage updates are rate limited by Anthropic. Automatic and manual refreshes will wait. Retrying in ~%@m.", [String(minutes)])
    }

    /// `user:profile` scope 없는 로그인(inference 전용 토큰)의 header 경고 — 재로그인으로
    /// Session/Weekly 복구 안내; 스캔된 spend 타일은 영향 없음.
    static let missingProfileScopeWarning = "Re-login for live usage. Run `claude` and sign in again to restore session and weekly limits."

    /// last-good snapshot에 덧붙는 rate-limited note(바의 stale 가능성 표시) — `rateLimitedUsage`와 문구 공유.
    static func rateLimitedNote(retryAfterSeconds: Int?) -> MetricLine {
        let retryText = retryAfterSeconds.map(formatRateLimitMinutes)
        let noteText = retryText.map { "Live usage rate limited - retry in ~\($0)" } ?? "Live usage rate limited - data may be stale"
        return .text(label: "Note", value: noteText)
    }

    static func parseRetryAfterSeconds(_ response: HTTPResponse, now: Date = Date()) -> Int? {
        guard let raw = response.header("retry-after")?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        if let seconds = Int(raw), seconds >= 0 {
            return seconds
        }
        if let date = HTTPDateFormatter.date(from: raw) {
            return max(0, Int(ceil(date.timeIntervalSince(now))))
        }
        return nil
    }

    static func formatPlan(subscriptionType: String?, rateLimitTier: String?) -> String? {
        guard let raw = subscriptionType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        let base = raw.titleCased(separator: { $0 == " " }, lowercasingTail: true)
        if base == "Ultra" { return base }

        guard let tier = rateLimitTier?.lowercased(),
              let match = tier.range(of: #"\d+x"#, options: .regularExpression)
        else {
            return base
        }
        let multiplier = String(tier[match])
        if base == "Max" {
            switch multiplier {
            case "5x": return "Max"
            case "20x": return "Ultra"
            default: break
            }
        }
        return "\(base) \(multiplier)"
    }

    /// 미제공 한도는 정상 처리하고, 응답에 있는 한도를 읽을 수 없을 때만 false 반환.
    private static func appendUsageWindow(
        _ value: Any?, label: String, periodDurationMs: Int, valueKey: String = "utilization",
        to lines: inout [MetricLine]
    ) -> Bool {
        guard let value, !(value is NSNull) else { return true }
        guard let object = value as? [String: Any],
            let used = ProviderParse.number(object[valueKey]), used >= 0
        else { return false }
        let reset = object["resets_at"]
        let resetsAt = resetDate(reset)
        if let reset, !(reset is NSNull), resetsAt == nil { return false }
        lines.append(.progress(
                label: label, used: used, limit: 100, format: .percent, resetsAt: resetsAt,
                periodDurationMs: periodDurationMs
        ))
        return true
    }

    /// 모델별 주간 한도는 limits 배열의 모델 이름과 percent 필드로 식별.
    private static func appendScopedWeeklyLimit(
        _ limits: Any?, modelName: String, label: String, to lines: inout [MetricLine]
    ) -> Bool {
        guard let limits, !(limits is NSNull) else { return true }
        guard let entries = limits as? [Any] else { return false }
        var complete = true
        var matched = false
        for entry in entries {
            guard let object = entry as? [String: Any] else {
                complete = false
                continue
            }
            guard object["kind"] as? String == "weekly_scoped" else { continue }
            guard let scope = object["scope"] as? [String: Any], let model = scope["model"] as? [String: Any],
                let name = model["display_name"] as? String, !name.isEmpty
            else {
                complete = false
                continue
            }
            guard name == modelName else { continue }
            guard !matched else {
                complete = false
                continue
            }
            matched = true
            let usable = appendUsageWindow(
                object, label: label, periodDurationMs: weeklyPeriodMs, valueKey: "percent", to: &lines)
            complete = complete && usable
        }
        return complete
    }

    private static func appendExtraUsage(_ value: Any?, to lines: inout [MetricLine]) {
        guard let object = value as? [String: Any],
              object["is_enabled"] as? Bool == true,
              let usedCents = ProviderParse.number(object["used_credits"])
        else {
            return
        }

        let used = ProviderParse.centsToDollars(usedCents)
        if let limitCents = ProviderParse.number(object["monthly_limit"]), limitCents > 0 {
            lines.append(.progress(
                label: "Extra usage spent",
                used: used,
                limit: ProviderParse.centsToDollars(limitCents),
                format: .dollars
            ))
        } else if used > 0 {
            // monthly cap 없음: unbounded spend를 raw로 전달 — `MetricFormatter`의 compact 포맷 적용.
            lines.append(.values(label: "Extra usage spent", values: [MetricValue(number: used, kind: .dollars)]))
        }
    }

    private static func resetDate(_ value: Any?) -> Date? {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let date = EgasuISO8601.date(from: text) {
            return date.timeIntervalSince1970 >= 0 ? date : nil
        }
        guard let number = ProviderParse.number(value), number.isFinite, number >= 0 else {
            return nil
        }
        let milliseconds = number < 1e10 ? number * 1000 : number
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }

    private static func formatRateLimitMinutes(_ seconds: Int) -> String {
        guard seconds > 0 else { return "now" }
        return "\(Int(ceil(Double(seconds) / 60)))m"
    }

}

private enum HTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}
