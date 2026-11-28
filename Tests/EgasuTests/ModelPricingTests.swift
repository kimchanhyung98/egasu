import XCTest
@testable import Egasu

final class ModelPricingTests: XCTestCase {
    private func makePricing(
        supplementJSON: String? = nil,
        primary: [String: ModelRates] = [:],
        secondary: [String: ModelRates] = [:]
    ) throws -> ModelPricing {
        let supplement: PricingSupplement
        if let supplementJSON {
            supplement = try PricingSupplement.decode(from: Data(supplementJSON.utf8))
        } else {
            supplement = PricingSupplement()
        }
        return ModelPricing(
            supplement: supplement,
            primary: PricingCatalog(entries: primary),
            secondary: PricingCatalog(entries: secondary)
        )
    }

    private func rates(
        _ input: Double, _ output: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil,
        fast: Double = 1
    ) -> ModelRates {
        ModelRates(
            inputPerMillion: input,
            outputPerMillion: output,
            cacheWritePerMillion: cacheWrite ?? input,
            cacheReadPerMillion: cacheRead ?? input * 0.1,
            fastMultiplier: fast
        )
    }

    // MARK: - Resolution

    func testExactMatchWins() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5")?.inputPerMillion, 5)
    }

    func testDateSuffixFuzzyMatch() throws {
        let pricing = try makePricing(primary: ["claude-sonnet-4-20250514": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4")?.inputPerMillion, 3)
    }

    func testModelWithDateSuffixResolvesUndatedKey() throws {
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-sonnet-4-5-20250929")?.inputPerMillion, 3)
    }

    func testNumericVersionsDoNotConflate() throws {
        // claude-sonnet-4와 claude-sonnet-4-5는 상호 매칭 금지
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertNil(pricing.resolve(model: "claude-sonnet-4"))
        let reverse = try makePricing(primary: ["claude-sonnet-4": rates(1, 2)])
        XCTAssertNil(reverse.resolve(model: "claude-sonnet-4-5"))
    }

    func testProviderPrefixFuzzyMatch() throws {
        let pricing = try makePricing(primary: ["xai/grok-4.3": rates(1.25, 2.5)])
        XCTAssertEqual(pricing.resolve(model: "grok-4.3")?.inputPerMillion, 1.25)
    }

    func testSeparatorNormalizationMatch() throws {
        // log slug grok-4-3(dash)이 catalog key xai/grok-4.3(dot)에 매칭
        let pricing = try makePricing(primary: ["xai/grok-4.3": rates(1.25, 2.5)])
        XCTAssertEqual(pricing.resolve(model: "grok-4-3")?.inputPerMillion, 1.25)
    }

    func testLongestKeyPreferred() throws {
        let pricing = try makePricing(primary: [
            "gemini-3-pro": rates(1, 2),
            "gemini/gemini-3-pro-preview": rates(2, 12)
        ])
        XCTAssertEqual(pricing.resolve(model: "gemini-3-pro-preview")?.inputPerMillion, 2)
    }

    func testSecondaryCatalogFillsGaps() throws {
        let pricing = try makePricing(
            primary: ["gpt-5.5": rates(5, 30)],
            secondary: ["grok-build-0.1": rates(1, 2)]
        )
        XCTAssertEqual(pricing.resolve(model: "grok-build-0.1")?.inputPerMillion, 1)
    }

    func testUnknownModelReturnsNil() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        XCTAssertNil(pricing.resolve(model: "made-up-model-9000"))
    }

    func testUnregisteredModelSuffixesDoNotInheritBaseRates() throws {
        let pricing = try makePricing(primary: ["vendor/custom": rates(2, 10, fast: 3)])
        for suffix in ["-unrecognized", "-contributor", "-preview", "-20261106-custom"] {
            for prefix in ["", "vendor/"] {
                XCTAssertNil(pricing.resolve(model: prefix + "custom" + suffix))
                XCTAssertNil(pricing.resolve(model: prefix + "custom" + suffix + "-fast"))
            }
        }
    }

    func testBothDateSuffixSpellingsPreserveBaseRates() throws {
        for date in ["20261106", "2026-11-06"] {
            let dated = try makePricing(primary: ["vendor/custom-" + date: rates(2, 10)])
            let undated = try makePricing(primary: ["custom": rates(2, 10)])
            XCTAssertEqual(dated.resolve(model: "custom")?.inputPerMillion, 2)
            XCTAssertEqual(undated.resolve(model: "custom-" + date)?.inputPerMillion, 2)
        }
    }

    func testFineTunedIDsUseRegisteredFineTunedRates() throws {
        let pricing = try makePricing(primary: [
            "ft:gpt-4.1-nano-2025-04-14": rates(3, 12),
            "gpt-4.1-nano-2025-04-14": rates(1, 4),
            "vendor/custom": rates(2, 10)
        ])
        for name in [
            "ft:gpt-4.1-nano-2025-04-14:openai::BTz2REMH",
            "openai/ft:gpt-4.1-nano-2025-04-14:my-org:custom:identifier:ckpt-step-2000"
        ] {
            XCTAssertEqual(pricing.resolve(model: name)?.inputPerMillion, 3, name)
        }
        XCTAssertNil(pricing.resolve(model: "vendor/custom:unregistered"))
        XCTAssertNil(pricing.resolve(model: "ft:gpt-4.1-nano-2025-04-14-unregistered"))
    }

    func testRegisteredProviderDateRevisionsKeepFuzzyRates() throws {
        for date in ["20240229", "2024-02-29"] {
            for prefix in ["bedrock/anthropic.", "anthropic/"] {
                let dated = "claude-3-opus-" + date
                let key = prefix + dated + "-v1:0"
                let pricing = try makePricing(primary: [key: rates(15, 75)])
                for model in [key, "claude-3-opus", dated, prefix + dated] {
                    XCTAssertEqual(pricing.resolve(model: model)?.inputPerMillion, 15, model)
                }
                XCTAssertNil(pricing.resolve(model: dated + "-v2:0"))
                XCTAssertNil(pricing.resolve(model: dated + "-v1:0-preview"))
            }
            let unversioned = try makePricing(primary: ["claude-3-opus-" + date: rates(15, 75)])
            XCTAssertNil(unversioned.resolve(model: "claude-3-opus-" + date + "-v1:0"))
        }
    }

    // MARK: - Supplement precedence, aliases, fast multipliers

    func testSupplementPricingBeatsCatalogs() throws {
        let supplement = """
        {"pricing": {"auto": {"input_per_million": 1.25, "output_per_million": 6.0, "cache_read_per_million": 0.25}}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["auto": rates(99, 99)])
        XCTAssertEqual(pricing.resolve(model: "auto")?.inputPerMillion, 1.25)
        XCTAssertEqual(pricing.resolve(model: "auto")?.cacheWritePerMillion, 1.25, "cache write defaults to input")
    }

    func testAliasRuleRewritesSlug() throws {
        let supplement = """
        {"pricing": {}, "alias_rules": [
            {"pattern": "^claude-4\\\\.5-sonnet(?:-thinking)?$", "canonical": "claude-sonnet-4-5"}
        ]}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["claude-sonnet-4-5": rates(3, 15)])
        XCTAssertEqual(pricing.resolve(model: "claude-4.5-sonnet-thinking")?.inputPerMillion, 3)
    }

    func testNeonAliasesKeepDirectPricesAndProviderBoundaries() {
        let direct = rates(3, 15, cacheRead: 0.15)
        let reseller = rates(6, 30, cacheRead: 3)
        let pricing = ModelPricing(
            supplement: TestPricing.bundled.supplement,
            primary: PricingCatalog(entries: [
                "gemini/gemini-4-neon": direct,
                "databricks/system.ai.gemini-4-neon": reseller,
                "vertex_ai/gemini-4-neon": reseller
            ]),
            secondary: PricingCatalog()
        )
        for prefix in ["", "google/", "gemini/"] {
            for suffix in ["", "-low", "-medium", "-high", "-xhigh"] {
                let model = prefix + "gemini-4-neon" + suffix
                XCTAssertEqual(pricing.resolve(model: model, source: .api), direct, model)
            }
            let unknown = prefix + "gemini-4-neon-unregistered"
            XCTAssertNil(pricing.resolve(model: unknown, source: .api), unknown)
        }
        XCTAssertEqual(pricing.resolve(model: "Google/Gemini-4-Neon-XHigh"), direct)
        for model in ["databricks/system.ai.gemini-4-neon", "vertex_ai/gemini-4-neon"] {
            XCTAssertNil(pricing.supplement.canonicalName(for: model), model)
            XCTAssertEqual(pricing.resolve(model: model, source: .api), reseller, model)
            XCTAssertNil(pricing.resolve(model: model + "-xhigh", source: .api), model)
        }
    }

    func testBundledDaybreakAliasesResolveToCurrentModels() throws {
        let pricing = TestPricing.bundled
        let aliasesByCanonical = [
            (
                canonical: "gpt-5.6-sol",
                aliases: [
                    "daybreak-blue-latest",
                    "gpt-daybreak-blue-latest",
                    "openai/daybreak-blue-latest",
                    "openai/gpt-daybreak-blue-latest"
                ]
            ),
            (
                canonical: "gpt-5.6-cyber",
                aliases: [
                    "daybreak-red-latest",
                    "gpt-daybreak-red-latest",
                    "openai/daybreak-red-latest",
                    "openai/gpt-daybreak-red-latest"
                ]
            )
        ]

        for entry in aliasesByCanonical {
            let expected = try XCTUnwrap(pricing.resolve(model: entry.canonical))
            for alias in entry.aliases {
                XCTAssertEqual(pricing.resolve(model: alias), expected, alias)
            }
        }

        XCTAssertEqual(
            pricing.resolve(model: "OpenAI/GPT-Daybreak-Blue-Latest"),
            pricing.resolve(model: "gpt-5.6-sol")
        )
    }

    func testBundledGPT56AliasResolvesAsSol() {
        let pricing = TestPricing.bundled
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-high"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-ultra"), pricing.resolve(model: "gpt-5.6-sol"))
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-high-fast"), pricing.resolve(model: "gpt-5.6-sol-fast"))
        XCTAssertEqual(pricing.resolve(model: "gpt-5.6-ultra-fast"), pricing.resolve(model: "gpt-5.6-sol-fast"))
    }

    func testAliasMissFallsBackToRawName() throws {
        let supplement = """
        {"pricing": {}, "alias_rules": [{"pattern": "^gpt-x$", "canonical": "key-not-anywhere"}]}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-x": rates(1, 2)])
        XCTAssertEqual(pricing.resolve(model: "gpt-x")?.inputPerMillion, 1)
    }

    func testFastSuffixUsesSupplementMultiplier() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-5.5": rates(5, 30, cacheRead: 0.5)])
        let fast = pricing.resolve(model: "gpt-5.5-fast")
        XCTAssertEqual(fast?.inputPerMillion, 12.5)
        XCTAssertEqual(fast?.outputPerMillion, 75)
        XCTAssertEqual(fast?.cacheReadPerMillion, 1.25)
    }

    func testFastSuffixUsesEntryMultiplier() throws {
        let pricing = try makePricing(primary: ["claude-opus-4-6": rates(5, 25, fast: 6)])
        let fast = pricing.resolve(model: "claude-opus-4-6-fast")
        XCTAssertEqual(fast?.inputPerMillion, 30)
        XCTAssertEqual(fast?.fastMultiplier, 1, "multiplier folded into the scaled rates")
    }

    func testFastSuffixWithoutMultiplierReturnsNil() throws {
        let pricing = try makePricing(primary: ["gpt-9": rates(1, 2)])
        XCTAssertNil(pricing.resolve(model: "gpt-9-fast"))
    }

    func testAlternateTerminalFastSeparatorsApplyMultiplierOrRemainUnpriced() throws {
        for suffix in ["-fast", ".fast", "@fast"] {
            let priced = try makePricing(primary: ["gpt-9.5": rates(5, 30, fast: 2.5)])
            XCTAssertEqual(priced.resolve(model: "gpt-9.5" + suffix)?.inputPerMillion, 12.5)
            let pricedWithSecondary = try makePricing(primary: ["gpt-9.5": rates(5, 30, fast: 2.5)], secondary: ["gpt-9.5" + suffix: rates(7, 21)])
            XCTAssertEqual(pricedWithSecondary.resolve(model: "gpt-9.5" + suffix)?.inputPerMillion, 12.5, "Primary pricing retains precedence when its fast multiplier is known")
            let unknown = try makePricing(primary: ["gpt-9.5": rates(5, 30)])
            XCTAssertNil(unknown.resolve(model: "gpt-9.5" + suffix))
            let secondary = try makePricing(primary: ["gpt-9.5": rates(5, 30)], secondary: ["gpt-9.5" + suffix: rates(7, 21)])
            XCTAssertEqual(secondary.resolve(model: "gpt-9.5" + suffix)?.inputPerMillion, 7)
            let exact = try makePricing(primary: ["gpt-9.5": rates(5, 30, fast: 2.5), "gpt-9.5" + suffix: rates(9, 27)])
            XCTAssertEqual(exact.resolve(model: "gpt-9.5" + suffix)?.inputPerMillion, 9)
        }
    }

    func testFastSuffixWithoutMultiplierUsesSecondaryExactEntry() throws {
        let pricing = try makePricing(
            primary: ["gpt-9": rates(1, 2)],
            secondary: ["gpt-9-fast": rates(2.5, 5)]
        )
        XCTAssertEqual(pricing.resolve(model: "gpt-9-fast")?.inputPerMillion, 2.5)
    }

    func testDatedBaseKeyStillFindsFastMultiplier() throws {
        let supplement = """
        {"pricing": {}, "fast_multipliers": {"gpt-5.5": 2.5}, "alias_rules": []}
        """
        let pricing = try makePricing(supplementJSON: supplement, primary: ["gpt-5.5-20260423": rates(5, 30)])
        XCTAssertEqual(pricing.resolve(model: "gpt-5.5-fast")?.inputPerMillion, 12.5)
    }

    func testCatalogCodecsPreserveSynthesizedCacheReadProvenance() throws {
        let source = Data(#"""
        {
            "explicit": {
                "input_cost_per_token": 0.000005,
                "output_cost_per_token": 0.00003,
                "cache_read_input_token_cost": 0.0000005
            },
            "missing": {
                "input_cost_per_token": 0.000005,
                "output_cost_per_token": 0.00003
            }
        }
        """#.utf8)

        let decoded = try PricingCatalogCodecs.catalogFromLiteLLM(source)
        XCTAssertTrue(try XCTUnwrap(decoded.entries["explicit"]).cacheReadIsExplicit)
        XCTAssertFalse(try XCTUnwrap(decoded.entries["missing"]).cacheReadIsExplicit)

        let restored = try PricingCatalogCodecs.catalogFromCompact(
            PricingCatalogCodecs.compactData(from: decoded)
        )
        XCTAssertTrue(try XCTUnwrap(restored.entries["explicit"]).cacheReadIsExplicit)
        XCTAssertFalse(try XCTUnwrap(restored.entries["missing"]).cacheReadIsExplicit)
    }

    func testPublicCatalogsSkipInvalidRequiredRatesAndKeepValidModels() throws {
        let liteLLM = Data(
            """
            {
                "lite-bool": {"input_cost_per_token": true, "output_cost_per_token": 0.000005},
                "lite-negative": {"input_cost_per_token": 0.000005, "output_cost_per_token": -0.000002},
                "lite-overflow": {"input_cost_per_token": 1e303, "output_cost_per_token": 0.000005},
                "lite-string": {"input_cost_per_token": "0.000005", "output_cost_per_token": 0.00001},
                "lite-free": {"input_cost_per_token": 0, "output_cost_per_token": 0},
                "lite-paid": {"input_cost_per_token": 0.000005, "output_cost_per_token": 0.00001}
            }
            """.utf8)
        let modelsDev = Data(
            """
            {"provider":{"models":{
                "dev-bool": {"cost":{"input":1,"output":false}},
                "dev-negative": {"cost":{"input":-2.5,"output":4.5}},
                "dev-string": {"cost":{"input":"1","output":2}},
                "dev-free": {"cost":{"input":0,"output":0}},
                "dev-paid": {"cost":{"input":2,"output":4}}
            }}}
            """.utf8)
        let primary = try PricingCatalogCodecs.catalogFromLiteLLM(liteLLM)
        let secondary = try PricingCatalogCodecs.catalogFromModelsDev(modelsDev)
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: try PricingCatalogCodecs.catalogFromCompact(PricingCatalogCodecs.compactData(from: primary)),
            secondary: try PricingCatalogCodecs.catalogFromCompact(PricingCatalogCodecs.compactData(from: secondary))
        )

        XCTAssertEqual(Set(pricing.primary.entries.keys), ["lite-free", "lite-paid"])
        XCTAssertEqual(Set(pricing.secondary.entries.keys), ["dev-free", "dev-paid"])
        let tokens = TokenBreakdown(input: 1_000_000, output: 1_000_000)
        for model in [
            "lite-bool", "lite-negative", "lite-overflow", "lite-string", "dev-bool", "dev-negative", "dev-string"
        ] {
            XCTAssertNil(pricing.estimatedCostDollars(model: model, tokens: tokens), model)
        }
        XCTAssertEqual(pricing.estimatedCostDollars(model: "lite-free", tokens: tokens), 0)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "dev-free", tokens: tokens), 0)
        XCTAssertEqual(
            try XCTUnwrap(pricing.estimatedCostDollars(model: "lite-paid", tokens: tokens)), 15, accuracy: 1e-9)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "dev-paid", tokens: tokens), 6)
    }

    func testPublicCatalogsUseDefaultsForInvalidOptionalRates() throws {
        let liteLLM = Data(
            """
            {"lite-model":{
                "input_cost_per_token":0.000005,"output_cost_per_token":0.00003,
                "cache_creation_input_token_cost":true,"cache_read_input_token_cost":-0.000002,
                "input_cost_per_token_above_200k_tokens":1e303,
                "output_cost_per_token_above_200k_tokens":-0.00003,
                "cache_creation_input_token_cost_above_200k_tokens":false,
                "cache_read_input_token_cost_above_200k_tokens":"NaN",
                "provider_specific_entry":{"fast":-2}
            }}
            """.utf8)
        let modelsDev = Data(
            """
            {"provider":{"models":{
                "dev-model":{"cost":{"input":5,"output":30,"cache_write":-1,"cache_read":true}},
                "dev-free-cache":{"cost":{"input":5,"output":30,"cache_read":0}}
            }}}
            """.utf8)
        let expected = ModelRates(
            inputPerMillion: 5, outputPerMillion: 30, cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.5, cacheReadIsExplicit: false)
        let liteRates = try XCTUnwrap(PricingCatalogCodecs.catalogFromLiteLLM(liteLLM).entries["lite-model"])
        let dev = try PricingCatalogCodecs.catalogFromModelsDev(modelsDev)
        let freeCache = try XCTUnwrap(dev.entries["dev-free-cache"])

        XCTAssertEqual(liteRates, expected)
        XCTAssertEqual(dev.entries["dev-model"], expected)
        XCTAssertEqual(freeCache.cacheReadPerMillion, 0)
        XCTAssertTrue(freeCache.cacheReadIsExplicit)
    }

    func testCompactCatalogRejectsPreviouslyCachedNegativeRates() throws {
        let data = Data(
            """
            {"models":{
                "invalid-model":{"i":-2,"o":30,"cw":5,"cr":0.5},
                "valid-model":{"i":5,"o":30,"cw":-2,"cr":-1,"ia":-3,"oa":-4,"cwa":-2,"cra":-1,"fast":-2}
            }}
            """.utf8)
        let catalog = try PricingCatalogCodecs.catalogFromCompact(data)

        XCTAssertNil(catalog.entries["invalid-model"])
        XCTAssertEqual(
            catalog.entries["valid-model"],
            ModelRates(
                inputPerMillion: 5, outputPerMillion: 30, cacheWritePerMillion: 5,
                cacheReadPerMillion: 0.5, cacheReadIsExplicit: false))
    }

    func testLegacyCompactCatalogTreatsUnmarkedCacheReadAsExplicit() throws {
        // `cre` 도입 이전 snapshot은 source/synthesized 구분 불가 — 생략을 explicit으로 취급해 기존 동작 유지
        let legacy = Data(#"{"models":{"gpt-test":{"i":5,"o":30,"cw":5,"cr":0.5}}}"#.utf8)

        let decoded = try PricingCatalogCodecs.catalogFromCompact(legacy)

        XCTAssertTrue(try XCTUnwrap(decoded.entries["gpt-test"]).cacheReadIsExplicit)
    }

    // MARK: - Cost math

    func testCostUsesAllTokenBuckets() throws {
        let entry = ModelRates(
            inputPerMillion: 3, outputPerMillion: 15,
            cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3
        )
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 1_000_000, cacheWrite5m: 1_000_000, cacheWrite1h: 1_000_000, cacheRead: 1_000_000, output: 1_000_000)
        // 계산: 입력 3 + cacheWrite5m 3.75 + cacheWrite1h(3x2=6) + cacheRead 0.3 + 출력 15 = 28.05
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 28.05, accuracy: 0.0001)
    }

    func testCostAbove200kUsesHigherRateForWholeRequest() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 300_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 1.8, accuracy: 0.0001)
    }

    func testCombinedPromptBucketsSelectLongContextRatesForEveryBucket() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        entry.cacheWriteAbove200kPerMillion = 7.5
        entry.cacheReadAbove200kPerMillion = 0.6
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 100_000, cacheWrite5m: 60_000, cacheRead: 50_000, output: 20_000)

        // 210k prompt는 input·cache·output 전부 상위 tier 선택
        let expected = 0.6 + 0.45 + 0.03 + 0.45
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, expected, accuracy: 0.0001)
    }

    func testLargeOutputAloneDoesNotSelectLongContextRates() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 10_000, output: 300_000)

        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 4.53, accuracy: 0.0001)
    }

    func testExactly200kPromptKeepsBaseRates() throws {
        var entry = ModelRates(inputPerMillion: 3, outputPerMillion: 15, cacheWritePerMillion: 3.75, cacheReadPerMillion: 0.3)
        entry.inputAbove200kPerMillion = 6
        entry.outputAbove200kPerMillion = 22.5
        let pricing = try makePricing(primary: ["claude-sonnet-4-5": entry])
        let tokens = TokenBreakdown(input: 200_000, output: 10_000)

        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-sonnet-4-5", tokens: tokens)!, 0.75, accuracy: 0.0001)
    }

    func testCustomLongContextThresholdUsesWholeRequestRates() {
        var entry = ModelRates(
            inputPerMillion: 5,
            outputPerMillion: 30,
            cacheWritePerMillion: 5,
            cacheReadPerMillion: 0.5
        )
        entry.inputAbove200kPerMillion = 10
        entry.outputAbove200kPerMillion = 45
        entry.cacheReadAbove200kPerMillion = 1
        entry.longContextThresholdTokens = 272_000

        let atThreshold = TokenBreakdown(input: 200_000, cacheRead: 72_000, output: 1_000)
        let overThreshold = TokenBreakdown(input: 200_001, cacheRead: 72_000, output: 1_000)

        XCTAssertEqual(entry.costDollars(for: atThreshold), 1.066, accuracy: 0.000_001)
        XCTAssertEqual(entry.costDollars(for: overThreshold), 2.117_01, accuracy: 0.000_001)
    }

    func testCostWithoutTierRatesUsesBaseRateThroughout() throws {
        let pricing = try makePricing(primary: ["gpt-5.5": rates(5, 30)])
        let tokens = TokenBreakdown(input: 300_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "gpt-5.5", tokens: tokens)!, 1.5, accuracy: 0.0001)
    }

    func testFastSpeedAppliesEntryMultiplier() throws {
        let pricing = try makePricing(primary: ["claude-opus-4-6": rates(5, 25, fast: 6)])
        var tokens = TokenBreakdown(input: 1_000_000)
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-opus-4-6", tokens: tokens)!, 5, accuracy: 0.0001)
        tokens.isFast = true
        XCTAssertEqual(pricing.estimatedCostDollars(model: "claude-opus-4-6", tokens: tokens)!, 30, accuracy: 0.0001)
    }

    func testUnknownModelCostIsNil() throws {
        let pricing = try makePricing()
        XCTAssertNil(pricing.estimatedCostDollars(model: "mystery", tokens: TokenBreakdown(input: 100)))
    }
}
