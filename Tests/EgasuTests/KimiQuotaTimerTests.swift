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

    func testExhaustedTimerReadCannotReuseAnOverlappingSuccessfulQuota() async throws {
        let suspended = expectation(description: "Timer quota request suspended")
        let http = OverlappingKimiQuotaHTTP(suspended: suspended)
        let provider = try makeProvider(monthlyTotal: nil, monthlyCode: 0, http: http)
        _ = await provider.quotaSnapshot()
        let expected = try XCTUnwrap(provider.usageTimerObservations.first)
        let prepared = try await provider.prepareUsageTimer(
            expected, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: UnexpectedUsageTimerCLI()))
        let session = try XCTUnwrap(prepared)
        await http.suspendNextQuotaRead()
        let timerRead = Task { try await session.verify() }
        await fulfillment(of: [suspended], timeout: 3)

        _ = await provider.quotaSnapshot()
        XCTAssertEqual(provider.usageTimerObservations.count, 1)
        await http.finishExhaustedRead()

        let observation = try await timerRead.value
        XCTAssertNil(observation)
        XCTAssertTrue(provider.usageTimerObservations.isEmpty)
    }

    private func makeProvider(
        monthlyTotal: Double?, monthlyCode: Double, extraCapExhausted: Bool = false, http: (any HTTPClient)? = nil
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
        let client = try http ?? KimiQuotaTimerHTTP(body: JSONSerialization.data(withJSONObject: payload))
        return KimiProvider(
            authStore: KimiAuthStore(
                files: files, environment: FakeEnvironment(["KIMI_CODE_HOME": root.path]), homeDirectory: { root }),
            usageClient: KimiUsageClient(http: client),
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

private actor OverlappingKimiQuotaHTTP: HTTPClient {
    let suspended: XCTestExpectation
    private var shouldSuspend = false
    private var waiting: CheckedContinuation<HTTPResponse, Never>?

    init(suspended: XCTestExpectation) { self.suspended = suspended }

    func suspendNextQuotaRead() { shouldSuspend = true }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if shouldSuspend, request.method == "GET" {
            shouldSuspend = false
            return await withCheckedContinuation {
                waiting = $0
                suspended.fulfill()
            }
        }
        return response(monthlyUsed: 0)
    }

    func finishExhaustedRead() {
        waiting?.resume(returning: response(monthlyUsed: 1))
        waiting = nil
    }

    private func response(monthlyUsed: Int) -> HTTPResponse {
        let body = """
            {"usages":{"limit_5h":{"used_ratio":0,"reset_time":"1970-01-01T05:00:00Z"},
            "limit_month_total":{"used_ratio":\(monthlyUsed)}}}
            """
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}
