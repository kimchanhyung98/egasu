import Foundation

/// Codex·Pi 요청의 정규화 토큰에 같은 장문·캐시 할인·서비스 등급 요율 적용.
enum CodexUsagePricing {
    /// 한 집계에서 같은 가격 스냅샷 사용. 모델과 Ultrafast 여부별로 단가 조회 결과 재사용.
    struct Resolver {
        private let pricing: ModelPricing
        private var cache: [Key: Resolution?] = [:]

        init(pricing: ModelPricing) {
            self.pricing = pricing
        }

        mutating func estimate(model: String, tokens: TokenBreakdown, isUltrafast: Bool = false) -> Double? {
            let key = Key(model: model, isUltrafast: isUltrafast)
            let resolution: Resolution?
            if let cached = cache[key] {
                resolution = cached
            } else {
                resolution = CodexUsagePricing.resolve(model: model, pricing: pricing, isUltrafast: isUltrafast)
                // 단가를 찾지 못한 결과도 저장해 같은 모델의 반복 조회 방지.
                cache.updateValue(resolution, forKey: key)
            }
            return resolution?.cost(for: tokens)
        }
    }

    private struct Key: Hashable {
        let model: String
        let isUltrafast: Bool
    }

    private struct Resolution {
        let rates: ModelRates
        let fastOverride: Bool?

        func cost(for tokens: TokenBreakdown, applyLongContextRates: Bool = true) -> Double? {
            var request = tokens
            if let fastOverride { request.isFast = fastOverride }
            let cost = rates.costDollars(for: request, applyLongContextRates: applyLongContextRates)
            return cost.isFinite && cost >= 0 ? cost : nil
        }
    }

    static func estimate(
        model: String, tokens: TokenBreakdown, pricing: ModelPricing, isUltrafast: Bool = false
    ) -> Double? {
        resolve(model: model, pricing: pricing, isUltrafast: isUltrafast)?.cost(for: tokens)
    }

    private static func resolve(model: String, pricing: ModelPricing, isUltrafast: Bool) -> Resolution? {
        let normalized = ModelPricing.normalizedFastName(model)
        let canonical =
            pricing.supplement.canonicalName(for: normalized)
            ?? pricing.supplement.canonicalName(for: datedBaseModel(normalized)) ?? normalized
        let isUltrafastAlias =
            canonical.range(of: #"-ultrafast(?=(?:-\d{4}-?\d{2}-?\d{2})?$)"#, options: .regularExpression) != nil
        if isUltrafast || isUltrafastAlias {
            let base = canonical.replacingOccurrences(
                of: #"-(?:ultrafast|fast)(?=(?:-\d{4}-?\d{2}-?\d{2})?$)"#,
                with: "", options: .regularExpression)
            let qualified = normalized.replacingOccurrences(
                of: #"-(?:ultrafast|fast)(?=(?:-\d{4}-?\d{2}-?\d{2})?$)"#,
                with: "", options: .regularExpression
            ).replacingOccurrences(
                of: #"^(.+?)(-\d{4}-?\d{2}-?\d{2})?$"#, with: "$1-ultrafast$2", options: .regularExpression
            )
            let aliasRates =
                isUltrafastAlias ? exactQualifiedRates(model: model, pricing: pricing) : nil
            guard
                let rates = aliasRates ?? exactQualifiedRates(model: qualified, pricing: pricing)
                    ?? resolveRates(model: qualified, pricing: pricing)
                    ?? resolveRates(model: base + "-ultrafast", pricing: pricing)
            else { return nil }
            return Resolution(rates: adjusted(rates: rates, model: base), fastOverride: false)
        }
        let fastBase = ModelPricing.fastBaseName(canonical)
        if let fastBase,
            fastBase.range(of: #"(?i)[-.@]ultrafast(?:$|[^A-Za-z0-9])"#, options: .regularExpression) != nil
        {
            return nil
        }
        let isFastAlias = fastBase != nil
        let rateModel = fastBase ?? canonical
        let prefixedBase: String
        if isFastAlias, let separator = model.lastIndex(of: "/") {
            prefixedBase = String(model[...separator]) + withoutProviderPrefix(rateModel)
        } else {
            prefixedBase = isFastAlias ? rateModel : model
        }
        let qualifiedBase = isFastAlias
            ? normalized.replacingOccurrences(of: #"-fast(?=(?:-\d{4}-?\d{2}-?\d{2})?$)"#, with: "", options: .regularExpression)
            : model
        let qualifiedRates = qualifiedBase != model ? exactQualifiedRates(model: qualifiedBase, pricing: pricing) : nil
        let baseRates = qualifiedRates ?? exactQualifiedRates(model: prefixedBase, pricing: pricing)
            ?? resolveRates(model: rateModel, pricing: pricing)
        guard let rates = baseRates ?? resolveRates(model: model, pricing: pricing) else { return nil }

        // 저장된 배율이 1이면 보충표의 모델별 배율 확인. Fast 별칭은 기본 모델 단가를 찾았을 때 배율 적용.
        var effectiveRates = rates
        if rates.fastMultiplier == 1, let multiplier = pricing.supplement.fastMultiplier(for: rateModel) {
            effectiveRates.fastMultiplier = multiplier
        }
        return Resolution(
            rates: adjusted(rates: effectiveRates, model: rateModel),
            fastOverride: isFastAlias ? baseRates != nil : nil
        )
    }

    static func estimateRecord(_ record: UsageRecord, pricing: ModelPricing) -> UsageHistoryBuilder.CostEstimate {
        guard var tokens = record.tokens else { return .unpriced }
        guard tokens.cacheWrite1h == 0 else { return .unsupportedUsage }
        let tier = record.serviceTier?.lowercased()
        if let tier, !["default", "standard", "priority", "fast", "ultrafast"].contains(tier) { return .unsupportedUsage }
        if tier == "priority" || tier == "fast" { tokens.isFast = true }
        guard let model = record.effectiveModel else { return .unpriced }
        return .init(resolve(model: model, pricing: pricing, isUltrafast: tier == "ultrafast")?.cost(
            for: tokens, applyLongContextRates: record.granularity == .request
        ))
    }

    static func adjusted(rates: ModelRates, model: String) -> ModelRates {
        var effective = rates
        let base = datedBaseModel(model)
        switch base {
        case "gpt-5.4", "gpt-5.4-pro", "gpt-5.5", "gpt-5.5-pro",
            "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra",
            "gpt-6-sol", "gpt-6-luna", "gpt-6-rosalind", "gpt-6.1-sol", "gpt-6.1-terra",
            "gpt-6.2-astra", "gpt-6.2-sol":
            effective.inputAbove200kPerMillion = rates.inputPerMillion * 2
            effective.outputAbove200kPerMillion = rates.outputPerMillion * 1.5
            effective.cacheWriteAbove200kPerMillion = rates.cacheWritePerMillion * 2
            effective.cacheReadAbove200kPerMillion = rates.cacheReadPerMillion * 2
            effective.longContextThresholdTokens = 272_000
        default:
            break
        }
        if base == "gpt-5.4-pro" || base == "gpt-5.5-pro" || !rates.cacheReadIsExplicit {
            effective.cacheReadPerMillion = effective.inputPerMillion
            effective.cacheReadAbove200kPerMillion = effective.inputAbove200kPerMillion
        }
        switch base {
        case "gpt-5.5", "gpt-5.5-pro":
            effective.fastMultiplier = 2.5
        case "gpt-5.4", "gpt-5.4-pro", "gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna", "gpt-6-astra":
            effective.fastMultiplier = 2
        default:
            effective.fastMultiplier = rates.fastMultiplier == 1 ? 2 : rates.fastMultiplier
        }
        return effective
    }

    private static func exactQualifiedRates(model: String, pricing: ModelPricing) -> ModelRates? {
        guard model.contains("/") || datedBaseModel(model) != model else { return nil }
        // Codex의 출처·날짜별 정확 요율은 정규화 별칭보다 우선. 공통 가격 엔진의 별칭 순서는 유지.
        return pricing.supplement.pricing[model]
            ?? pricing.primary.findExact(model)?.rates
            ?? pricing.secondary.findExact(model)?.rates
    }

    private static func resolveRates(model: String, pricing: ModelPricing) -> ModelRates? {
        // 원래 이름 우선. 단가가 없을 때만 공급자 접두사·날짜를 제거해 재조회.
        pricing.resolve(model: model) ?? pricing.resolve(model: withoutProviderPrefix(model))
            ?? pricing.resolve(model: datedBaseModel(model))
    }

    private static func withoutProviderPrefix(_ model: String) -> String {
        String(model.split(separator: "/").last ?? Substring(model))
    }

    private static func datedBaseModel(_ model: String) -> String {
        withoutProviderPrefix(model)
            .replacingOccurrences(of: #"-\d{4}-\d{2}-\d{2}$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"-\d{8}$"#, with: "", options: .regularExpression)
    }
}
