import XCTest

@testable import Egasu

final class PricingSupplementLongContextTests: XCTestCase {
    func testLongContextStartsAfterThresholdAndCountsAllPromptBuckets() throws {
        let rates = try XCTUnwrap(makePricing().resolve(model: "tiered-model"))
        let atThreshold = TokenBreakdown(
            input: 40_000, cacheWrite5m: 20_000, cacheWrite1h: 10_000, cacheRead: 30_000, output: 1_000)
        var aboveThreshold = atThreshold
        aboveThreshold.input += 1

        XCTAssertEqual(rates.longContextThresholdTokens, 100_000)
        XCTAssertEqual(rates.costDollars(for: atThreshold), 0.0093, accuracy: 1e-12)
        XCTAssertEqual(rates.costDollars(for: aboveThreshold), 0.0465005, accuracy: 1e-12)
    }

    func testOutputDoesNotSelectLongContextTierAndAggregatedUsageCanOptOut() throws {
        let rates = try XCTUnwrap(makePricing().resolve(model: "tiered-model"))
        XCTAssertEqual(
            rates.costDollars(for: .init(input: 100_000, output: 200_000)), 0.11, accuracy: 1e-12)
        XCTAssertEqual(
            rates.costDollars(for: .init(input: 100_001, output: 1_000), applyLongContextRates: false),
            0.0105001, accuracy: 1e-12)
    }

    func testFastResolutionPreservesThresholdAndScalesAllLongContextRatesOnce() throws {
        let pricing = try makePricing()
        let base = try XCTUnwrap(pricing.resolve(model: "tiered-model"))
        let fast = try XCTUnwrap(pricing.resolve(model: "tiered-model-fast"))
        let tokens = TokenBreakdown(
            input: 40_001, cacheWrite5m: 20_000, cacheWrite1h: 10_000, cacheRead: 30_000,
            output: 1_000, isFast: true)

        XCTAssertEqual(fast.longContextThresholdTokens, 100_000)
        XCTAssertEqual(fast.fastMultiplier, 1)
        XCTAssertEqual(base.costDollars(for: tokens), 0.093001, accuracy: 1e-12)
        XCTAssertEqual(fast.costDollars(for: tokens), 0.093001, accuracy: 1e-12)
    }

    func testLegacyEntriesWithoutLongContextKeepBaseRatesAboveDefaultThreshold() throws {
        let pricing = try makePricing(longContextJSON: nil)
        let rates = try XCTUnwrap(pricing.resolve(model: "tiered-model"))

        XCTAssertNil(rates.longContextThresholdTokens)
        XCTAssertNil(rates.inputAbove200kPerMillion)
        XCTAssertNil(rates.outputAbove200kPerMillion)
        XCTAssertNil(rates.cacheWriteAbove200kPerMillion)
        XCTAssertNil(rates.cacheReadAbove200kPerMillion)
        XCTAssertEqual(rates.costDollars(for: .init(input: 300_000, output: 1_000)), 0.0305, accuracy: 1e-12)
    }

    func testCodexUsesExplicitLongContextThresholdOrItsDefault() throws {
        let cases: [(explicitThreshold: Int?, threshold: Int, at: Double, above: Double)] = [
            (200_000, 200_000, 0.375, 0.745004),
            (500_000, 500_000, 0.975, 1.945004),
            (nil, 272_000, 0.519, 1.033004)
        ]

        for testCase in cases {
            let pricing = try makeCodexPricing(standardThreshold: testCase.explicitThreshold)
            let model = "gpt-6.2-sol"
            let message = "long_context threshold: \(String(describing: testCase.explicitThreshold))"
            let rates = try XCTUnwrap(pricing.resolve(model: model), message)
            XCTAssertEqual(rates.longContextThresholdTokens, testCase.explicitThreshold, message)

            var tokens = TokenBreakdown(
                input: testCase.threshold - 50_000, cacheWrite5m: 25_000, cacheRead: 25_000, output: 1_000)
            let at = try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: tokens, pricing: pricing))
            XCTAssertEqual(at, testCase.at, accuracy: 1e-12, message)

            tokens.input += 1
            let above = try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: tokens, pricing: pricing))
            XCTAssertEqual(above, testCase.above, accuracy: 1e-12, message)
        }
    }

    func testCodexFastAndUltrafastHonorTheirLongContextThresholds() throws {
        let pricing = try makeCodexPricing(standardThreshold: 200_000)
        let cases: [(model: String, isUltrafast: Bool, threshold: Int, at: Double, above: Double)] = [
            ("gpt-6.2-sol", false, 200_000, 0.75, 1.490008),
            ("gpt-6.2-sol-fast", false, 200_000, 0.75, 1.490008),
            ("gpt-6.2-sol", true, 500_000, 5.85, 11.670024),
            ("gpt-6.2-sol-ultrafast", false, 500_000, 5.85, 11.670024)
        ]

        for testCase in cases {
            var tokens = TokenBreakdown(
                input: testCase.threshold - 50_000, cacheWrite5m: 25_000, cacheRead: 25_000,
                output: 1_000, isFast: true)
            let at = try XCTUnwrap(
                CodexUsagePricing.estimate(
                    model: testCase.model, tokens: tokens, pricing: pricing, isUltrafast: testCase.isUltrafast))
            XCTAssertEqual(at, testCase.at, accuracy: 1e-12, testCase.model)

            tokens.input += 1
            let above = try XCTUnwrap(
                CodexUsagePricing.estimate(
                    model: testCase.model, tokens: tokens, pricing: pricing, isUltrafast: testCase.isUltrafast))
            XCTAssertEqual(above, testCase.above, accuracy: 1e-12, testCase.model)
        }
    }

    func testCodexAggregateUsesBaseRatesAboveExplicitLongContextThreshold() throws {
        let pricing = try makeCodexPricing(standardThreshold: 200_000)
        let tokens = TokenBreakdown(input: 300_000, cacheWrite5m: 25_000, cacheRead: 25_000, output: 1_000)
        let record = UsageRecord(
            sourceID: "pi", formatID: "pi-session", granularity: .aggregate, kind: "message",
            providerID: "codex", model: "gpt-6.2-sol", tokens: tokens, totalTokens: tokens.totalTokens)

        guard case .priced(let cost) = CodexUsagePricing.estimateRecord(record, pricing: pricing) else {
            return XCTFail("Expected a cost estimate")
        }
        XCTAssertEqual(cost, 0.675, accuracy: 1e-12)
    }

    func testMalformedLongContextObjectsAreRejected() throws {
        for json in ["null", "[]", "true", "42", "{}"] {
            XCTAssertThrowsError(try makePricing(longContextJSON: json), json)
        }
        for field in [
            "threshold_tokens", "input_per_million", "output_per_million",
            "cache_write_per_million", "cache_read_per_million",
        ] {
            var tier = validLongContext
            tier.removeValue(forKey: field)
            XCTAssertThrowsError(try makePricing(longContextJSON: jsonObject(tier)), field)
        }
    }

    func testInvalidThresholdsAndRatesAreRejected() throws {
        for threshold in [0, -1, 1.5, true, "100000", NSNull()] as [Any] {
            var tier = validLongContext
            tier["threshold_tokens"] = threshold
            XCTAssertThrowsError(try makePricing(longContextJSON: jsonObject(tier)), "\(threshold)")
        }
        for field in [
            "input_per_million", "output_per_million", "cache_write_per_million", "cache_read_per_million",
        ] {
            for rate in [-0.01, true, "0.5", NSNull()] as [Any] {
                var tier = validLongContext
                tier[field] = rate
                XCTAssertThrowsError(try makePricing(longContextJSON: jsonObject(tier)), "\(field): \(rate)")
            }
            let overflowing = try jsonObject(validLongContext).replacingOccurrences(
                of: #""\#(field)"\s*:\s*[0-9.]+"#, with: #""\#(field)":1e309"#,
                options: .regularExpression)
            XCTAssertThrowsError(try makePricing(longContextJSON: overflowing), field)
        }
    }

    func testZeroLongContextRatesAreAccepted() throws {
        var tier = validLongContext
        for field in tier.keys where field != "threshold_tokens" {
            tier[field] = 0
        }
        let rates = try XCTUnwrap(makePricing(longContextJSON: jsonObject(tier)).resolve(model: "tiered-model"))
        XCTAssertEqual(rates.costDollars(for: .init(input: 100_001, output: 1_000)), 0)
    }

    private var validLongContext: [String: Any] {
        [
            "threshold_tokens": 100_000,
            "input_per_million": 0.5,
            "output_per_million": 2.5,
            "cache_write_per_million": 0.625,
            "cache_read_per_million": 0.05,
        ]
    }

    private func jsonObject(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: .sortedKeys), as: UTF8.self)
    }

    private func makeCodexPricing(standardThreshold: Int?) throws -> ModelPricing {
        let longContext =
            standardThreshold.map { threshold in
                """
                , "long_context": {
                  "threshold_tokens": \(threshold), "input_per_million": 4, "output_per_million": 15,
                  "cache_write_per_million": 5, "cache_read_per_million": 0.2
                }
                """
            } ?? ""
        let json = """
            {
              "pricing": {},
              "pricing_v2": {
                "gpt-6.2-sol": {
                  "input_per_million": 2, "output_per_million": 10,
                  "cache_write_per_million": 2.5, "cache_read_per_million": 0.1\(longContext)
                },
                "gpt-6.2-sol-ultrafast": {
                  "input_per_million": 12, "output_per_million": 60,
                  "cache_write_per_million": 15, "cache_read_per_million": 0.6,
                  "long_context": {
                    "threshold_tokens": 500000, "input_per_million": 24, "output_per_million": 90,
                    "cache_write_per_million": 30, "cache_read_per_million": 1.2
                  }
                }
              },
              "fast_multipliers_exact": {"gpt-6.2-sol": 2},
              "alias_rules": []
            }
            """
        return ModelPricing(
            supplement: try PricingSupplement.decode(from: Data(json.utf8)),
            primary: PricingCatalog(), secondary: PricingCatalog())
    }

    private func makePricing(
        longContextJSON: String? = """
            {"threshold_tokens":100000,"input_per_million":0.5,"output_per_million":2.5,
             "cache_write_per_million":0.625,"cache_read_per_million":0.05}
            """
    ) throws -> ModelPricing {
        let longContext = longContextJSON.map { ", \"long_context\": \($0)" } ?? ""
        let json = """
            {
              "pricing": {
                "tiered-model": {
                  "input_per_million": 0.1,
                  "output_per_million": 0.5,
                  "cache_write_per_million": 0.125,
                  "cache_read_per_million": 0.01\(longContext)
                }
              },
              "fast_multipliers_exact": {"tiered-model": 2},
              "alias_rules": []
            }
            """
        return ModelPricing(
            supplement: try PricingSupplement.decode(from: Data(json.utf8)),
            primary: PricingCatalog(), secondary: PricingCatalog())
    }
}
