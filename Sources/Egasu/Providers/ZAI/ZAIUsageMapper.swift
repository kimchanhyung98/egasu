import Foundation

/// Z.ai `/api/monitor/usage/quota/limit` payload와 `/api/biz/subscription/list`의 plan 이름을 metric line으로 매핑.
/// 시간·일·주·월 단위 사용량 창과 웹 검색 횟수 한도 매핑.
/// 두 endpoint 모두 Z.ai 자체 UI가 쓰는 비공개 내부 API — mapper는 순수(I/O 없음)라 sample payload로 테스트 가능.
enum ZAIUsageMapper {
    /// 월간 web-search cycle 1회의 밀리초 (Z.ai 보고값 `unit: 5, number: 1`).
    static let monthlyPeriodMs = MetricPeriod.monthMs

    /// quota + subscription payload에서 `(plan, lines)` 생성.
    /// 구독 응답은 선택 사항. 한도 배열에서 지원하는 지표만 생성.
    static func map(quotaBody: Data, subscriptionBody: Data?) throws -> (plan: String?, lines: [MetricLine]) {
        let lines = try mapQuota(quotaBody)
        let level = (ProviderParse.jsonObject(quotaBody)?["data"] as? [String: Any])?["level"] as? String
        let quotaPlan = level?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map {
            "GLM Coding " + $0.prefix(1).uppercased() + $0.dropFirst().lowercased()
        }
        let plan = subscriptionBody.flatMap { planName(from: $0) } ?? quotaPlan
        return (plan, lines)
    }

    /// 2xx quota body가 "유효 key, GLM Coding Plan 없음" 신호(`{"success":false,…,"msg":"…coding plan"}`)인지 판정.
    /// 구조화된 `success:false`와 메시지의 "coding plan" 문구(localize돼도 ASCII)를 함께 매칭 — 무관한 business 실패의 오탐 방지.
    static func isNoCodingPlan(_ body: Data) -> Bool {
        guard let root = ProviderParse.jsonObject(body),
              (root["success"] as? Bool) == false else { return false }
        return ((root["msg"] as? String) ?? "").lowercased().contains("coding plan")
    }

    /// 응답에 있는 기간별 할당량과 웹 검색 한도 생성.
    /// 필수 값 누락은 0 사용량이 아닌 invalid response — 명시적 빈 배열은 유효한 no-data 상태.
    static func mapQuota(_ body: Data) throws -> [MetricLine] {
        guard let root = ProviderParse.jsonObject(body) else {
            throw ZAIUsageError.invalidResponse
        }
        if let success = root["success"], !(success is NSNull) {
            guard let success = success as? Bool, success else { throw ZAIUsageError.invalidResponse }
        }
        if let code = root["code"], !(code is NSNull) {
            guard let code = ProviderParse.number(code), code == 0 || code == 200 else {
                throw ZAIUsageError.invalidResponse
            }
        }
        // limits 배열은 `data.limits` 하위 — legacy plugin처럼 `data` wrapper 없는 root 직접 형태도 허용
        let container: [String: Any]
        if let data = root["data"] {
            guard let data = data as? [String: Any] else { throw ZAIUsageError.invalidResponse }
            container = data
        } else {
            container = root
        }
        guard let limits = container["limits"] as? [[String: Any]] else {
            throw ZAIUsageError.invalidResponse
        }
        guard !limits.isEmpty else {
            return [.noUsageData]
        }

        var lines: [MetricLine] = []
        var sawRecognizedLimit = false

        // 두 필드 중 하나라도 credit/token quota면 인식 — 기존 name alias 허용 범위 유지.
        let percentageLimits = limits.filter { entry in
            let type = entry["type"] as? String
            let name = entry["name"] as? String
            return type == "CREDIT_LIMIT" || type == "TOKENS_LIMIT"
                || name == "CREDIT_LIMIT" || name == "TOKENS_LIMIT"
        }
        for entry in percentageLimits {
            guard let periodMs = try windowDuration(entry) else { continue }
            let label: String
            if SoftLimitWindow.monthly.matches(periodDurationMs: periodMs, allowsDSTOffset: false) {
                label = "Monthly"
            } else if ProviderParse.number(entry["unit"]) == 5 {
                continue
            } else {
                label = periodMs < MetricPeriod.dayMs ? "Session" : "Weekly"
            }
            sawRecognizedLimit = true
            let line = try percentLine(entry, label: label, periodMs: periodMs)
            if let existing = lines.first(where: { $0.label == line.label }) {
                // 동일 quota의 별칭만 병합 — 서로 다른 quota를 배열 순서로 선택하지 않음.
                guard existing == line else { throw ZAIUsageError.invalidResponse }
                continue
            }
            lines.append(line)
        }
        if let web = findLimit(limits, type: "TIME_LIMIT") {
            sawRecognizedLimit = true
            lines.append(try webSearchLine(from: web))
        }

        guard !lines.isEmpty else {
            if sawRecognizedLimit { throw ZAIUsageError.invalidResponse }
            return [.noUsageData]
        }
        return lines
    }

    /// 첫 구독 항목의 비어 있지 않은 `productName` 추출.
    static func planName(from body: Data) -> String? {
        guard let root = ProviderParse.jsonObject(body),
              let list = root["data"] as? [[String: Any]],
              let first = list.first,
              let name = (first["productName"] as? String)?.nilIfEmpty
        else {
            return nil
        }
        return name
    }

    // MARK: - Private

    /// 시간(3)·일(4)·월(5)·주(6) 단위와 개수를 밀리초로 변환.
    private static func windowDuration(_ entry: [String: Any]) throws -> Int? {
        guard let unit = ProviderParse.number(entry["unit"]),
              let number = ProviderParse.number(entry["number"]),
              number > 0 else {
            throw ZAIUsageError.invalidResponse
        }
        let unitMs: Double
        switch unit {
        case 3: unitMs = 60 * 60 * 1000
        case 4: unitMs = 24 * 60 * 60 * 1000
        case 6: unitMs = 7 * 24 * 60 * 60 * 1000
        case 5: unitMs = Double(monthlyPeriodMs)
        default: return nil
        }
        let duration = unitMs * number
        guard duration >= 1, duration < Double(Int.max) else {
            throw ZAIUsageError.invalidResponse
        }
        return Int(duration)
    }

    /// 크레딧·토큰 할당량을 사용률로 변환.
    private static func percentLine(_ entry: [String: Any], label: String, periodMs: Int) throws -> MetricLine {
        guard let rawPercentage = ProviderParse.number(entry["percentage"]) else {
            throw ZAIUsageError.invalidResponse
        }
        let percentage = ProviderParse.clampPercent(rawPercentage)
        let resetsAt = try resetDate(entry["nextResetTime"])
        return .progress(
            label: label,
            used: percentage,
            limit: 100,
            format: .percent,
            resetsAt: resetsAt,
            periodDurationMs: periodMs
        )
    }

    /// TIME_LIMIT → 월간 web-search/reader 호출의 count meter(used/limit).
    private static func webSearchLine(from entry: [String: Any]) throws -> MetricLine {
        guard let used = ProviderParse.number(entry["currentValue"]),
              let limit = ProviderParse.number(entry["usage"]),
              used >= 0,
              limit >= 0 else {
            throw ZAIUsageError.invalidResponse
        }
        // 기간을 생략한 이전 응답도 사용 횟수와 상한은 표시.
        let resetsAt = try resetDate(entry["nextResetTime"])
        let duration = entry["unit"] == nil && entry["number"] == nil ? nil : try windowDuration(entry)
        return .progress(
            label: "Web Searches",
            used: used,
            limit: limit,
            format: .count(suffix: "searches"),
            resetsAt: resetsAt,
            periodDurationMs: duration
        )
    }

    /// limit entry는 `type` 또는 `name`으로 매칭 — Z.ai payload가 revision에 따라 두 필드를 혼용.
    private static func findLimit(_ limits: [[String: Any]], type: String) -> [String: Any]? {
        for entry in limits {
            if (entry["type"] as? String) == type || (entry["name"] as? String) == type {
                return entry
            }
        }
        return nil
    }

    /// `nextResetTime`은 epoch 밀리초로 도착 (예: `1770648402389`).
    private static func resetDate(_ value: Any?) throws -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let milliseconds = ProviderParse.number(value), milliseconds >= 0 else {
            throw ZAIUsageError.invalidResponse
        }
        return Date(timeIntervalSince1970: milliseconds / 1000)
    }
}
