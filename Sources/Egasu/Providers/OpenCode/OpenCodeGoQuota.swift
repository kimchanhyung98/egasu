import Foundation

/// Go 계정 전체의 서버 사용률. 이 Mac에서 계산한 지출 추정치와 단위가 다름.
struct OpenCodeGoQuota {
    var lines: [MetricLine] = []
    var missingWindows: Set<SoftLimitWindow> = []
    var isIncomplete = false

    static func fetch(key: String, http: any HTTPClient, now: @Sendable () -> Date) async throws -> Self {
        let response = try await http.send(
            HTTPRequest(
                method: "GET", url: URL(string: "https://opencode.ai/zen/go/v1/usage")!,
                headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
                logEndpoint: "opencode.go_usage"))
        guard (200..<300).contains(response.statusCode) else {
            throw OpenCodeUsageError.requestFailed(response.statusCode)
        }
        guard let usage = ProviderParse.jsonObject(response.body)?["usage"] as? [String: Any] else {
            throw OpenCodeUsageError.invalidResponse
        }
        var quota = Self()
        let captured = response.header("date").flatMap(HTTPDateFormatter.date) ?? now()
        for (key, label, duration, window) in [
            ("rolling", "Session", MetricPeriod.sessionMs, nil as SoftLimitWindow?),
            ("weekly", "Weekly", MetricPeriod.weekMs, .weekly),
            ("monthly", "Monthly", MetricPeriod.monthMs, .monthly)
        ] {
            guard let value = usage[key] as? [String: Any],
                let percent = ProviderParse.number(value["percent"]), (0...100).contains(percent),
                let rawReset = value["resetsAt"] as? String, let reset = EgasuISO8601.date(from: rawReset)
            else {
                quota.isIncomplete = true
                if let window { quota.missingWindows.insert(window) }
                continue
            }
            // 미시작 세션은 조회할 때마다 지금부터 5시간 뒤를 반환.
            let placeholder =
                window == nil && percent == 0 && abs(reset.timeIntervalSince(captured) - Double(duration) / 1_000) <= 2
            quota.lines.append(
                .progress(
                    label: label, used: percent, limit: 100, format: .percent,
                    resetsAt: placeholder ? nil : reset, periodDurationMs: duration))
        }
        guard !quota.lines.isEmpty else { throw OpenCodeUsageError.invalidResponse }
        return quota
    }
}
