import XCTest
@testable import Egasu

final class CodexCreditNumberBoundsTests: XCTestCase {
    func testLargeFiniteFlexBalanceKeepsItsCreditAndDollarValues() throws {
        let usage = HTTPResponse(
            statusCode: 200, headers: [:], body: Data(#"{"credits":{"balance":1e100}}"#.utf8))
        let mapped = try CodexUsageMapper.mapUsageResponse(usage)

        guard case .values(_, let values, _, _, _, _) = mapped.lines.first(where: { $0.label == "Credits" }),
            values.count == 2
        else {
            return XCTFail("Expected Flex credit values")
        }
        XCTAssertEqual(values[1].number, 1e100)
        XCTAssertEqual(values[0].number / values[1].number, 0.04, accuracy: 0.000_001)
        for style in [MetricFormatter.Style.tray, .row, .full] {
            XCTAssertFalse(MetricFormatter.string(for: values[1], style: style).isEmpty)
        }
    }

    func testEmbeddedOversizedResetCountIsRejected() {
        for count in [Double(Int.max), 1e100, Double.greatestFiniteMagnitude] {
            let result = CodexUsageMapper.readResetCredits(
                body: ["rate_limit_reset_credits": ["available_count": count]], resetCredits: nil)

            XCTAssertNil(result)
        }
    }

    func testDedicatedOversizedResetCountFallsBackToTheEmbeddedCount() throws {
        let body: [String: Any] = ["rate_limit_reset_credits": ["available_count": 3]]
        for count in [Double(Int.max), 1e100, Double.greatestFiniteMagnitude] {
            let dedicated = HTTPResponse(
                statusCode: 200, headers: [:],
                body: try JSONSerialization.data(withJSONObject: ["available_count": count]))

            XCTAssertNil(CodexUsageMapper.resetCreditsPayload(dedicated))
            XCTAssertEqual(CodexUsageMapper.readResetCredits(body: body, resetCredits: dedicated)?.count, 3)
        }
    }

    func testLargestDisplayableResetCountAndNormalFlooringRemainSupported() throws {
        let largest = Double(Int.max).nextDown
        for (value, expected) in [(largest, Int.max - 1023), (2.8, 2), (0, 0)] {
            let dedicated = HTTPResponse(
                statusCode: 200, headers: [:],
                body: try JSONSerialization.data(withJSONObject: ["available_count": value]))

            XCTAssertNotNil(CodexUsageMapper.resetCreditsPayload(dedicated))
            XCTAssertEqual(CodexUsageMapper.readResetCredits(body: [:], resetCredits: dedicated)?.count, expected)
            XCTAssertEqual(
                CodexUsageMapper.readResetCredits(
                    body: ["rate_limit_reset_credits": ["available_count": value]], resetCredits: nil
                )?.count, expected)
        }
    }

    func testFlexBalancesPreserveZeroClampAndFractionalFlooring() {
        for (balance, expected) in [(-Double.greatestFiniteMagnitude, 0.0), (-0.5, 0), (0, 0), (3.9, 3)] {
            XCTAssertEqual(
                CodexUsageMapper.creditValues(remaining: balance),
                [
                    MetricValue(number: expected * 0.04, kind: .dollars),
                    MetricValue(number: expected, kind: .count, label: "credits")
                ])
        }
    }

    func testFlexCreditHeaderAlsoSupportsLargeFiniteBalances() throws {
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: ["x-codex-credits-balance": "1e100"], body: Data("{}".utf8)))

        guard case .values(_, let values, _, _, _, _) = mapped.lines.first(where: { $0.label == "Credits" }) else {
            return XCTFail("Expected the header Flex balance")
        }
        XCTAssertEqual(values.first(where: { $0.kind == .count })?.number, 1e100)
    }
}
