import Foundation

/// 공개 가격표 두 종의 해석과 번들·디스크 캐시용 축약 형식 변환.
/// 요율과 해석에 필요한 메타데이터 보관 — 취득 시각, 캐시 읽기 요율의 출처 포함.
enum PricingCatalogCodecs {
    // MARK: - LiteLLM (model_prices_and_context_window.json)

    /// LiteLLM JSON을 가격표로 변환 — 입력·출력 요율 없는 항목 제외, 토큰당 요율을 백만 토큰당으로 환산.
    /// 항목별로 JSON 해석 — 잘못된 항목 하나 때문에 전체 가격표를 거부하지 않음.
    static func catalogFromLiteLLM(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        let tokensPerMillion = 1_000_000.0
        var entries: [String: ModelRates] = [:]
        for (key, value) in root {
            guard let entry = value as? [String: Any],
                let input = catalogRate(entry["input_cost_per_token"], scale: tokensPerMillion),
                let output = catalogRate(entry["output_cost_per_token"], scale: tokensPerMillion)
            else { continue }
            let cacheWrite = catalogRate(entry["cache_creation_input_token_cost"], scale: tokensPerMillion)
            let cacheRead = catalogRate(entry["cache_read_input_token_cost"], scale: tokensPerMillion)
            let providerSpecific = entry["provider_specific_entry"] as? [String: Any]
            entries[key] = ModelRates(
                inputPerMillion: input,
                outputPerMillion: output,
                cacheWritePerMillion: cacheWrite ?? input,
                cacheReadPerMillion: cacheRead ?? input * 0.1,
                inputAbove200kPerMillion: catalogRate(
                    entry["input_cost_per_token_above_200k_tokens"], scale: tokensPerMillion),
                outputAbove200kPerMillion: catalogRate(
                    entry["output_cost_per_token_above_200k_tokens"], scale: tokensPerMillion),
                cacheWriteAbove200kPerMillion: catalogRate(
                    entry["cache_creation_input_token_cost_above_200k_tokens"], scale: tokensPerMillion),
                cacheReadAbove200kPerMillion: catalogRate(
                    entry["cache_read_input_token_cost_above_200k_tokens"], scale: tokensPerMillion),
                cacheReadIsExplicit: cacheRead != nil,
                fastMultiplier: catalogRate(providerSpecific?["fast"]) ?? 1
            )
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    // MARK: - models.dev (api.json)

    /// models.dev의 provider → models → id → cost 구조를 가격표로 변환.
    /// 모델 ID를 그대로 저장 — 중복 ID는 프로바이더 이름순 첫 유효 항목 사용. 단위는 백만 토큰당.
    static func catalogFromModelsDev(_ data: Data) throws -> PricingCatalog {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PricingCodecError.notAnObject
        }
        var entries: [String: ModelRates] = [:]
        for providerName in root.keys.sorted() {
            guard let provider = root[providerName] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (modelID, value) in models {
                guard entries[modelID] == nil,
                      let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                    let input = catalogRate(cost["input"]),
                    let output = catalogRate(cost["output"])
                else { continue }
                let cacheRead = catalogRate(cost["cache_read"])
                entries[modelID] = ModelRates(
                    inputPerMillion: input,
                    outputPerMillion: output,
                    cacheWritePerMillion: catalogRate(cost["cache_write"]) ?? input,
                    cacheReadPerMillion: cacheRead ?? input * 0.1,
                    cacheReadIsExplicit: cacheRead != nil
                )
            }
        }
        guard !entries.isEmpty else { throw PricingCodecError.noUsableEntries }
        return PricingCatalog(entries: entries)
    }

    private static func catalogRate(_ value: Any?, scale: Double = 1) -> Double? {
        guard value is NSNumber, let number = ProviderParse.number(value) else { return nil }
        return validRate(number * scale)
    }

    private static func validRate(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }

    // MARK: - Compact format (bundled snapshots + disk cache)

    static func catalogFromCompact(_ data: Data) throws -> PricingCatalog {
        let file = try JSONDecoder().decode(CompactCatalog.self, from: data)
        var entries: [String: ModelRates] = [:]
        entries.reserveCapacity(file.models.count)
        for (key, model) in file.models {
            guard let input = validRate(model.i), let output = validRate(model.o) else { continue }
            let cacheRead = validRate(model.cr)
            entries[key] = ModelRates(
                inputPerMillion: input,
                outputPerMillion: output,
                cacheWritePerMillion: validRate(model.cw) ?? input,
                cacheReadPerMillion: cacheRead ?? input * 0.1,
                inputAbove200kPerMillion: model.ia.flatMap(validRate),
                outputAbove200kPerMillion: model.oa.flatMap(validRate),
                cacheWriteAbove200kPerMillion: model.cwa.flatMap(validRate),
                cacheReadAbove200kPerMillion: model.cra.flatMap(validRate),
                cacheReadIsExplicit: cacheRead != nil && (model.cre ?? true),
                fastMultiplier: model.fast.flatMap(validRate) ?? 1
            )
        }
        return PricingCatalog(entries: entries, retrievedAt: file.retrievedAt)
    }

    static func compactData(from catalog: PricingCatalog) throws -> Data {
        var models: [String: CompactCatalog.Model] = [:]
        models.reserveCapacity(catalog.entries.count)
        for (key, rates) in catalog.entries {
            models[key] = CompactCatalog.Model(
                i: rates.inputPerMillion,
                o: rates.outputPerMillion,
                cw: rates.cacheWritePerMillion,
                cr: rates.cacheReadPerMillion,
                ia: rates.inputAbove200kPerMillion,
                oa: rates.outputAbove200kPerMillion,
                cwa: rates.cacheWriteAbove200kPerMillion,
                cra: rates.cacheReadAbove200kPerMillion,
                cre: rates.cacheReadIsExplicit ? nil : false,
                fast: rates.fastMultiplier == 1 ? nil : rates.fastMultiplier
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CompactCatalog(retrievedAt: catalog.retrievedAt, models: models))
    }

    /// 축약 키별 백만 토큰당 요율 — i는 입력, o는 출력, cw·cr은 캐시 쓰기·읽기, a는 긴 문맥, fast는 배율.
    private struct CompactCatalog: Codable {
        var retrievedAt: String?
        var models: [String: Model]

        struct Model: Codable {
            var i: Double
            var o: Double
            var cw: Double
            var cr: Double
            var ia: Double?
            var oa: Double?
            var cwa: Double?
            var cra: Double?
            /// 필드 생략은 명시 요율로 해석해 이전 스냅샷과 호환. `false`는 기본 요율을 뜻함.
            var cre: Bool?
            var fast: Double?
        }

        enum CodingKeys: String, CodingKey {
            case retrievedAt = "retrieved_at"
            case models
        }
    }
}

enum PricingCodecError: CategorizedError, LocalizedError, Equatable {
    case notAnObject
    case noUsableEntries

    var errorCategory: ErrorCategory { .decoding }

    var errorDescription: String? {
        switch self {
        case .notAnObject: return "Pricing feed is not a JSON object."
        case .noUsableEntries: return "Pricing feed contained no usable model entries."
        }
    }
}
