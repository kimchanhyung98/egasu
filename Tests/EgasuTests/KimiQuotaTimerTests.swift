import Foundation
import XCTest
@testable import Egasu

@MainActor
final class KimiQuotaTimerTests: XCTestCase {
    func testMonthlyTotalExhaustionBlocksSessionTimer() async throws {
        let provider = try makeProvider(monthlyTotal: 1, monthlyCode: 0.2)

        let snapshot = await provider.quotaSnapshot()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(
            snapshot.lines.first { $0.label == "Total Usage" },
            .progress(label: "Total Usage", used: 100, limit: 100, format: .percent))
        XCTAssertTrue(provider.usageTimerObservations.isEmpty)
        XCTAssertNil(provider.usageTimerCredential)
    }

    func testMonthlyCodeContributionIsNotAnIndependentTimerLimit() async throws {
        let provider = try makeProvider(monthlyTotal: nil, monthlyCode: 1)

        let snapshot = await provider.quotaSnapshot()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.lines.map(\.label), ["Session"])
        XCTAssertEqual(provider.usageTimerObservations.map(\.timerID), ["kimi.session"])
        XCTAssertNotNil(provider.usageTimerCredential)
    }

    func testExtraSpendingCapDoesNotBlockRemainingSubscriptionQuota() async throws {
        let provider = try makeProvider(monthlyTotal: 0.25, monthlyCode: 0.2, extraCapExhausted: true)

        let snapshot = await provider.quotaSnapshot()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(
            snapshot.lines.first { $0.label == "Extra Usage" },
            .progress(label: "Extra Usage", used: 10, limit: 10, format: .dollars))
        XCTAssertEqual(provider.usageTimerObservations.map(\.timerID), ["kimi.session"])
        XCTAssertNotNil(provider.usageTimerCredential)
    }

    private func makeProvider(
        monthlyTotal: Double?, monthlyCode: Double, extraCapExhausted: Bool = false
    ) throws -> KimiProvider {
        var usages: [String: Any] = [
            "limit_5h": ["used_ratio": 0, "reset_time": "1970-01-01T05:00:00Z"],
            "limit_month_code": ["used_ratio": monthlyCode]
        ]
        if let monthlyTotal { usages["limit_month_total"] = ["used_ratio": monthlyTotal] }
        var payload: [String: Any] = ["usages": usages]
        if extraCapExhausted {
            payload["booster_wallet"] = [
                "balance": ["type": "BOOSTER", "amount": "1000000000", "amountLeft": "500000000"],
                "monthlyChargeLimitEnabled": true,
                "monthlyUsed": ["currency": "USD", "priceInCents": "1000"],
                "monthlyChargeLimit": ["currency": "USD", "priceInCents": "1000"]
            ]
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "KimiQuotaTimerTests-\(UUID().uuidString)")
        let jwt = "e30." + Data(#"{"sub":"test-account"}"#.utf8).base64EncodedString() + ".signature"
        let files = FakeFiles([
            root.appendingPathComponent("credentials/kimi-code.json").path:
                #"{"access_token":"\#(jwt)","expires_at":9000}"#
        ])
        return KimiProvider(
            authStore: KimiAuthStore(
                files: files, environment: FakeEnvironment(["KIMI_CODE_HOME": root.path]), homeDirectory: { root }),
            usageClient: KimiUsageClient(
                http: KimiQuotaTimerHTTP(body: try JSONSerialization.data(withJSONObject: payload))),
            now: { Date(timeIntervalSince1970: 2_000) }, pricing: { .empty }
        )
    }
}

private struct KimiQuotaTimerHTTP: HTTPClient {
    let body: Data

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: body)
    }
}
