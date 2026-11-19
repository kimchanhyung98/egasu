import Foundation

struct CodexMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
    var incompleteQuotaWindows: Set<SoftLimitWindow>
}

enum CodexUsageMapper {
    static let sessionPeriodMs = MetricPeriod.sessionMs
    static let weeklyPeriodMs = MetricPeriod.weekMs
    /// Codex flex credit 1개당 4¢ — credits line은 dollar 값 선행 (JS plugin의 `CREDIT_USD_RATE` mirror).
    static let creditUSDRate = 0.04

    /// 자동 전송은 기본 버킷의 명시적 7일 윈도와 원본 사용률만 허용. UI 슬롯·헤더 대체값 제외.
    static func weeklyTimerObservation(
        response: HTTPResponse,
        accountKey: String,
        observedAt: Date
    ) -> UsageTimerObservation? {
        timerObservations(response: response, accountKey: accountKey, observedAt: observedAt)
            .first { $0.timerID == "codex.default.weekly" }
    }

    static func timerObservations(
        response: HTTPResponse, accountKey: String, observedAt: Date
    ) -> [UsageTimerObservation] {
        guard (200..<300).contains(response.statusCode),
              let body = ProviderParse.jsonObject(response.body) else { return [] }
        var pools: [(String, [String: Any])] = []
        if let rate = body["rate_limit"] as? [String: Any] { pools.append(("default", rate)) }
        let additional = (body["additional_rate_limits"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
        if let spark = additional.first(where: isSparkEntry), let rate = spark["rate_limit"] as? [String: Any] {
            pools.append(("spark", rate))
        }
        return pools.flatMap { pool, rate in
            [("weekly", 604_800.0), ("session", 18_000.0)].compactMap { period, seconds in
                let windows = ["primary_window", "secondary_window"].compactMap { rate[$0] as? [String: Any] }
                    .filter { ProviderParse.number($0["limit_window_seconds"]) == seconds }
                guard windows.count == 1, let window = windows.first,
                      let used = ProviderParse.number(window["used_percent"]), (0...100).contains(used) else { return nil }
                return UsageTimerObservation(
                    accountKey: accountKey, usedPercent: used, resetsAt: resetDate(window, now: observedAt),
                    observedAt: observedAt, rawResetAt: ProviderParse.number(window["reset_at"]).map { Date(timeIntervalSince1970: $0) },
                    timerID: "codex.\(pool).\(period)", duration: seconds
                )
            }
        }
    }

    static func mapUsageResponse(
        _ response: HTTPResponse,
        resetCredits: HTTPResponse? = nil,
        now: Date = Date()
    ) throws -> CodexMappedUsage {
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: CodexAuthError.tokenExpired,
            requestFailed: { CodexUsageError.requestFailed($0) }
        )

        guard let body = ProviderParse.jsonObject(response.body) else {
            throw CodexUsageError.invalidResponse
        }

        var lines: [MetricLine] = []
        var incompleteWindows: Set<SoftLimitWindow> = []
        let rateLimit = body["rate_limit"]
        lines.append(
            contentsOf: classifiedWindowLines(
                rateLimit: rateLimit,
                labels: (session: "Session", weekly: "Weekly", monthly: "Monthly"),
                headerPercents: (
                    primary: ProviderParse.number(response.header("x-codex-primary-used-percent")),
                    secondary: ProviderParse.number(response.header("x-codex-secondary-used-percent"))
                ),
                now: now, incompleteWindows: &incompleteWindows
            ))

        // Spark는 기본 계정 한도와 별도로 모델별 한도를 제공.
        lines.append(contentsOf: sparkLines(body: body, now: now, incompleteWindows: &incompleteWindows))

        // On-demand reset credit은 Credits 앞에 표시 — count는 raw 전달(menu-bar tile과 동일 숫자), 각 credit의 expiry는 `expiriesAt`로 hover tooltip에 노출.
        if let resets = readResetCredits(body: body, resetCredits: resetCredits) {
            lines.append(.values(
                label: "Rate Limit Resets",
                values: [MetricValue(number: Double(resets.count), kind: .count, label: "available")],
                expiriesAt: resets.expiries
            ))
        }

        if let remaining = readCreditsRemaining(response: response, body: body) {
            lines.append(.values(label: "Credits", values: creditValues(remaining: remaining)))
        }

        // "no usage data" badge는 `CodexProvider.probe`가 스캔된 spend line *뒤에* 추가 — 빈 live 응답의 badge가 Today/Yesterday와 공존 불가.
        return CodexMappedUsage(
            plan: formatCodexPlan(body["plan_type"]), lines: lines, incompleteQuotaWindows: incompleteWindows)
    }

    private static func progress(
        label: String,
        used: Double,
        resetWindow: [String: Any]?,
        now: Date,
        periodDurationMs: Int?
    ) -> MetricLine {
        .progress(
            label: label,
            used: used,
            limit: 100,
            format: .percent,
            resetsAt: resetDate(resetWindow, now: now),
            periodDurationMs: periodDurationMs
        )
    }

    private enum WindowKind {
        case session
        case weekly
        case monthly
    }

    private struct WindowCandidate {
        var window: [String: Any]
        var usedPercent: Double?
        var fallbackKind: WindowKind
    }

    /// 세션·주간·월간 한도를 슬롯 위치와 무관하게 보고된 기간으로 분류.
    /// primary=session / secondary=weekly slot 매핑은 duration을 생략하거나 낯선 값을 쓰는 payload용 호환 fallback.
    private static func classifiedWindowLines(
        rateLimit value: Any?,
        labels: (session: String, weekly: String, monthly: String),
        headerPercents: (primary: Double?, secondary: Double?) = (nil, nil),
        now: Date, incompleteWindows: inout Set<SoftLimitWindow>
    ) -> [MetricLine] {
        let rateLimit = value as? [String: Any]
        if let value, !(value is NSNull), rateLimit == nil {
            incompleteWindows.formUnion(SoftLimitWindow.allCases)
        }
        let candidates = [
            windowCandidate(
                rateLimit?["primary_window"], headerPercent: headerPercents.primary, fallbackKind: .session,
                incompleteWindows: &incompleteWindows),
            windowCandidate(
                rateLimit?["secondary_window"], headerPercent: headerPercents.secondary, fallbackKind: .weekly,
                incompleteWindows: &incompleteWindows)
        ].compactMap { $0 }

        let rows: [(WindowKind, String)] = [
            (.session, labels.session), (.weekly, labels.weekly), (.monthly, labels.monthly)
        ]
        return rows.compactMap { kind, label in
            classifiedWindowLine(
                kind: kind, label: label, candidates: candidates, now: now, incompleteWindows: &incompleteWindows)
        }
    }

    private static func windowCandidate(
        _ value: Any?,
        headerPercent: Double?,
        fallbackKind: WindowKind,
        incompleteWindows: inout Set<SoftLimitWindow>
    ) -> WindowCandidate? {
        let reportedWindow = value as? [String: Any]
        // 손상된 슬롯은 위치만으로 원래의 기간을 특정할 수 없음.
        if let value, !(value is NSNull), readPeriodMs(reportedWindow) == nil {
            incompleteWindows.formUnion(SoftLimitWindow.allCases)
        }
        guard let window = reportedWindow ?? (headerPercent == nil ? nil : [:]) else { return nil }
        return WindowCandidate(
            window: window,
            usedPercent: ProviderParse.number(window["used_percent"]) ?? headerPercent,
            fallbackKind: fallbackKind
        )
    }

    private static func classifiedWindowLine(
        kind: WindowKind,
        label: String,
        candidates: [WindowCandidate],
        now: Date,
        incompleteWindows: inout Set<SoftLimitWindow>
    ) -> MetricLine? {
        let exact = candidates.filter { exactKind(for: $0.window) == kind }
        let fallback = candidates.first { exactKind(for: $0.window) == nil && $0.fallbackKind == kind }
        guard let candidate = exact.first ?? fallback else { return nil }
        // 기간 없는 세션은 기존 5시간 표시를 유지. 헤더 대체값이나 중복된 구간으로 한도 상태를 확정하지 않음.
        var duration = readPeriodMs(candidate.window) ?? (kind == .session ? sessionPeriodMs : nil)
        if kind != .session, !exact.isEmpty {
            let hasReportedUsage =
                ProviderParse.number(candidate.window["used_percent"]).map { (0...100).contains($0) } == true
            let hasUnusableReset = hasMalformedReset(candidate.window) && resetDate(candidate.window, now: now) == nil
            if exact.count != 1 || !hasReportedUsage || hasUnusableReset {
                incompleteWindows.insert(kind == .weekly ? .weekly : .monthly)
                duration = nil
            }
        }
        guard let used = candidate.usedPercent, used >= 0 else { return nil }
        return progress(label: label, used: used, resetWindow: candidate.window, now: now, periodDurationMs: duration)
    }

    private static func exactKind(for window: [String: Any]) -> WindowKind? {
        guard let periodMs = readPeriodMs(window) else { return nil }
        switch periodMs {
        case sessionPeriodMs: return .session
        case weeklyPeriodMs: return .weekly
        default:
            return SoftLimitWindow.monthly.matches(periodDurationMs: periodMs, allowsDSTOffset: false) ? .monthly : nil
        }
    }

    /// Spark 한도의 primary/secondary window도 계정 한도와 같은 기간 규칙 적용.
    /// 비-dictionary·null 요소는 유효한 형제를 버리지 않고 skip; Spark entry 없으면 빈 목록 반환 — 해당 row는 "No data".
    private static func sparkLines(body: [String: Any], now: Date, incompleteWindows: inout Set<SoftLimitWindow>)
        -> [MetricLine]
    {
        guard let rawEntries = body["additional_rate_limits"] as? [Any] else { return [] }
        let entries = rawEntries.compactMap { $0 as? [String: Any] }
        guard let spark = entries.first(where: isSparkEntry) else { return [] }

        return classifiedWindowLines(
            rateLimit: spark["rate_limit"],
            labels: (session: "Spark", weekly: "Spark Weekly", monthly: "Spark Monthly"),
            now: now, incompleteWindows: &incompleteWindows
        )
    }

    /// Spark limit entry 판별 — `limit_name`("GPT-5.3-Codex-Spark") 또는 `metered_feature`를 case-insensitive 매칭, 한쪽 표기 변경에도 해석 유지.
    private static func isSparkEntry(_ entry: [String: Any]) -> Bool {
        [entry["limit_name"], entry["metered_feature"]]
            .compactMap { ($0 as? String)?.lowercased() }
            .contains { $0.contains("spark") }
    }

    private static func hasMalformedReset(_ window: [String: Any]) -> Bool {
        for field in ["reset_at", "reset_after_seconds"] {
            guard let raw = window[field], !(raw is NSNull) else { continue }
            guard let seconds = ProviderParse.number(raw), seconds >= 0 else { return true }
        }
        return false
    }

    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let resetAt = ProviderParse.number(window["reset_at"]), resetAt >= 0 {
            return Date(timeIntervalSince1970: resetAt)
        }
        if let resetAfter = ProviderParse.number(window["reset_after_seconds"]), resetAfter >= 0 {
            return now.addingTimeInterval(resetAfter)
        }
        return nil
    }

    private static func readPeriodMs(_ window: [String: Any]?) -> Int? {
        guard let window else { return nil }
        guard let seconds = ProviderParse.number(window["limit_window_seconds"]),
            seconds > 0, seconds * 1000 < Double(Int.max)
        else { return nil }
        return Int(seconds * 1000)
    }

    /// Flex credit을 raw 값으로 — floored count와 dollar 값(count × 4¢), "$32.84 · 821 credits" 형태로 결합 표시.
    /// count를 pricing *전에* floor — Codex CLI/plugin과 dollar 일치. 음수 잔액은 0으로 clamp — "$0.00 · 0 credits"는 측정된 zero, "No data" 아님.
    static func creditValues(remaining: Double) -> [MetricValue] {
        let credits = max(0, Int(remaining.rounded(.down)))
        let usd = Double(credits) * creditUSDRate
        return [
            MetricValue(number: usd, kind: .dollars),
            MetricValue(number: Double(credits), kind: .count, label: "credits")
        ]
    }

    /// On-demand reset credit — floored available count + still-available credit들의 expiry (soonest-first, hover tooltip용).
    /// per-credit expiry를 유일하게 제공하는 전용 `/rate-limit-reset-credits` payload 우선, 없으면 usage body의 count-only object로 fallback. 비numeric count는 row 전체 skip.
    static func readResetCredits(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> (count: Int, expiries: [Date])? {
        guard let source = resetCreditsSource(body: body, resetCredits: resetCredits),
              let count = ProviderParse.number(source["available_count"]), count >= 0
        else {
            return nil
        }
        return (Int(count.rounded(.down)), availableExpiries(in: source["credits"]))
    }

    /// count·expiry를 읽을 source — 전용 endpoint body가 usable(2xx, 파싱 가능, 0 이상 numeric `available_count`)일 때만 채택, 아니면 usage body의 embedded object.
    /// bare nil-check 금지 — JSON `null`은 `NSNull`(non-nil)이라 unusable한 전용 body를 선택해 usage-body count로의 fallback을 막음.
    private static func resetCreditsSource(
        body: [String: Any],
        resetCredits: HTTPResponse?
    ) -> [String: Any]? {
        if let resetCredits, let dedicated = resetCreditsPayload(resetCredits) {
            return dedicated
        }
        return body["rate_limit_reset_credits"] as? [String: Any]
    }

    static func resetCreditsPayload(_ response: HTTPResponse) -> [String: Any]? {
        guard (200..<300).contains(response.statusCode),
              let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any],
              let count = ProviderParse.number(body["available_count"]), count >= 0
        else { return nil }
        return body
    }

    /// Still-available credit들의 `expires_at` (soonest-first). `status`는 upstream optional — 명시적 non-available("consumed"/"expired")만 제외, status 없는 credit은 유지.
    /// `== "available"` hard filter는 status 생략 응답에서 expiry 목록(tooltip + 24h 경고) 전체를 비움. `expires_at`은 ISO-8601 문자열 또는 epoch 숫자로 파싱.
    private static func availableExpiries(in value: Any?) -> [Date] {
        guard let credits = value as? [[String: Any]] else { return [] }
        return credits
            .filter { credit in
                guard let status = credit["status"] as? String else { return true }
                return status == "available"
            }
            .compactMap { parseExpiry($0["expires_at"]) }
            .sorted()
    }

    private static func parseExpiry(_ value: Any?) -> Date? {
        if let string = value as? String, let date = EgasuISO8601.date(from: string) {
            return date
        }
        if let seconds = ProviderParse.number(value) {
            return Date(timeIntervalSince1970: seconds)
        }
        return nil
    }

    private static func readCreditsRemaining(response: HTTPResponse, body: [String: Any]) -> Double? {
        if let credits = body["credits"] as? [String: Any] {
            if let balance = ProviderParse.number(credits["balance"]) {
                return balance
            }
            if credits["has_credits"] as? Bool == false {
                return 0
            }
        }
        return ProviderParse.number(response.header("x-codex-credits-balance"))
    }

    static func formatCodexPlan(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite":
            return "Pro Lite"
        case "pro":
            return "Pro"
        case "promax":
            return "Pro Max"
        default:
            return raw.titleCased(separator: { $0 == "_" })
        }
    }

}

enum CodexUsageError: Error, LocalizedError, Equatable {
    case requestFailed(Int)
    case invalidResponse
    case connectionFailed

    var errorDescription: String? {
        switch self {
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        }
    }
}
