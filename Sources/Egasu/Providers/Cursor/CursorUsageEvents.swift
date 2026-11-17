import CoreFoundation
import Foundation

struct CursorUsageEvent: Sendable, Equatable {
    var date: Date
    var model: String
    var tokens: TokenBreakdown
    var costUSD: Double
}

struct CursorUsageEventsPage: Sendable, Equatable {
    var totalCount: Int
    var events: [CursorUsageEvent]
}

enum CursorUsageEvents {
    static let chargeableKind = "USAGE_EVENT_KIND_USAGE_BASED"

    /// 포함·무료 이벤트의 chargedCents는 청구액이 아님. 손상된 이벤트가 있으면 페이지 전체 거부.
    static func parsePage(_ data: Data) throws -> CursorUsageEventsPage {
        guard let object = ProviderParse.jsonObject(data),
            let total = integer(object["totalUsageEventsCount"]),
            let rawEvents = (object["usageEventsDisplay"] ?? [Any]()) as? [Any]
        else { throw CursorUsageError.invalidResponse }
        let events = try rawEvents.map { raw -> CursorUsageEvent in
            guard let event = raw as? [String: Any],
                let milliseconds = number(event["timestamp"]), milliseconds >= 0,
                let kind = event["kind"] as? String, !kind.isEmpty,
                let usage = (event["tokenUsage"] ?? [String: Any]()) as? [String: Any]
            else { throw CursorUsageError.invalidResponse }
            if let rawModel = event["model"], !(rawModel is String) {
                throw CursorUsageError.invalidResponse
            }
            var chargeable = true
            if let value = event["isChargeable"] {
                guard let flag = value as? NSNumber, CFGetTypeID(flag) == CFBooleanGetTypeID() else {
                    throw CursorUsageError.invalidResponse
                }
                chargeable = flag.boolValue
            }
            var dollars = 0.0
            if kind == chargeableKind, chargeable, let raw = event["chargedCents"] {
                guard let cents = number(raw), cents >= 0 else { throw CursorUsageError.invalidResponse }
                dollars = cents / 100
            }
            func count(_ key: String) throws -> Int {
                guard let value = usage[key] else { return 0 }
                guard let count = integer(value) else { throw CursorUsageError.invalidResponse }
                return count
            }
            let tokens = try TokenBreakdown(
                input: count("inputTokens"), cacheWrite5m: count("cacheWriteTokens"),
                cacheRead: count("cacheReadTokens"), output: count("outputTokens")
            )
            var totalTokens = 0
            for count in [tokens.input, tokens.cacheRead, tokens.cacheWrite5m, tokens.output] {
                let sum = totalTokens.addingReportingOverflow(count)
                guard !sum.overflow else { throw CursorUsageError.invalidResponse }
                totalTokens = sum.partialValue
            }
            return CursorUsageEvent(
                date: Date(timeIntervalSince1970: milliseconds / 1000),
                model: (event["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                tokens: tokens, costUSD: dollars
            )
        }
        return CursorUsageEventsPage(totalCount: total, events: events)
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let value = number(value), value >= 0 else { return nil }
        return Int(exactly: value)
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            result = number.doubleValue
        } else if let string = value as? String {
            result = Double(string)
        } else {
            result = nil
        }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }
}

enum CursorHistoryError: Error {
    case http(Int, retryAfter: String?)
}
