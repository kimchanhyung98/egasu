import Foundation

/// 모델의 백만 토큰당 USD 요율과 선택적 긴 문맥 요율·Fast 배율.
/// 토큰 기반 비용 추정의 공통 가격 자료.
struct ModelRates: Sendable, Equatable {
    var inputPerMillion: Double
    var outputPerMillion: Double
    /// 5분 임시 캐시 쓰기 요율 — 별도 단가가 없으면 입력 요율 사용.
    var cacheWritePerMillion: Double
    var cacheReadPerMillion: Double

    /// 프롬프트가 긴 문맥 기준을 초과하면 요청 전체에 적용하는 요율.
    /// 필드 이름은 above_200k 관례 유지 — 실제 기준은 longContextThresholdTokens.
    var inputAbove200kPerMillion: Double?
    var outputAbove200kPerMillion: Double?
    var cacheWriteAbove200kPerMillion: Double?
    var cacheReadAbove200kPerMillion: Double?

    /// 가격 출처의 캐시 읽기 요율 명시 여부.
    /// 일반 추정용 기본값은 입력 요율의 10% — Codex는 미명시 상태에서 입력 요율 전액 사용.
    var cacheReadIsExplicit: Bool = true

    /// 긴 문맥 요율 적용을 시작하는 프롬프트 토큰 기준.
    var longContextThresholdTokens: Int = 200_000

    /// Fast 변형의 요율 배율 — 기본값은 1.
    var fastMultiplier: Double = 1

    /// 모든 금액 요율에 배율 적용 — Fast 모델을 기본 항목으로 계산할 때 사용.
    func scaled(by factor: Double) -> ModelRates {
        ModelRates(
            inputPerMillion: inputPerMillion * factor,
            outputPerMillion: outputPerMillion * factor,
            cacheWritePerMillion: cacheWritePerMillion * factor,
            cacheReadPerMillion: cacheReadPerMillion * factor,
            inputAbove200kPerMillion: inputAbove200kPerMillion.map { $0 * factor },
            outputAbove200kPerMillion: outputAbove200kPerMillion.map { $0 * factor },
            cacheWriteAbove200kPerMillion: cacheWriteAbove200kPerMillion.map { $0 * factor },
            cacheReadAbove200kPerMillion: cacheReadAbove200kPerMillion.map { $0 * factor },
            cacheReadIsExplicit: cacheReadIsExplicit,
            longContextThresholdTokens: longContextThresholdTokens,
            fastMultiplier: 1
        )
    }
}

/// 요율이 다른 분류별 토큰 수 — 수집기가 전달하는 정규화된 입력.
struct TokenBreakdown: Codable, Sendable, Equatable {
    /// 캐시를 사용하지 않은 일반 입력 토큰.
    var input: Int = 0
    /// 5분 임시 캐시에 기록한 입력 토큰.
    var cacheWrite5m: Int = 0
    /// 1시간 임시 캐시에 기록한 입력 토큰 — 입력 요율의 두 배 적용.
    var cacheWrite1h: Int = 0
    var cacheRead: Int = 0
    var output: Int = 0
    /// 요청 단위 Fast 실행 여부 — Claude 로그의 speed 필드 등에서 확인.
    var isFast: Bool = false

    /// 긴 문맥 판정에 쓰는 입력 토큰 합계 — 출력은 판정에서 제외하고 선택된 요율로 계산.
    var promptTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead }
    var totalTokens: Int { input + cacheWrite5m + cacheWrite1h + cacheRead + output }
}

extension ModelRates {
    /// 1시간 캐시 쓰기는 선택된 입력 요율의 두 배 적용.
    private static let cacheWrite1hInputMultiplier = 2.0

    /// 요청 한 건의 USD 비용 — 요청 전체의 긴 문맥 요율과 Fast 배율 반영.
    /// 요청 경계가 없는 집계 자료는 긴 문맥 요율 적용 생략 가능.
    func costDollars(for tokens: TokenBreakdown, applyLongContextRates: Bool = true) -> Double {
        let multiplier = tokens.isFast ? fastMultiplier : 1
        let useLongContextRates = applyLongContextRates && tokens.promptTokens > longContextThresholdTokens
        let inputRate = selectedRate(base: inputPerMillion, longContext: inputAbove200kPerMillion,
                                     useLongContextRates: useLongContextRates)
        let outputRate = selectedRate(base: outputPerMillion, longContext: outputAbove200kPerMillion,
                                      useLongContextRates: useLongContextRates)
        let cacheWriteRate = selectedRate(base: cacheWritePerMillion, longContext: cacheWriteAbove200kPerMillion,
                                          useLongContextRates: useLongContextRates)
        let cacheReadRate = selectedRate(base: cacheReadPerMillion, longContext: cacheReadAbove200kPerMillion,
                                         useLongContextRates: useLongContextRates)
        let cacheWrite1hRate = selectedRate(
            base: inputPerMillion,
            longContext: inputAbove200kPerMillion,
            useLongContextRates: useLongContextRates
        ) * Self.cacheWrite1hInputMultiplier

        let cost = cost(tokens.input, at: inputRate)
            + cost(tokens.output, at: outputRate)
            + cost(tokens.cacheWrite5m, at: cacheWriteRate)
            + cost(tokens.cacheWrite1h, at: cacheWrite1hRate)
            + cost(tokens.cacheRead, at: cacheReadRate)
        return cost * multiplier
    }

    private func selectedRate(base: Double, longContext: Double?, useLongContextRates: Bool) -> Double {
        useLongContextRates ? (longContext ?? base) : base
    }

    private func cost(_ tokens: Int, at ratePerMillion: Double) -> Double {
        Double(tokens) * ratePerMillion / 1_000_000
    }
}
