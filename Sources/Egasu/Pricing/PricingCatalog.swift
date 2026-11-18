import Foundation

/// 가격 출처 하나의 모델 키별 요율표 — LiteLLM 또는 models.dev.
/// 정확한 키 우선, 이후 경계를 확인하는 유사 일치 — 공급자 접두사·구분자·날짜 변형 허용.
/// 숫자 버전은 구분 — claude-sonnet-4와 claude-sonnet-4-5는 일치하지 않음.
struct PricingCatalog: Sendable, Equatable {
    var entries: [String: ModelRates]
    /// 출처 자료의 취득 시각 — 로그 참고용.
    var retrievedAt: String?

    init(entries: [String: ModelRates] = [:], retrievedAt: String? = nil) {
        self.entries = entries
        self.retrievedAt = retrievedAt
    }

    func findExact(_ model: String) -> (key: String, rates: ModelRates)? {
        entries[model].map { (model, $0) }
    }

    /// 정확 일치 실패 후 전체 항목의 유사 일치 탐색 — 긴 키 우선, 동률은 사전순.
    func findFuzzy(_ model: String, excludingFastVariants: Bool = false) -> (key: String, rates: ModelRates)? {
        let normalizedModel = Self.normalizedKey(model)
        let fastSegment = #"-(?:ultrafast|fast)($|[^A-Za-z0-9])"#
        let excludeFast =
            excludingFastVariants
            && normalizedModel.lowercased().range(of: fastSegment, options: .regularExpression) == nil
        var best: (key: String, rates: ModelRates)?
        for (key, rates) in entries {
            if excludeFast {
                let normalizedCandidate = Self.normalizedKey(key).lowercased()
                if normalizedCandidate.contains("-fast") || normalizedCandidate.contains("-ultrafast"),
                   normalizedCandidate.range(of: fastSegment, options: .regularExpression) != nil { continue }
            }
            guard Self.keyMatches(candidate: key, model: model, normalizedModel: normalizedModel) else { continue }
            if let current = best {
                if key.count > current.key.count || (key.count == current.key.count && key < current.key) {
                    best = (key, rates)
                }
            } else {
                best = (key, rates)
            }
        }
        return best
    }

    /// 다른 카탈로그를 병합 — 같은 키는 other의 항목 우선.
    func merging(_ other: PricingCatalog) -> PricingCatalog {
        var merged = entries
        merged.merge(other.entries) { _, new in new }
        return PricingCatalog(entries: merged, retrievedAt: other.retrievedAt ?? retrievedAt)
    }
}

// MARK: - Fuzzy matching (port of ccusage pricing.rs)

extension PricingCatalog {
    /// 점·@ 구분자를 하이픈으로 통일 — 예: grok-4.3 → grok-4-3.
    static func normalizedKey(_ value: String) -> String {
        guard value.contains(".") || value.contains("@") else { return value }
        return value.replacingOccurrences(of: ".", with: "-").replacingOccurrences(of: "@", with: "-")
    }

    /// 원본·정규화 이름에서 모델 경계를 지키는 포함 관계 판정.
    static func keyMatches(candidate: String, model: String, normalizedModel: String) -> Bool {
        if containsKey(model, key: candidate) || containsKey(candidate, key: model) {
            return true
        }
        let normalizedCandidate = normalizedKey(candidate)
        if containsKey(normalizedModel, key: normalizedCandidate)
            || containsKey(normalizedCandidate, key: normalizedModel) { return true }
        guard normalizedCandidate.contains("-v") else { return false }
        // 등록된 공급자 후보의 날짜 뒤 개정 접미사만 제거 — 미등록 요청 이름은 유지.
        let unversioned = normalizedCandidate.replacingOccurrences(
            of: #"(-[0-9]{8}|-[0-9]{4}-[0-9]{2}-[0-9]{2})-v[0-9]+:[0-9]+$"#,
            with: "$1", options: .regularExpression)
        return unversioned != normalizedCandidate && containsKey(unversioned, key: normalizedModel)
    }

    /// 모델명 앞의 구분자와 뒤의 날짜만 허용 — 미등록 설명·등급을 다른 모델의 가격으로 연결하지 않음.
    static func containsKey(_ value: String, key: String) -> Bool {
        guard !key.isEmpty else { return false }
        let valueBytes = Array(value.utf8)
        let keyBytes = Array(key.utf8)
        guard keyBytes.count <= valueBytes.count else { return false }
        for start in 0...(valueBytes.count - keyBytes.count) {
            guard valueBytes[start..<(start + keyBytes.count)].elementsEqual(keyBytes) else { continue }
            let beforeOK = start == 0 || !valueBytes[start - 1].isASCIIAlphanumeric
            guard beforeOK else { continue }
            let suffix = Array(valueBytes[(start + keyBytes.count)...])
            if suffixAllowsMatch(key: keyBytes, suffix: suffix) {
                return true
            }
        }
        return false
    }

    private static func suffixAllowsMatch(key: [UInt8], suffix: [UInt8]) -> Bool {
        guard let separator = suffix.first else { return true }
        if key.starts(with: Array("ft:".utf8)), separator == UInt8(ascii: ":") { return true }
        guard separator == UInt8(ascii: "-") || separator == UInt8(ascii: ".") else {
            return false
        }
        if suffix.count == 9 { return suffix.dropFirst().allSatisfy(\.isASCIIDigit) }
        guard suffix.count == 11,
              suffix[5] == UInt8(ascii: "-"), suffix[8] == UInt8(ascii: "-") else { return false }
        return suffix[1..<5].allSatisfy(\.isASCIIDigit)
            && suffix[6..<8].allSatisfy(\.isASCIIDigit)
            && suffix[9..<11].allSatisfy(\.isASCIIDigit)
    }
}

private extension UInt8 {
    var isASCIIDigit: Bool { self >= UInt8(ascii: "0") && self <= UInt8(ascii: "9") }
    var isASCIIAlphanumeric: Bool {
        isASCIIDigit
            || (self >= UInt8(ascii: "a") && self <= UInt8(ascii: "z"))
            || (self >= UInt8(ascii: "A") && self <= UInt8(ascii: "Z"))
    }
}
