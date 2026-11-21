import Foundation
import os

/// 불변 가격 스냅샷 — 보충표·공개 카탈로그 두 종을 구성하여 한 번의 수집·매핑 동안 동기 사용.
/// Cursor 기록은 별칭과 보충표의 Cursor 전용 단가를 먼저 확인.
/// 공통 조회는 별칭을 적용한 뒤 보충표와 LiteLLM의 정확 일치 우선.
/// 속도 접미사를 정규화하고 Fast 배율·속도별 정확 일치 확인, 일반 모델은 LiteLLM 유사 일치 후 models.dev 정확 일치.
final class ModelPricing: Sendable {
    enum Source: Hashable, Sendable {
        case api
        case cursor
    }

    private struct ResolutionKey: Hashable {
        let model: String
        let source: Source
    }

    let supplement: PricingSupplement
    /// LiteLLM 가격표 — 번들 스냅샷에 받은 자료를 병합.
    let primary: PricingCatalog
    /// models.dev 가격표 — LiteLLM에 없는 모델의 보조 출처.
    let secondary: PricingCatalog

    /// 카탈로그 전체 탐색을 줄이도록 모델·출처별 결과 캐시 — 스냅샷 수명 동안 입력 불변.
    private let memo = OSAllocatedUnfairLock<[ResolutionKey: ModelRates?]>(initialState: [:])

    init(supplement: PricingSupplement, primary: PricingCatalog, secondary: PricingCatalog) {
        self.supplement = supplement
        self.primary = primary
        self.secondary = secondary
    }

    static let empty = ModelPricing(supplement: PricingSupplement(), primary: PricingCatalog(), secondary: PricingCatalog())

    /// 모델 단가 조회. 어느 출처에도 가격이 없으면 nil을 반환하여 토큰과 미확정 비용 구분.
    func resolve(model: String, source: Source = .api) -> ModelRates? {
        let key = ResolutionKey(model: model, source: source)
        if let cached = memo.withLock({ $0[key] }) {
            return cached
        }
        let scoped = source == .cursor ? cursorRates(model: model) : nil
        let resolved = scoped ?? resolveUncached(model: model)
        memo.withLock { $0[key] = resolved }
        return resolved
    }

    /// 모델과 토큰 내역으로 USD 비용 계산 — 단가가 없으면 nil.
    /// 요청 경계가 없는 집계 자료는 긴 문맥 요율 적용 생략 가능.
    func estimatedCostDollars(
        model: String,
        tokens: TokenBreakdown,
        applyLongContextRates: Bool = true,
        source: Source = .api
    ) -> Double? {
        guard let rates = resolve(model: model, source: source) else { return nil }
        return rates.costDollars(for: tokens, applyLongContextRates: applyLongContextRates)
    }

    /// Cursor 별도 요율은 보충 파일의 정확 항목·등록 별칭으로만 조회 — 공급 경로 접두사를 공개 카탈로그 유사 매칭에 전달하지 않음.
    private func cursorRates(model: String) -> ModelRates? {
        let scoped = "cursor/" + model
        if let canonical = supplement.canonicalName(for: scoped),
           let rates = supplement.pricing[canonical]
        {
            return rates
        }
        return supplement.pricing[scoped]
    }

    private func resolveUncached(model: String) -> ModelRates? {
        if let canonical = supplement.canonicalName(for: model), canonical != model {
            return lookup(canonical) ?? lookup(model)
        }
        return lookup(model)
    }

    /// 공통 요율 조회 — models.dev는 정확한 모델 ID만 조회하고, Ultrafast는 전용 항목만 사용.
    private func lookup(_ name: String) -> ModelRates? {
        if let entry = supplement.pricing[name] { return entry }
        if let exact = primary.findExact(name) { return exact.rates }
        let normalized = Self.normalizedFastName(name)
        if normalized != name {
            return resolveUncached(model: normalized) ?? secondary.findExact(name)?.rates
        }
        if name.range(of: #"(?i)[-.@]ultrafast(?:$|[^A-Za-z0-9])"#, options: .regularExpression) != nil {
            return secondary.findExact(name)?.rates
        }
        if let fast = fastVariant(name) { return fast }
        if Self.fastBaseName(name) != nil { return secondary.findExact(name)?.rates }
        if let fuzzy = primary.findFuzzy(name, excludingFastVariants: true) { return fuzzy.rates }
        if let exact = secondary.findExact(name) { return exact.rates }
        return nil
    }

    /// 말단·날짜 직전 Fast·Ultrafast 구분자만 통일 — 모델 버전의 소수점과 이름 내부 fast 구간 유지.
    static func normalizedFastName(_ name: String) -> String {
        guard
            let range = name.range(
                of: #"(?i)[-.@](ultrafast|fast)(?=(?:-\d{4}-?\d{2}-?\d{2})?$)"#,
                options: .regularExpression
            )
        else { return name }
        return name.replacingCharacters(in: range, with: "-" + name[range].dropFirst().lowercased())
    }

    static func fastBaseName(_ name: String) -> String? {
        guard let range = name.range(of: #"-fast(?=(?:-\d{4}-?\d{2}-?\d{2})?$)"#, options: .regularExpression) else {
            return nil
        }
        return name.replacingCharacters(in: range, with: "")
    }

    /// <base>-fast 모델은 기본 요율에 Fast 배율 적용 — 배율을 모르면 nil.
    /// 기본 요율은 유사 일치로 찾을 수 있음. 배율이 없으면 전용 Fast 단가 확인을 위해 nil 반환.
    private func fastVariant(_ name: String) -> ModelRates? {
        guard let base = Self.fastBaseName(name), !base.isEmpty else { return nil }
        let undatedBase = base.replacingOccurrences(
            of: #"-\d{4}-?\d{2}-?\d{2}$"#, with: "", options: .regularExpression)
        guard let (key, rates) = baseEntry(base) ?? baseEntry(undatedBase) else { return nil }
        let multiplier: Double
        if rates.fastMultiplier != 1 {
            multiplier = rates.fastMultiplier
        } else if let requestedMultiplier = supplement.exactFastMultiplier(for: base) {
            multiplier = supplement.exactFastMultiplier(for: key) ?? requestedMultiplier
        } else if let supplementMultiplier = supplement.legacyFastMultiplier(for: key)
            ?? supplement.legacyFastMultiplier(for: base)
        {
            multiplier = supplementMultiplier
        } else {
            return nil
        }
        return rates.scaled(by: multiplier)
    }

    private func baseEntry(_ base: String) -> (key: String, rates: ModelRates)? {
        if let entry = supplement.pricing[base] { return (base, entry) }
        let unqualified = String(base.split(separator: "/").last ?? Substring(base))
        return primary.findExact(base)
            ?? primary.findExact(unqualified)
            ?? primary.findFuzzy(base, excludingFastVariants: true)
            ?? secondary.findExact(base)
    }
}
