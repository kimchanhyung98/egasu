import Foundation

/// 프로바이더와 로컬 API가 공유하는 ISO 8601 날짜 해석·서식.
/// 공백 구분·UTC 접미사·다양한 소수 자릿수를 해석 전에 정규화.
enum EgasuISO8601 {
    static func string(from date: Date) -> String {
        formatter(fractionalSeconds: true).string(from: date)
    }

    static func date(from value: String) -> Date? {
        let normalized = normalizeTimestamp(value)
        return formatter(fractionalSeconds: true).date(from: normalized) ??
        formatter(fractionalSeconds: false).date(from: normalized)
    }

    /// 공백 구분·UTC 접미사·긴 소수 초를 지원하는 날짜 문자열 정규화.
    private static func normalizeTimestamp(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        if s.contains(" "),
           let range = s.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}"#, options: .regularExpression) {
            s.replaceSubrange(range, with: s[range].replacingOccurrences(of: " ", with: "T"))
        }
        if s.hasSuffix(" UTC") {
            s = String(s.dropLast(4)) + "Z"
        }

        if let match = s.range(of: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})$"#, options: .regularExpression) {
            let matched = String(s[match])
            return normalizeFractionalISO(matched, assumeUTC: false)
        }
        if let match = s.range(of: #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?$"#, options: .regularExpression) {
            let matched = String(s[match])
            return normalizeFractionalISO(matched, assumeUTC: true)
        }

        return s
    }

    private static func normalizeFractionalISO(_ value: String, assumeUTC: Bool) -> String {
        let pattern = #"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})(\.\d+)?(Z|[+-]\d{2}:\d{2})?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges >= 2,
              let headRange = Range(match.range(at: 1), in: value)
        else {
            return assumeUTC && !value.hasSuffix("Z") ? value + "Z" : value
        }

        let head = String(value[headRange])
        var frac = ""
        if match.numberOfRanges > 2, match.range(at: 2).location != NSNotFound,
           let fracRange = Range(match.range(at: 2), in: value) {
            var digits = String(value[fracRange]).dropFirst()
            if digits.count > 3 {
                digits = digits.prefix(3)
            }
            while digits.count < 3 {
                digits.append("0")
            }
            frac = ".\(digits)"
        }

        var tz = "Z"
        if !assumeUTC, match.numberOfRanges > 3, match.range(at: 3).location != NSNotFound,
           let tzRange = Range(match.range(at: 3), in: value) {
            tz = String(value[tzRange])
        }

        return head + frac + tz
    }

    // 생성 비용을 줄이도록 두 고정 설정의 ISO8601DateFormatter 공유. 생성 후 설정은 변경하지 않음.
    private nonisolated(unsafe) static let fractionalFormatter = makeFormatter(fractionalSeconds: true)
    private nonisolated(unsafe) static let plainFormatter = makeFormatter(fractionalSeconds: false)

    private static func formatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        fractionalSeconds ? fractionalFormatter : plainFormatter
    }

    private static func makeFormatter(fractionalSeconds: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractionalSeconds
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }
}
