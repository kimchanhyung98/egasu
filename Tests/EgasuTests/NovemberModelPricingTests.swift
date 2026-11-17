import XCTest
@testable import Egasu

@MainActor
final class NovemberModelPricingTests: XCTestCase {
    private let pricing = TestPricing.bundled

    func testNewModelsUsePublishedStandardRatesOffline() throws {
        let cases: [(String, Double, Double, Double, Double)] = [
            ("claude-fable-5-2", 8, 10, 0.2, 40),
            ("claude-mythos-5-2", 8, 10, 0.2, 40),
            ("gemini-4-carbon", 4, 4, 0.2, 20),
            ("gemini-4-hydrogen", 1.5, 1.5, 0.075, 7.5)
        ]
        for (model, input, write, read, output) in cases {
            let rates = try XCTUnwrap(pricing.resolve(model: model), model)
            XCTAssertEqual(rates.inputPerMillion, input, accuracy: 1e-9, model)
            XCTAssertEqual(rates.cacheWritePerMillion, write, accuracy: 1e-9, model)
            XCTAssertEqual(rates.cacheReadPerMillion, read, accuracy: 1e-9, model)
            XCTAssertEqual(rates.outputPerMillion, output, accuracy: 1e-9, model)
            XCTAssertTrue(rates.cacheReadIsExplicit, model)
            XCTAssertNil(rates.inputAbove200kPerMillion, model)
        }
    }

    func testClaude52AliasesAndFastSignalChargeTheSameAmount() throws {
        let tokens = TokenBreakdown(
            input: 100_000, cacheWrite5m: 100_000, cacheWrite1h: 100_000,
            cacheRead: 500_000, output: 20_000
        )
        var fastTokens = tokens
        fastTokens.isFast = true
        for family in ["fable", "mythos"] {
            let standard = try XCTUnwrap(pricing.resolve(model: "claude-\(family)-5-2"))
            let fast = try XCTUnwrap(pricing.resolve(model: "claude-\(family)-5-2-fast"))
            for model in [
                "anthropic/claude-\(family)-5.2[1m]-thinking-high",
                "claude-5.2-\(family)-max",
                "claude-\(family)-5-2-20261112"
            ] {
                XCTAssertEqual(pricing.resolve(model: model), standard, model)
                XCTAssertEqual(pricing.resolve(model: model, source: .cursor), standard, model)
            }
            for model in [
                "anthropic/claude-\(family)-5.2-thinking-high-fast",
                "claude-5.2-\(family)-max.fast",
                "claude-\(family)-5-2-fast-20261112"
            ] {
                XCTAssertEqual(pricing.resolve(model: model), fast, model)
            }
            XCTAssertEqual(standard.costDollars(for: tokens), 4.3, accuracy: 1e-9)
            XCTAssertEqual(standard.costDollars(for: fastTokens), 8.6, accuracy: 1e-9)
            XCTAssertEqual(fast.costDollars(for: tokens), 8.6, accuracy: 1e-9)
            XCTAssertEqual(fast.costDollars(for: fastTokens), 8.6, accuracy: 1e-9)
        }
    }

    func testGoogleCLIAndProviderAliasesUseDirectPrices() throws {
        for (model, efforts) in [
            ("gemini-4-carbon", ["low", "medium", "high"]),
            ("gemini-4-hydrogen", ["low", "medium", "high", "xhigh"])
        ] {
            let rates = try XCTUnwrap(pricing.resolve(model: model))
            for prefix in ["", "google/", "gemini/"] {
                for suffix in [""] + efforts.map({ "-" + $0 }) {
                    let alias = prefix + model + suffix
                    XCTAssertEqual(pricing.resolve(model: alias), rates, alias)
                    XCTAssertEqual(pricing.resolve(model: alias, source: .cursor), rates, alias)
                }
            }
        }
    }

    func testCarbonAliasAvoidsResellerCacheRateAndKeepsExplicitReseller() throws {
        let direct = ModelRates(
            inputPerMillion: 4, outputPerMillion: 20,
            cacheWritePerMillion: 4, cacheReadPerMillion: 0.2
        )
        var reseller = direct
        reseller.cacheReadPerMillion = 2
        let isolated = ModelPricing(
            supplement: pricing.supplement,
            primary: PricingCatalog(entries: [
                "gemini/gemini-4-carbon": direct,
                "databricks/databricks-gemini-4-carbon": reseller
            ]),
            secondary: PricingCatalog()
        )

        XCTAssertEqual(isolated.resolve(model: "gemini-4-carbon"), direct)
        XCTAssertEqual(isolated.resolve(model: "gemini-4-carbon-high"), direct)
        XCTAssertEqual(isolated.resolve(model: "databricks/databricks-gemini-4-carbon"), reseller)
    }

    func testGoogleListPricesSurvivePromotionalCatalogRefresh() throws {
        for (model, input, read, output) in [
            ("gemini-4-carbon", 4.0, 0.2, 20.0),
            ("gemini-4-argon", 4.0, 0.2, 20.0),
            ("gemini-3.6-flash", 1.5, 0.15, 7.5),
            ("gemini-3.8-flash", 1.5, 0.15, 7.5)
        ] {
            let promotional = ModelRates(
                inputPerMillion: input / 2, outputPerMillion: output / 2,
                cacheWritePerMillion: input / 2, cacheReadPerMillion: read / 2
            )
            let catalog = PricingCatalog(entries: [model: promotional, "gemini/" + model: promotional])
            let refreshed = ModelPricing(
                supplement: pricing.supplement,
                primary: pricing.primary.merging(catalog),
                secondary: catalog
            )
            for prefix in ["", "google/", "gemini/"] {
                for suffix in ["", "-high"] {
                    let alias = prefix + model + suffix
                    let rates = try XCTUnwrap(refreshed.resolve(model: alias), alias)
                    XCTAssertEqual(rates.inputPerMillion, input, alias)
                    XCTAssertEqual(rates.cacheReadPerMillion, read, alias)
                    XCTAssertEqual(rates.outputPerMillion, output, alias)
                }
            }
        }
    }

    func testSolListPricesKeepCacheFastAndLongContextRatesAfterCatalogRefresh() throws {
        let promotional = ModelRates(
            inputPerMillion: 4, outputPerMillion: 20,
            cacheWritePerMillion: 5, cacheReadPerMillion: 0.4
        )
        let refreshed = ModelPricing(
            supplement: pricing.supplement,
            primary: PricingCatalog(entries: [
                "gpt-5.6-sol": promotional,
                "openai/gpt-5.6-sol": promotional,
                "gpt-5.6-sol-fast": promotional.scaled(by: 2)
            ]),
            secondary: pricing.secondary
        )
        let standard = try XCTUnwrap(refreshed.resolve(model: "gpt-5.6-sol"))
        let fast = try XCTUnwrap(refreshed.resolve(model: "gpt-5.6-sol-fast"))
        XCTAssertEqual(standard.inputPerMillion, 5)
        XCTAssertEqual(standard.cacheWritePerMillion, 6.25)
        XCTAssertEqual(standard.cacheReadPerMillion, 0.5)
        XCTAssertEqual(standard.outputPerMillion, 30)
        for model in ["gpt-5.6", "openai/gpt-5.6-sol-high", "openai/gpt-5.6-sol-2026-07-09"] {
            XCTAssertEqual(refreshed.resolve(model: model), standard, model)
        }
        for model in ["gpt-5.6-ultra-fast", "openai/gpt-5.6-sol-high.fast", "gpt-5.6-sol-fast-20260709"] {
            XCTAssertEqual(refreshed.resolve(model: model), fast, model)
        }
        let boundary = TokenBreakdown(input: 200_000, cacheWrite5m: 22_000, cacheRead: 50_000, output: 10_000)
        var over = boundary
        over.input += 1
        XCTAssertEqual(standard.costDollars(for: boundary), 1.4625, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: boundary), 2.925, accuracy: 1e-9)
        for model in ["gpt-5.6-sol", "openai/gpt-5.6-sol", "openai/gpt-5.6-sol-2026-07-09"] {
            XCTAssertEqual(
                try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: boundary, pricing: refreshed)),
                1.4625, accuracy: 1e-9, model
            )
            XCTAssertEqual(
                try XCTUnwrap(CodexUsagePricing.estimate(model: model, tokens: over, pricing: refreshed)),
                2.77501, accuracy: 1e-9, model
            )
            XCTAssertEqual(
                try XCTUnwrap(CodexUsagePricing.estimate(model: model + "-fast", tokens: over, pricing: refreshed)),
                5.55002, accuracy: 1e-9, model
            )
        }
        var fastTokens = boundary
        fastTokens.isFast = true
        XCTAssertEqual(standard.costDollars(for: fastTokens), 2.925, accuracy: 1e-9)
        XCTAssertEqual(fast.costDollars(for: fastTokens), 2.925, accuracy: 1e-9)
    }

    func testKimiFastKeepsFireworksRatesWhenBareCatalogKeyChangesSeller() throws {
        let fireworksKey = "fireworks_ai/accounts/fireworks/routers/kimi-k3-fast"
        let fireworks = try XCTUnwrap(pricing.primary.findExact(fireworksKey)?.rates)
        let reseller = fireworks.scaled(by: 0.9)
        let isolated = ModelPricing(
            supplement: pricing.supplement,
            primary: PricingCatalog(entries: [fireworksKey: fireworks]),
            secondary: PricingCatalog(entries: [
                "kimi-k3-fast": reseller,
                "reseller/kimi-k3-fast": reseller
            ])
        )

        XCTAssertEqual(pricing.supplement.canonicalName(for: "kimi-k3-fast"), fireworksKey)
        XCTAssertEqual(isolated.resolve(model: "kimi-k3-fast"), fireworks)
        XCTAssertEqual(isolated.resolve(model: "kimi-k3-fast", source: .cursor), fireworks)
        XCTAssertEqual(isolated.resolve(model: "reseller/kimi-k3-fast"), reseller)
    }

    func testUnregisteredVariantsDoNotInheritNewModelAliases() {
        for model in [
            "gemini-4-carbon-audio", "gemini-4-carbon-fast", "gemini-4-carbon-xhigh",
            "gemini-4-carbon-cyber-permissive", "gemini-4-hydrogen-max",
            "claude-fable-5-2-ultrafast", "claude-mythos-5-2-audio",
            "claude-fable-5-3", "other/claude-fable-5-2"
        ] {
            XCTAssertNil(pricing.supplement.canonicalName(for: model), model)
        }
        XCTAssertNil(pricing.resolve(model: "gemini-4-carbon-audio"))
        XCTAssertNil(pricing.resolve(model: "claude-fable-5-2-ultrafast"))
    }

    func testCursorNewModelsKeepReportedCostAndReadableFamilies() throws {
        let now = Date(timeIntervalSince1970: 1_794_700_800)
        let rows = ["gemini-4-carbon-high", "gemini-4-hydrogen-xhigh", "claude-fable-5.2-high", "kimi-k3-fast"].map {
            CursorUsageEvent(date: now, model: $0, tokens: TokenBreakdown(input: 100_000), costUSD: 0.17)
        }
        var lines: [MetricLine] = []
        let history = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: pricing, to: &lines)
        let models = try XCTUnwrap(history.modelUsage?.daily.first?.models)
        XCTAssertEqual(
            Set(models.map(\.model)), ["gemini-4-carbon", "gemini-4-hydrogen", "claude-fable-5-2", "kimi-k3"])
        XCTAssertEqual(models.map(\.costUSD), Array(repeating: 0.17, count: 4))
    }

    func testAntigravityNewModelsRestoreDailyCostsWithBundledPricing() async throws {
        let now = Date(timeIntervalSince1970: 1_794_700_800)
        let db = try AntigravityScannerDatabase()
        defer { db.remove() }
        try db.model(index: 0, name: "gemini-4-carbon-high")
        try db.model(index: 1, name: "gemini-4-hydrogen-xhigh")
        try db.step(index: 1, date: now, input: 100_000, output: 10_000, cacheRead: 900_000)
        try db.step(index: 2, date: now, input: 100_000, output: 10_000, cacheRead: 900_000, metadataIndex: 1)
        let scanner = AntigravityUsageScanner(databasePaths: { [db.path] })

        let unpriced = try await scanner.scan(now: now, pricing: .empty)
        XCTAssertNil(unpriced?.series.daily.first?.costUSD)
        let priced = try await scanner.scan(now: now, pricing: pricing)

        XCTAssertEqual(priced?.series.daily.first?.totalTokens, 2_020_000)
        XCTAssertEqual(try XCTUnwrap(priced?.series.daily.first?.costUSD), 1.0725, accuracy: 1e-9)
        XCTAssertEqual(priced?.unknownModelsByDay, [:])
    }
}
