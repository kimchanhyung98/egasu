import XCTest
@testable import Egasu

enum CursorEventFixture {
    static func event(
        date: Date = Date(timeIntervalSince1970: 1_800_000_000), model: String = "new-model",
        tokens: Int = 100, cents: Double = 123, kind: String = CursorUsageEvents.chargeableKind
    ) -> [String: Any] {
        [
            "timestamp": String(Int(date.timeIntervalSince1970 * 1_000)), "model": model,
            "kind": kind, "chargedCents": cents, "tokenUsage": ["inputTokens": tokens]
        ]
    }

    static func page(_ events: [[String: Any]], total: Int? = nil) throws -> Data {
        try JSONSerialization.data(withJSONObject: [
            "totalUsageEventsCount": total ?? events.count, "usageEventsDisplay": events
        ])
    }

    static let token =
        "a."
        + Data(#"{"sub":"auth|events","exp":9999999999}"#.utf8)
        .base64EncodedString().replacingOccurrences(of: "=", with: "") + ".c"
}

final class CursorUsageEventsTests: XCTestCase {
    func testOnlyChargeableOnDemandEventsContributeSpend() throws {
        var disabled = CursorEventFixture.event(cents: 999)
        disabled["isChargeable"] = false
        let rows = [
            CursorEventFixture.event(cents: 12.5), disabled,
            CursorEventFixture.event(cents: 1_000, kind: "USAGE_EVENT_KIND_INCLUDED"),
            CursorEventFixture.event(cents: 1_000, kind: "USAGE_EVENT_KIND_ERRORED"),
            CursorEventFixture.event(cents: 1_000, kind: "USAGE_EVENT_KIND_FREE")
        ]
        let parsed = try CursorUsageEvents.parsePage(CursorEventFixture.page(rows))
        XCTAssertEqual(parsed.events.map(\.costUSD), [0.125, 0, 0, 0, 0])
        XCTAssertEqual(parsed.events.map(\.tokens.totalTokens), [100, 100, 100, 100, 100])
    }

    func testOmittedZeroFieldsAndModelRemainValid() throws {
        let event: [String: Any] = ["timestamp": 1_800_000_000_000, "kind": CursorUsageEvents.chargeableKind]
        let row = try XCTUnwrap(CursorUsageEvents.parsePage(CursorEventFixture.page([event])).events.first)
        XCTAssertEqual(row.costUSD, 0)
        XCTAssertEqual(row.tokens.totalTokens, 0)
        XCTAssertEqual(row.model, "")
        XCTAssertEqual(try CursorUsageEvents.parsePage(Data(#"{"totalUsageEventsCount":0}"#.utf8)).events, [])
    }

    func testTokenBucketsAreSummedWithoutRepricing() throws {
        var event = CursorEventFixture.event(cents: 17.75)
        event["tokenUsage"] =
            ["inputTokens": "10", "cacheReadTokens": 20, "cacheWriteTokens": 30, "outputTokens": 40] as [String: Any]
        let row = try XCTUnwrap(CursorUsageEvents.parsePage(CursorEventFixture.page([event])).events.first)
        XCTAssertEqual(row.tokens.totalTokens, 100)
        XCTAssertEqual(row.tokens.cacheWrite5m, 30)
        XCTAssertEqual(row.costUSD, 0.1775)
    }

    func testMalformedNumbersAndShapesRejectTheWholePage() throws {
        let invalidTokens: [Any] = [-1, 1.5, true, "NaN", "inf", "bad", "9223372036854775808"]
        for value in invalidTokens {
            var event = CursorEventFixture.event()
            event["tokenUsage"] = ["inputTokens": value]
            XCTAssertThrowsError(
                try CursorUsageEvents.parsePage(CursorEventFixture.page([CursorEventFixture.event(), event])))
        }
        for (field, value) in [
            ("timestamp", true), ("timestamp", "NaN"), ("timestamp", -1),
            ("kind", 7), ("model", 7), ("tokenUsage", "invalid"),
            ("chargedCents", true), ("chargedCents", -1), ("chargedCents", "inf"),
            ("isChargeable", "false"), ("isChargeable", 0)
        ] as [(String, Any)] {
            var event = CursorEventFixture.event()
            event[field] = value
            XCTAssertThrowsError(try CursorUsageEvents.parsePage(CursorEventFixture.page([event])), field)
        }
        for value in ["true", "-1", "1.5", "null", "\"inf\""] {
            XCTAssertThrowsError(try CursorUsageEvents.parsePage(Data("{\"totalUsageEventsCount\":\(value)}".utf8)))
        }
    }

    func testTokenBucketOverflowIsRejectedBeforeAggregation() throws {
        var event = CursorEventFixture.event()
        event["tokenUsage"] = ["inputTokens": 5_000_000_000_000_000_000, "outputTokens": 5_000_000_000_000_000_000]
        XCTAssertThrowsError(try CursorUsageEvents.parsePage(CursorEventFixture.page([event])))
    }
}

final class CursorUsageEventPagingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testAllPagesAreIncludedAndRequestRangeStaysFixed() async throws {
        let first = try CursorEventFixture.page([CursorEventFixture.event(tokens: 40, cents: 3)], total: 2)
        let second = try CursorEventFixture.page([CursorEventFixture.event(tokens: 60, cents: 5)], total: 2)
        let http = RoutingHTTPClient { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
            return HTTPResponse(statusCode: 200, headers: [:], body: body?["page"] as? Int == 1 ? first : second)
        }
        let rows = try await load(http)
        XCTAssertEqual(rows.map(\.tokens.totalTokens), [40, 60])
        XCTAssertEqual(rows.map(\.costUSD), [0.03, 0.05])
        XCTAssertEqual(http.requests.count, 2)
        let ranges = try http.requests.map { request in
            try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])["startDate"]
                as? String
        }
        XCTAssertEqual(ranges[0], ranges[1])
    }

    func testMissingChangedOversizedAndOutOfRangePagesFailAtomically() async throws {
        let first = try CursorEventFixture.page([CursorEventFixture.event()], total: 2)
        let failures = [
            try CursorEventFixture.page([], total: 2),
            try CursorEventFixture.page([CursorEventFixture.event()], total: 3),
            try CursorEventFixture.page([CursorEventFixture.event(), CursorEventFixture.event()], total: 2),
            try CursorEventFixture.page([CursorEventFixture.event(date: now.addingTimeInterval(1))], total: 2),
            try CursorEventFixture.page([CursorEventFixture.event(date: now.addingTimeInterval(-3_601))], total: 2),
            Data("invalid".utf8)
        ]
        for failure in failures {
            let http = RoutingHTTPClient { request in
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
                return HTTPResponse(statusCode: 200, headers: [:], body: body?["page"] as? Int == 1 ? first : failure)
            }
            do {
                _ = try await load(http)
                XCTFail("partial history must fail")
            } catch { XCTAssertEqual(error as? CursorUsageError, .invalidResponse) }
        }
    }

    func testRepeatedPageFailsEvenWhenCountsMatch() async throws {
        let rows = [CursorEventFixture.event(), CursorEventFixture.event(tokens: 0)]
        let data = try CursorEventFixture.page(rows, total: 4)
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 200, headers: [:], body: data) }
        do {
            _ = try await load(http)
            XCTFail("repeated page must fail")
        } catch { XCTAssertEqual(error as? CursorUsageError, .invalidResponse) }
        XCTAssertEqual(http.requests.count, 2)
    }

    func testDistinctServerEventsWithIdenticalUsageAreCounted() async throws {
        let http = RoutingHTTPClient { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
            var event = CursorEventFixture.event()
            event["requestId"] = body?["page"]
            let page = try CursorEventFixture.page([event, event], total: 4)
            return HTTPResponse(statusCode: 200, headers: [:], body: page)
        }
        let events = try await load(http)
        XCTAssertEqual(events.count, 4)
    }

    func testNumericOverflowAcrossPagesIsRejected() async throws {
        for event in [
            CursorEventFixture.event(tokens: 5_000_000_000_000_000_000),
            CursorEventFixture.event(cents: Double.greatestFiniteMagnitude)
        ] {
            let first = try CursorEventFixture.page([event], total: 2)
            var other = event
            other["model"] = "different-model"
            let second = try CursorEventFixture.page([other], total: 2)
            let http = RoutingHTTPClient { request in
                let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
                return HTTPResponse(statusCode: 200, headers: [:], body: body?["page"] as? Int == 1 ? first : second)
            }
            do {
                _ = try await load(http)
                XCTFail("overflow must fail")
            } catch { XCTAssertEqual(error as? CursorUsageError, .invalidResponse) }
        }
    }

    func testFailureOnLaterPageDoesNotReturnEarlierEvents() async throws {
        let first = try CursorEventFixture.page([CursorEventFixture.event()], total: 2)
        let http = RoutingHTTPClient { request in
            let body = try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any]
            if body?["page"] as? Int == 1 { return HTTPResponse(statusCode: 200, headers: [:], body: first) }
            return HTTPResponse(statusCode: 429, headers: ["retry-after": "120"], body: Data())
        }
        do {
            _ = try await load(http)
            XCTFail("partial history must fail")
        } catch CursorHistoryError.http(let status, let retryAfter) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(retryAfter, "120")
        }
    }

    func testInvalidSessionDoesNotSendAnyRequest() async throws {
        let http = RoutingHTTPClient { _ in
            XCTFail("unexpected request"); throw URLError(.badURL)
        }
        do {
            _ = try await CursorUsageClient(http: http).fetchUsageEvents(accessToken: "invalid", start: now, end: now)
            XCTFail("invalid session must fail")
        } catch { XCTAssertTrue(error is CursorAuthError) }
        XCTAssertTrue(http.requests.isEmpty)
    }

    private func load(_ http: RoutingHTTPClient) async throws -> [CursorUsageEvent] {
        try await CursorUsageClient(http: http).fetchUsageEvents(
            accessToken: CursorEventFixture.token, start: now.addingTimeInterval(-3_600), end: now
        )
    }
}
