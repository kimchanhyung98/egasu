import Foundation

/// egasu 가격 보충표 — 추가 모델·Fast 배율·기록의 모델명과 정규 가격 키를 연결하는 별칭 규칙.
/// pricing_supplement.json을 번들에 포함하고 게시된 피드에서 갱신 — 앱 릴리스 없이 가격 반영.
struct PricingSupplement: Sendable {
    /// 보충표가 직접 제공하는 모델 가격 — 다른 출처보다 우선.
    let pricing: [String: ModelRates]
    /// Fast 모델명·요청별 Fast 신호에 적용하는 기본 모델 배율.
    let fastMultipliers: [String: Double]
    /// 정확 모델·등록 별칭·날짜 변형만 허용하는 배율 — 구버전 앱은 이 필드 무시.
    let exactFastMultipliers: [String: Double]
    let aliasRules: [AliasRule]
    let updatedAt: String?

    /// 모델명 정규식을 정규 가격 키로 연결 — 먼저 일치한 규칙 사용. JSON의 V2 규칙은 기존 규칙 앞에 배치.
    struct AliasRule: @unchecked Sendable {
        let pattern: NSRegularExpression
        let canonical: String
    }

    init(
        pricing: [String: ModelRates] = [:],
        fastMultipliers: [String: Double] = [:],
        exactFastMultipliers: [String: Double] = [:],
        aliasRules: [AliasRule] = [],
        updatedAt: String? = nil
    ) {
        self.pricing = pricing
        self.fastMultipliers = fastMultipliers
        self.exactFastMultipliers = exactFastMultipliers
        self.aliasRules = aliasRules
        self.updatedAt = updatedAt
    }

    /// 별칭 규칙에 따른 정규 가격 키 — 일치 규칙이 없으면 nil.
    func canonicalName(for model: String) -> String? {
        let range = NSRange(model.startIndex..., in: model)
        for rule in aliasRules where rule.pattern.firstMatch(in: model, range: range) != nil {
            return rule.canonical
        }
        return nil
    }

    /// 기본 모델의 Fast 배율 — 정확한 키 우선, 접두사·날짜 변형은 긴 모델명 우선.
    func fastMultiplier(for model: String) -> Double? {
        if let exact = exactFastMultipliers[model] ?? fastMultipliers[model] { return exact }
        return exactFastMultiplier(for: model) ?? legacyFastMultiplier(for: model)
    }

    /// 구형 피드의 넓은 모델명 일치를 지원하는 Fast 배율.
    func legacyFastMultiplier(for model: String) -> Double? {
        if let exact = fastMultipliers[model] { return exact }
        let normalized = PricingCatalog.normalizedKey(model)
        let candidates = fastMultipliers.sorted {
            $0.key.count == $1.key.count ? $0.key < $1.key : $0.key.count > $1.key.count
        }
        for part in normalized.split(whereSeparator: { $0 == "/" || $0 == ":" }) {
            for (base, multiplier) in candidates {
                if Self.matchesModelSuffix(part: String(part), base: PricingCatalog.normalizedKey(base)) {
                    return multiplier
                }
            }
        }
        return nil
    }

    /// 등록 모델·별칭·날짜 변형에만 적용하는 Fast 배율.
    func exactFastMultiplier(for model: String) -> Double? {
        if let exact = exactFastMultipliers[model] { return exact }
        let canonical = canonicalName(for: model) ?? model
        let normalizedExact = PricingCatalog.normalizedKey(canonical).lowercased()
        let exactCandidates = exactFastMultipliers.sorted { $0.key.count > $1.key.count }
        for part in normalizedExact.split(whereSeparator: { $0 == "/" || $0 == ":" }) {
            for (base, multiplier) in exactCandidates {
                let normalizedBase = PricingCatalog.normalizedKey(base).lowercased()
                guard part.hasPrefix(normalizedBase) else { continue }
                let suffix = String(part.dropFirst(normalizedBase.count))
                if suffix.isEmpty
                    || suffix.range(of: #"^-(?:\d{8}|\d{4}-\d{2}-\d{2})$"#, options: .regularExpression) != nil
                {
                    return multiplier
                }
            }
        }
        return nil
    }

    /// part에서 base 뒤가 비어 있거나 하이픈으로 이어질 때만 일치.
    private static func matchesModelSuffix(part: String, base: String) -> Bool {
        guard let range = part.range(of: base, options: .backwards) else { return false }
        let suffix = part[range.upperBound...]
        return suffix.isEmpty || suffix.hasPrefix("-")
    }
}

// MARK: - JSON decoding

extension PricingSupplement {
    /// 번들·피드의 보충표 JSON 해석 — 잘못된 JSON은 오류, 잘못된 별칭 정규식은 로그 후 제외.
    static func decode(from data: Data) throws -> PricingSupplement {
        let file = try JSONDecoder().decode(SupplementFile.self, from: data)
        var pricing: [String: ModelRates] = [:]
        // 새 해석 규칙이 필요한 항목은 구버전 앱이 읽지 않는 필드에서 우선 적용.
        let entries = file.pricing.merging(file.pricingV2) { _, updated in updated }
        for (model, entry) in entries {
            pricing[model] = ModelRates(
                inputPerMillion: entry.inputPerMillion,
                outputPerMillion: entry.outputPerMillion,
                cacheWritePerMillion: entry.cacheWritePerMillion ?? entry.inputPerMillion,
                cacheReadPerMillion: entry.cacheReadPerMillion ?? entry.inputPerMillion * 0.1,
                inputAbove200kPerMillion: entry.longContext?.inputPerMillion,
                outputAbove200kPerMillion: entry.longContext?.outputPerMillion,
                cacheWriteAbove200kPerMillion: entry.longContext?.cacheWritePerMillion,
                cacheReadAbove200kPerMillion: entry.longContext?.cacheReadPerMillion,
                cacheReadIsExplicit: entry.cacheReadPerMillion != nil,
                longContextThresholdTokens: entry.longContext?.thresholdTokens,
                // Claude speed 필드 등 요청별 Fast 신호에 사용할 배율 보존.
                fastMultiplier: file.exactFastMultipliers?[model] ?? file.fastMultipliers?[model] ?? 1
            )
        }
        var rules: [AliasRule] = []
        for rule in file.aliasRulesV2 + file.aliasRules {
            do {
                let pattern = try NSRegularExpression(pattern: rule.pattern)
                rules.append(AliasRule(pattern: pattern, canonical: rule.canonical))
            } catch {
                AppLog.warn(.cache, "pricing supplement: invalid alias pattern '\(rule.pattern)' skipped: \(error.localizedDescription)")
            }
        }
        return PricingSupplement(
            pricing: pricing,
            fastMultipliers: file.fastMultipliers ?? [:],
            exactFastMultipliers: file.exactFastMultipliers ?? [:],
            aliasRules: rules,
            updatedAt: file.updatedAt
        )
    }

    private struct SupplementFile: Decodable {
        var updatedAt: String?
        var pricing: [String: Entry]
        var pricingV2: [String: Entry]
        var fastMultipliers: [String: Double]?
        var exactFastMultipliers: [String: Double]?
        var aliasRules: [Rule]
        var aliasRulesV2: [Rule]

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
            pricing = try container.decode([String: Entry].self, forKey: .pricing)
            pricingV2 = container.contains(.pricingV2)
                ? try container.decode([String: Entry].self, forKey: .pricingV2) : [:]
            fastMultipliers = try container.decodeIfPresent([String: Double].self, forKey: .fastMultipliers)
            exactFastMultipliers = try container.decodeIfPresent([String: Double].self, forKey: .exactFastMultipliers)
            aliasRules = try container.decode([Rule].self, forKey: .aliasRules)
            aliasRulesV2 = container.contains(.aliasRulesV2)
                ? try container.decode([Rule].self, forKey: .aliasRulesV2) : []
        }

        struct Entry: Decodable {
            var inputPerMillion: Double
            var outputPerMillion: Double
            var cacheWritePerMillion: Double?
            var cacheReadPerMillion: Double?
            var longContext: LongContext?

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
                outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)
                cacheWritePerMillion = try container.decodeIfPresent(Double.self, forKey: .cacheWritePerMillion)
                cacheReadPerMillion = try container.decodeIfPresent(Double.self, forKey: .cacheReadPerMillion)
                longContext = container.contains(.longContext)
                    ? try container.decode(LongContext.self, forKey: .longContext) : nil
            }

            enum CodingKeys: String, CodingKey {
                case inputPerMillion = "input_per_million"
                case outputPerMillion = "output_per_million"
                case cacheWritePerMillion = "cache_write_per_million"
                case cacheReadPerMillion = "cache_read_per_million"
                case longContext = "long_context"
            }
        }

        struct LongContext: Decodable {
            var thresholdTokens: Int
            var inputPerMillion: Double
            var outputPerMillion: Double
            var cacheWritePerMillion: Double
            var cacheReadPerMillion: Double

            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                thresholdTokens = try container.decode(Int.self, forKey: .thresholdTokens)
                guard thresholdTokens > 0 else {
                    throw DecodingError.dataCorruptedError(
                        forKey: .thresholdTokens, in: container, debugDescription: "Expected a positive token threshold")
                }
                inputPerMillion = try container.decode(Double.self, forKey: .inputPerMillion)
                outputPerMillion = try container.decode(Double.self, forKey: .outputPerMillion)
                cacheWritePerMillion = try container.decode(Double.self, forKey: .cacheWritePerMillion)
                cacheReadPerMillion = try container.decode(Double.self, forKey: .cacheReadPerMillion)
                let rates: [(CodingKeys, Double)] = [
                    (.inputPerMillion, inputPerMillion), (.outputPerMillion, outputPerMillion),
                    (.cacheWritePerMillion, cacheWritePerMillion), (.cacheReadPerMillion, cacheReadPerMillion),
                ]
                for (key, value) in rates where !value.isFinite || value < 0 {
                    throw DecodingError.dataCorruptedError(
                        forKey: key, in: container, debugDescription: "Expected a finite nonnegative rate")
                }
            }

            enum CodingKeys: String, CodingKey {
                case thresholdTokens = "threshold_tokens"
                case inputPerMillion = "input_per_million"
                case outputPerMillion = "output_per_million"
                case cacheWritePerMillion = "cache_write_per_million"
                case cacheReadPerMillion = "cache_read_per_million"
            }
        }

        struct Rule: Decodable {
            var pattern: String
            var canonical: String
        }

        enum CodingKeys: String, CodingKey {
            case updatedAt = "updated_at"
            case pricing
            case pricingV2 = "pricing_v2"
            case fastMultipliers = "fast_multipliers"
            case exactFastMultipliers = "fast_multipliers_exact"
            case aliasRules = "alias_rules"
            case aliasRulesV2 = "alias_rules_v2"
        }
    }
}
