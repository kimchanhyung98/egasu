import XCTest
@testable import Egasu

final class ZAIDetailMapperTests: XCTestCase {
    func testBundledFreeCachedModelPreservesPaidDailyCost() throws {
        let rates = try XCTUnwrap(TestPricing.bundled.resolve(model: "zai/glm-4.5-flash"))
        XCTAssertTrue(rates.cacheReadIsExplicit)
        XCTAssertEqual(rates.cacheReadPerMillion, 0)
        for cached in [false, true] {
            let parsed = try map(models: [
                model("glm-5.3", input: 1_000_000),
                model("glm-4.5-flash", input: cached ? 0 : 1, cached: cached ? 1 : 0)
            ])
            let day = try XCTUnwrap(parsed.days["2026-11-02"])
            XCTAssertEqual(day.tokens, 1_000_001)
            XCTAssertTrue(day.tokensComplete)
            XCTAssertEqual(try XCTUnwrap(day.costUSD), 1.4, accuracy: 1e-9)
        }
    }

    func testBundledFreeModelRemainsZeroWithCachedInputAndOutput() throws {
        let parsed = try map(models: [model("glm-4.5-flash", input: 1, cached: 1, output: 1)])
        let day = try XCTUnwrap(parsed.days["2026-11-02"])
        XCTAssertEqual(day.tokens, 3)
        XCTAssertTrue(day.tokensComplete)
        XCTAssertEqual(day.costUSD, 0)
    }

    func testUnknownCachedModelStillMakesPaidDailyCostIncomplete() throws {
        let parsed = try map(models: [
            model("glm-5.3", input: 1_000_000),
            model("glm-4.5-flash-unknown", cached: 1)
        ])
        let day = try XCTUnwrap(parsed.days["2026-11-02"])
        XCTAssertEqual(day.tokens, 1_000_001)
        XCTAssertTrue(day.tokensComplete)
        XCTAssertNil(day.costUSD)
    }

    func testAggregateBucketsMatchEveryModelAtEachAxisPosition() throws {
        let parsed = try map(buckets: [
            ["modelCode": "cached_input", "totalTokensUsage": [20, 40]],
            ["modelCode": "uncached_input", "tokensUsage": [60, 80]],
            ["modelCode": "output", "totalTokensUsage": [100, 120]]
        ])
        XCTAssertEqual(parsed.days["2026-11-02"]?.tokens, 420)
        XCTAssertEqual(parsed.days["2026-11-02"]?.tokensComplete, true)
        XCTAssertNotNil(parsed.days["2026-11-02"]?.costUSD)
    }

    func testMismatchedBucketAmountsOrAxisLengthsAreRejected() {
        for code in ["cached_input", "uncached_input", "output"] {
            for values in [[999, 999], [1], [20, 40, 60]] {
                XCTAssertThrowsError(try map(buckets: [["modelCode": code, "totalTokensUsage": values]]), code)
            }
        }
        XCTAssertThrowsError(try map(buckets: [
            ["modelCode": "cached_input", "totalTokensUsage": [40, 20]]
        ]))
    }

    private func model(_ code: String, input: Int = 0, cached: Int = 0, output: Int = 0) -> [String: Any] {
        ["modelCode": code, "cachedInputTokensUsage": [cached],
         "uncachedInputTokensUsage": [input], "outputTokensUsage": [output]]
    }

    private func map(models: [[String: Any]]) throws -> ZAIDetailMapper.Parsed {
        let body = try JSONSerialization.data(withJSONObject: [
            "data": ["modelUsage": ["xTime": ["2026-11-02"], "modelDataList": models]]
        ])
        return try ZAIDetailMapper.map(
            body, window: ZAIDetailWindow(days: ["2026-11-02"], hourly: false), pricing: TestPricing.bundled
        )
    }

    private func map(buckets: [[String: Any]]) throws -> ZAIDetailMapper.Parsed {
        let models = ["glm-4.5", "glm-4.5-air"].map { model -> [String: Any] in
            ["modelCode": model, "cachedInputTokensUsage": [10, 20],
             "uncachedInputTokensUsage": [30, 40], "outputTokensUsage": [50, 60]]
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "data": ["modelUsage": ["xTime": ["00:00:00", "01:00:00"], "modelDataList": buckets + models]]
        ])
        return try ZAIDetailMapper.map(
            body, window: ZAIDetailWindow(days: ["2026-11-02"], hourly: true, hourlyThrough: 1),
            pricing: TestPricing.bundled
        )
    }
}
