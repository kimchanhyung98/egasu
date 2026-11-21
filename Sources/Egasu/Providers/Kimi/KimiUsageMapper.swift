import Foundation

struct KimiMappedUsage: Equatable, Sendable {
    var plan: String?
    var lines: [MetricLine]
}

enum KimiUsageMapper {
    static let sessionPeriodMs = 5 * 60 * 60 * 1000
    static let weeklyPeriodMs = 7 * 24 * 60 * 60 * 1000
    private static let planNamesByLevel = [
        "LEVEL_FREE": "Adagio",
        "LEVEL_BASIC": "Moderato",
        "LEVEL_INTERMEDIATE": "Allegretto",
        "LEVEL_ADVANCED": "Allegro",
        "LEVEL_STANDARD": "Vivace"
    ]

    static func map(_ data: Data) throws -> KimiMappedUsage {
        guard let root = ProviderParse.jsonObject(data) else {
            throw KimiUsageError.invalidResponse
        }
        return try map(root)
    }

    static func map(_ root: [String: Any]) throws -> KimiMappedUsage {
        let lines = try quotaLines(root) + extraUsageLines(root)
        guard !lines.isEmpty else { throw KimiUsageError.quotaUnavailable }
        return KimiMappedUsage(plan: plan(root), lines: lines)
    }

    private static func quotaLines(_ root: [String: Any]) throws -> [MetricLine] {
        if let value = root["usages"] {
            guard let usages = value as? [String: Any] else { throw KimiUsageError.invalidResponse }
            var lines: [MetricLine] = []
            let windows: [(String, String, Int?)] = [
                ("limit_5h", "Session", sessionPeriodMs),
                ("limit_7d", "Weekly", weeklyPeriodMs),
                ("limit_month_total", "Total Usage", nil)
            ]
            for (key, label, duration) in windows {
                guard let value = usages[key], !(value is NSNull) else { continue }
                let quota = try currentQuota(value)
                lines.append(.progress(
                    label: label, used: quota.used, limit: 100, format: .percent,
                    resetsAt: quota.reset,
                    periodDurationMs: duration
                ))
            }
            return lines
        }
        var lines: [MetricLine] = []

        if let limitsValue = root["limits"] {
            guard let limits = limitsValue as? [Any] else {
                throw KimiUsageError.invalidResponse
            }
            var sessionLine: MetricLine?
            for value in limits {
                guard let entry = value as? [String: Any] else {
                    throw KimiUsageError.invalidResponse
                }
                guard try windowDurationMs(entry["window"]) == sessionPeriodMs else { continue }
                guard sessionLine == nil else { throw KimiUsageError.invalidResponse }
                let detail: [String: Any]
                if let rawDetail = entry["detail"] {
                    guard let parsed = rawDetail as? [String: Any] else {
                        throw KimiUsageError.invalidResponse
                    }
                    detail = parsed
                } else {
                    detail = entry
                }
                sessionLine = try quotaLine(detail, label: "Session", periodDurationMs: sessionPeriodMs)
            }
            if let sessionLine { lines.append(sessionLine) }
        }

        if let usageValue = root["usage"] {
            guard let usage = usageValue as? [String: Any] else {
                throw KimiUsageError.invalidResponse
            }
            lines.append(try quotaLine(usage, label: "Weekly", periodDurationMs: weeklyPeriodMs))
        }

        return lines
    }

    private static func currentQuota(_ value: Any) throws -> (used: Double, reset: Date?) {
        guard let quota = value as? [String: Any],
              let ratio = ProviderParse.number(quota["used_ratio"]), ratio >= 0,
              (ratio * 100).isFinite else { throw KimiUsageError.invalidResponse }
        return (ratio * 100, (quota["reset_time"] as? String).flatMap(EgasuISO8601.date(from:)))
    }

    private static func extraUsageLines(_ root: [String: Any]) throws -> [MetricLine] {
        guard let value = root["booster_wallet"] ?? root["boosterWallet"], !(value is NSNull) else { return [] }
        guard let wallet = value as? [String: Any] else { throw KimiUsageError.invalidResponse }
        guard let rawBalance = wallet["balance"], !(rawBalance is NSNull) else { return [] }
        guard let balance = rawBalance as? [String: Any], let type = balance["type"] as? String else {
            throw KimiUsageError.invalidResponse
        }
        guard type == "BOOSTER" else { return [] }

        // 미충전 BOOSTER 지갑은 amountLeft를 생략. 지갑 자체가 없는 응답과 구분해 0 잔액 유지.
        let available = try walletInteger(balance["amountLeft"], allowsNegative: true) / 100_000_000
        let used = try walletMoney(wallet["monthlyUsed"])
        let cap = try walletMoney(wallet["monthlyChargeLimit"])
        if let usedCurrency = used.currency, let capCurrency = cap.currency, usedCurrency != capCurrency {
            throw KimiUsageError.invalidResponse
        }
        let currency = cap.currency ?? used.currency ?? "USD"
        let capped: Bool
        if let value = wallet["monthlyChargeLimitEnabled"], !(value is NSNull) {
            guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                throw KimiUsageError.invalidResponse
            }
            capped = flag.boolValue
        } else {
            capped = false
        }

        let spending: MetricLine
        if currency == "USD", capped {
            spending = .progress(label: "Extra Usage", used: used.amount, limit: cap.amount, format: .dollars)
        } else if currency == "USD", !capped {
            spending = .values(label: "Extra Usage", values: [MetricValue(number: used.amount, kind: .dollars)])
        } else {
            // 비USD 금액은 통화·상한을 그대로 표시. USD 수치로 오인하지 않음.
            let text =
                walletAmount(used.amount, currency: currency)
                + (capped ? " / " + walletAmount(cap.amount, currency: currency) : "")
            spending = .badge(label: "Extra Usage", text: text)
        }
        let remaining: MetricLine =
            currency == "USD"
            ? .values(label: "Extra Balance", values: [MetricValue(number: available, kind: .dollars)])
            : .badge(label: "Extra Balance", text: walletAmount(available, currency: currency))
        return [spending, remaining]
    }

    private static func walletInteger(_ value: Any?, allowsNegative: Bool = false) throws -> Double {
        guard let value, !(value is NSNull) else { return 0 }
        guard let number = ProviderParse.number(value), number.rounded(.towardZero) == number,
            allowsNegative || number >= 0
        else { throw KimiUsageError.invalidResponse }
        return number
    }

    private static func walletMoney(_ value: Any?) throws -> (amount: Double, currency: String?) {
        guard let value, !(value is NSNull) else { return (0, nil) }
        guard let money = value as? [String: Any] else { throw KimiUsageError.invalidResponse }
        let amount = try walletInteger(money["priceInCents"]) / 100
        var currency: String?
        if let value = money["currency"], !(value is NSNull) {
            guard let code = value as? String else { throw KimiUsageError.invalidResponse }
            let normalized = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            if !normalized.isEmpty {
                guard normalized.utf8.count == 3, normalized.utf8.allSatisfy({ (65...90).contains($0) }) else {
                    throw KimiUsageError.invalidResponse
                }
                currency = normalized
            }
        }
        return (amount, currency)
    }

    private static func walletAmount(_ amount: Double, currency: String) -> String {
        if currency == "USD" { return MetricFormatter.number(amount, kind: .dollars, style: .row) }
        return currency + " "
            + amount.formatted(.number.precision(.fractionLength(2)).locale(Locale(identifier: "en_US")))
    }

    private static func quotaLine(
        _ detail: [String: Any],
        label: String,
        periodDurationMs: Int
    ) throws -> MetricLine {
        guard let limit = ProviderParse.number(detail["limit"]), limit > 0 else {
            throw KimiUsageError.invalidResponse
        }

        let used: Double
        if let explicit = ProviderParse.number(detail["used"]) {
            used = explicit
        } else if let remaining = ProviderParse.number(detail["remaining"]) {
            used = limit - remaining
        } else {
            throw KimiUsageError.invalidResponse
        }
        guard used >= 0 else { throw KimiUsageError.invalidResponse }

        let reset = (detail["resetTime"] as? String).flatMap(EgasuISO8601.date(from:))
        return .progress(
            label: label,
            used: used / limit * 100,
            limit: 100,
            format: .percent,
            resetsAt: reset,
            periodDurationMs: periodDurationMs
        )
    }

    private static func windowDurationMs(_ value: Any?) throws -> Int? {
        guard let window = value as? [String: Any] else { return nil }
        guard let duration = ProviderParse.number(window["duration"]), duration > 0,
              let rawUnit = window["timeUnit"] as? String
        else {
            throw KimiUsageError.invalidResponse
        }
        let multiplier: Double
        switch rawUnit.uppercased() {
        case "TIME_UNIT_SECOND": multiplier = 1000
        case "TIME_UNIT_MINUTE": multiplier = 60 * 1000
        case "TIME_UNIT_HOUR": multiplier = 60 * 60 * 1000
        case "TIME_UNIT_DAY": multiplier = 24 * 60 * 60 * 1000
        default: return nil
        }
        let milliseconds = duration * multiplier
        guard milliseconds <= Double(Int.max) else { throw KimiUsageError.invalidResponse }
        return Int(milliseconds)
    }

    private static func plan(_ root: [String: Any]) -> String? {
        guard let user = root["user"] as? [String: Any],
              let membership = user["membership"] as? [String: Any],
              let raw = (membership["level"] as? String)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        else {
            return nil
        }
        let normalized = raw.uppercased()
        if let planName = planNamesByLevel[normalized] {
            return planName
        }
        guard normalized != "LEVEL_UNSPECIFIED" else { return nil }
        let withoutPrefix = normalized.hasPrefix("LEVEL_") ? String(normalized.dropFirst(6)) : raw
        return withoutPrefix.titleCased(separator: { $0 == "_" || $0 == "-" }, lowercasingTail: true)
    }
}
