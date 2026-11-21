import XCTest
@testable import Egasu

@MainActor
final class CursorOptionalEndpointTests: XCTestCase {
    func testIncompleteWeeklyLimitPreservesMeasuredBreakdownAndUnknownState() async throws {
        let provider = makeProvider { request in
            if request.url == CursorUsageClient.usageURL {
                let body = """
                    {"billingCycleStart":1799800000000,"billingCycleEnd":1800404800000,
                     "planUsage":{"limit":300,"apiPercentUsed":20}}
                    """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let snapshot = await provider.refresh()
        XCTAssertEqual(snapshot.incompleteQuotaWindows, [.weekly])
        XCTAssertEqual(progress(snapshot.lines, "API usage")?.used, 20)
        let now = try XCTUnwrap(snapshot.liveQuotaObservedAt)
        let observed = try XCTUnwrap(
            SoftLimitObservation.project(
                snapshot: snapshot, descriptors: provider.widgetDescriptors, window: .weekly, now: now
            ))
        XCTAssertEqual(observed.quotaState(thresholdPercent: 90, at: now), .unknown)
        XCTAssertEqual(observed.quotaState(thresholdPercent: 10, at: now), .reached)
    }

    func testOptionalSchemaAndHTTPFailuresAreLoggedWithoutDiscardingPrimaryUsage() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let accessToken = makeCursorJWT(includeSubject: true)
        let provider = makeProvider(accessToken: accessToken) { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":42}}"#.utf8))
            case CursorUsageClient.creditsURL:
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            case CursorUsageClient.stripeURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNil(snapshot.incompleteQuotaWindows)
        XCTAssertTrue(diagnostics.events.contains(DiagnosticEvent(.cursorCredits, result: .degraded, category: .http5xx, providerID: "cursor")))
        XCTAssertTrue(logs.contains("optional plan response contained invalid plan metadata"), logs)
        XCTAssertTrue(logs.contains("optional credit-grants request returned HTTP 503"), logs)
        XCTAssertTrue(logs.contains("optional prepaid-balance response was invalid"), logs)
        for operation in ["cursor_plan", "cursor_credits", "cursor_balance"] {
            let matching = logs.split(separator: "\n").filter { $0.contains("operation=" + operation) }
            XCTAssertEqual(matching.count, 1, logs)
            XCTAssertTrue(matching.first?.contains("WARN") == true, logs)
        }
        XCTAssertEqual(logs.split(separator: "\n").filter { $0.contains("optional plan") }.count, 1, logs)
        XCTAssertEqual(logs.split(separator: "\n").filter { $0.contains("optional credit-grants") }.count, 1, logs)
        XCTAssertEqual(logs.split(separator: "\n").filter { $0.contains("optional prepaid-balance") }.count, 1, logs)
        XCTAssertFalse(logs.contains("[http]"), logs)
        XCTAssertFalse(logs.contains(accessToken), logs)
    }

    func testOptionalTransportAndSessionPreparationFailuresAreLogged() async throws {
        let provider = makeProvider(accessToken: makeCursorJWT(includeSubject: false)) { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL, CursorUsageClient.creditsURL:
                throw URLError(.cannotConnectToHost)
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional plan request failed"), logs)
        XCTAssertTrue(logs.contains("optional credit-grants request failed"), logs)
        XCTAssertTrue(logs.contains("optional prepaid-balance request could not be prepared from the current session"), logs)
    }

    func testInvalidPlanMetadataStillEnablesRequestBasedFallback() async throws {
        let provider = makeProvider { request in
            if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"gpt-4":{"maxRequestUsage":500,"numRequests":100}}"#.utf8)
                )
            }
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true}"#.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":42}}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Requests")?.used, 100)
        XCTAssertEqual(progress(snapshot.lines, "Requests")?.limit, 500)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional plan response contained invalid plan metadata"), logs)
    }

    func testEnterpriseOnDemandSpendAloneDoesNotSupplyASubscriptionObservation() async {
        let provider = makeProvider { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true}"#.utf8))
            case CursorUsageClient.planURL:
                let plan = #"{"planInfo":{"planName":"enterprise"}}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(plan.utf8))
            case CursorUsageClient.usageSummaryURL:
                let summary = """
                    {"billingCycleStart":"2026-07-01T00:00:00Z","billingCycleEnd":"2026-08-01T00:00:00Z",
                     "individualUsage":{"onDemand":{"used":500,"limit":1000}}}
                    """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(summary.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, 5)
        XCTAssertNil(snapshot.liveQuotaObservedAt)
    }

    func testMissingPrepaidBalanceMetadataIsLoggedWithoutDiscardingPrimaryUsage() async throws {
        let provider = makeProvider { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8)
                )
            case CursorUsageClient.creditsURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            case CursorUsageClient.stripeURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"unexpected":true}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 20)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(logs.contains("optional prepaid-balance response contained invalid balance metadata"), logs)
    }

    func testBooleanCreditAndPrepaidMetadataIsLoggedWithoutBogusBalance() async throws {
        let provider = makeProvider { request in
            switch request.url {
            case CursorUsageClient.usageURL:
                return Self.primaryUsageResponse
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8)
                )
            case CursorUsageClient.creditsURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"hasCreditGrants":true,"totalCents":true,"usedCents":0}"#.utf8)
                )
            case CursorUsageClient.stripeURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"customerBalance":true}"#.utf8))
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.lines.first { $0.label == "Credits" })
        XCTAssertTrue(logs.contains("optional credit-grants response contained invalid grant metadata"), logs)
        XCTAssertTrue(logs.contains("optional prepaid-balance response contained invalid balance metadata"), logs)
    }

    func testSuccessfulGenericRequestFallbackIncludesSpendAndHistory() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let body = try CursorEventFixture.page([
            CursorEventFixture.event(date: now, tokens: 1_000_000, cents: 1_000),
            CursorEventFixture.event(date: yesterday, tokens: 500_000, cents: 500)
        ])
        let pricing = ModelPricing(
            supplement: PricingSupplement(),
            primary: PricingCatalog(entries: ["test-model": ModelRates(
                inputPerMillion: 1, outputPerMillion: 10, cacheWritePerMillion: 1, cacheReadPerMillion: 0.1
            )]),
            secondary: PricingCatalog()
        )
        let provider = makeProvider(pricing: pricing) { request in
            if request.url.path == CursorUsageClient.usageEventsURL.path {
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                let usage = """
                    {"startOfMonth":"2027-01-01T00:00:00Z","gpt-4":{"maxRequestUsage":500,"numRequests":100}}
                    """
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(usage.utf8))
            }
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"planUsage":{}}"#.utf8))
            case CursorUsageClient.planURL:
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8))
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.isDegraded)
        XCTAssertEqual(snapshot.liveQuotaObservedAt, now)
        XCTAssertEqual(progress(snapshot.lines, "Requests")?.used, 100)
        XCTAssertEqual(progress(snapshot.lines, "Requests")?.limit, 500)
        XCTAssertEqual(diagnostics.events.filter { $0.operation == .cursorFallback }, [
            DiagnosticEvent(.cursorFallback, result: .success, providerID: "cursor")
        ])
        XCTAssertEqual(diagnostics.events.filter { $0.operation == .historyScan }, [
            DiagnosticEvent(.historyScan, result: .success, providerID: "cursor")
        ])
        for (label, dollars, tokens) in [("Today", 10.0, 1_000_000.0), ("Yesterday", 5.0, 500_000.0), ("Last 30 Days", 15.0, 1_500_000.0)] {
            guard case .values(_, let values, _, _, _, _) = snapshot.lines.first(where: { $0.label == label }) else {
                XCTFail("Missing \(label) spend line")
                continue
            }
            XCTAssertEqual(values, [
                MetricValue(number: dollars, kind: .dollars, estimated: false),
                MetricValue(number: tokens, kind: .count, label: "tokens")
            ])
        }
        XCTAssertEqual(snapshot.usageHistory?.series.daily, [
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 1_000_000, costUSD: 10),
            DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: yesterday), totalTokens: 500_000, costUSD: 5)
        ])
        guard case .chart(_, let points, _) = snapshot.lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("Missing usage trend")
        }
        XCTAssertEqual(points.suffix(2).map(\.value), [500_000, 1_000_000])
    }

    func testGenericRequestFallbackPreservesUsageWhenSpendExportFails() async throws {
        let failures: [(HTTPResponse?, ErrorCategory)] = [
            (nil, .network),
            (HTTPResponse(statusCode: 503, headers: [:], body: Data()), .http5xx),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8)), .decoding)
        ]
        for (response, category) in failures {
            let diagnostics = DiagnosticEventRecorder()
            let provider = makeProvider { request in
                if request.url.path == CursorUsageClient.usageEventsURL.path {
                    guard let response else { throw URLError(.cannotConnectToHost) }
                    return response
                }
                if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"gpt-4":{"maxRequestUsage":500,"numRequests":100}}"#.utf8
                    ))
                }
                switch request.url {
                case CursorUsageClient.usageURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"planUsage":{}}"#.utf8))
                case CursorUsageClient.planURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8))
                default:
                    XCTFail("Unexpected request: \(request.url)")
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }

            let (snapshot, logs) = try await captureLogs { await provider.refresh() }

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertEqual(progress(snapshot.lines, "Requests")?.used, 100)
            XCTAssertEqual(progress(snapshot.lines, "Requests")?.limit, 500)
            XCTAssertNil(snapshot.usageHistory)
            XCTAssertFalse(snapshot.lines.contains { ["Today", "Yesterday", "Last 30 Days", "Usage Trend"].contains($0.label) })
            XCTAssertEqual(diagnostics.events.filter { $0.operation == .cursorFallback }, [
                DiagnosticEvent(.cursorFallback, result: .success, providerID: "cursor")
            ])
            XCTAssertEqual(diagnostics.events.filter { $0.operation == .historyScan }, [
                DiagnosticEvent(.historyScan, result: .degraded, category: category, providerID: "cursor")
            ])
            XCTAssertTrue(logs.contains("usage events"), logs)
            XCTAssertFalse(logs.contains(makeCursorJWT(includeSubject: true)), logs)
        }
    }

    func testFailedGenericRequestFallbackIsLoggedBeforePrimaryMappingError() async throws {
        let diagnostics = DiagnosticEventRecorder()
        let provider = makeProvider { request in
            if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                return HTTPResponse(statusCode: 502, headers: [:], body: Data())
            }
            switch request.url {
            case CursorUsageClient.usageURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"enabled":true,"planUsage":{}}"#.utf8)
                )
            case CursorUsageClient.planURL:
                return HTTPResponse(
                    statusCode: 200,
                    headers: [:],
                    body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8)
                )
            default:
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
        }

        let (snapshot, logs) = try await captureLogs { await provider.refresh() }

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.liveQuotaObservedAt)
        XCTAssertTrue(logs.contains("optional request-based usage fallback failed"), logs)
        XCTAssertEqual(
            diagnostics.events.filter { $0.operation == .cursorFallback },
            [DiagnosticEvent(.cursorFallback, result: .degraded, category: .http5xx, providerID: "cursor")]
        )
    }

    func testGenericRequestFallbackPreservesTransportAndDecodingDiagnosticsBeforePrimaryMappingFailure() async throws {
        let responses: [(HTTPResponse?, ErrorCategory)] = [
            (nil, .network),
            (HTTPResponse(statusCode: 200, headers: [:], body: Data("not-json".utf8)), .decoding)
        ]
        for (response, category) in responses {
            let diagnostics = DiagnosticEventRecorder()
            let provider = makeProvider { request in
                if request.url.absoluteString.hasPrefix(CursorUsageClient.restUsageURL.absoluteString) {
                    guard let response else { throw URLError(.cannotConnectToHost) }
                    return response
                }
                switch request.url {
                case CursorUsageClient.usageURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"enabled":true,"planUsage":{}}"#.utf8))
                case CursorUsageClient.planURL:
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro"}}"#.utf8))
                default:
                    return HTTPResponse(statusCode: 404, headers: [:], body: Data())
                }
            }

            let (snapshot, logs) = try await captureLogs { await provider.refresh() }

            XCTAssertEqual(snapshot.errorCategory, .decoding, "The empty primary plan fails mapping after the optional fallback")
            XCTAssertFalse(logs.contains("[http]"), logs)
            XCTAssertEqual(logs.split(separator: "\n").filter {
                $0.contains("operation=cursor_fallback") || $0.contains("optional request-based usage fallback failed")
            }.count, 1, logs)
            XCTAssertEqual(
                diagnostics.events.filter { $0.operation == .cursorFallback },
                [DiagnosticEvent(.cursorFallback, result: .degraded, category: category, providerID: "cursor")]
            )
        }
    }

    func testMergedAccountUsesOneWeeklyPoolAndDashboardBilling() async throws {
        let provider = makeProvider { request in
            let json: String
            switch request.url.lastPathComponent {
            case "GetCurrentPeriodUsage":
                json = #"{"enabled":true,"billingCycleStart":"1794728276119","billingCycleEnd":"1795333076119","planUsage":{"totalPercentUsed":23,"autoPercentUsed":23}}"#
            case "GetPlanInfo": json = #"{"isMerged":true,"planInfo":{"planName":"ultra"}}"#
            case "GetComplatCreditBalance": json = #"{"usdRemainingCents":"581149"}"#
            case "usage-status":
                XCTAssertEqual(request.url.query, "scope=user")
                XCTAssertNotNil(request.headers["Cookie"])
                json = #"{"availability":"available","monthlyUsage":{"usedCents":2500,"limitCents":10000,"periodStart":"2026-11-01T00:00:00Z","resetsAt":"2026-12-01T00:00:00Z"}}"#
            case "get-filtered-usage-events": json = #"{"totalUsageEventsCount":0}"#
            default:
                XCTFail("Unexpected endpoint \(request.url.path)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        let snapshot = await provider.refresh()
        XCTAssertEqual(progress(snapshot.lines, "Total usage")?.used, 23)
        XCTAssertNil(snapshot.line(label: "Auto usage"))
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, 25)
        XCTAssertEqual(progress(snapshot.lines, "On-demand")?.limit, 100)
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Credits") else {
            return XCTFail("Missing prepaid balance")
        }
        XCTAssertEqual(values.first?.number, 5811.49)
    }

    func testAdditionalUsageDistinguishesDisabledUncappedAndInvalidBilling() throws {
        XCTAssertNil(try CursorProvider.additionalUsage(["availability": "unavailable"]))
        XCTAssertNil(try CursorProvider.additionalUsage(["monthlyUsage": ["additionalUsageOff": true]]))
        XCTAssertNil(try CursorProvider.additionalUsage(["monthlyUsage": ["limitCents": 0, "usedCents": 250]]))
        guard case .values(_, let values, _, _, _, _) = try CursorProvider.additionalUsage(
            ["monthlyUsage": ["usedCents": 250, "limitCents": NSNull()]]) else { return XCTFail("Missing spend") }
        XCTAssertEqual(values.first?.number, 2.5)
        for monthly: [String: Any] in [["usedCents": -1], ["usedCents": 10, "limitCents": "invalid"]] {
            XCTAssertThrowsError(try CursorProvider.additionalUsage(["monthlyUsage": monthly]))
        }
    }

    private nonisolated static var primaryUsageResponse: HTTPResponse {
        HTTPResponse(
            statusCode: 200,
            headers: [:],
            body: Data(
                #"{"enabled":true,"billingCycleEnd":1772592000000,"planUsage":{"limit":40000,"remaining":32000,"totalPercentUsed":20}}"#.utf8
            )
        )
    }

    private func makeProvider(
        accessToken: String = makeCursorJWT(includeSubject: true),
        pricing: ModelPricing = TestPricing.bundled,
        handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse
    ) -> CursorProvider {
        CursorProvider(
            authStore: CursorAuthStore(
                sqlite: OptionalCursorSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: RoutingHTTPClient(handler: handler)),
            now: { Date(timeIntervalSince1970: 1_800_000_000) },
            pricing: { pricing }
        )
    }

    private func captureLogs(
        _ operation: () async -> ProviderSnapshot
    ) async throws -> (ProviderSnapshot, String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgasuTests.CursorOptional.\(UUID().uuidString)", isDirectory: true)
        let sink = LogFile(directory: directory, fileName: "egasu.log")
        sink.open()
        let originalSink = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.warn)
        defer {
            AppLog.sink = originalSink
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        let snapshot = await operation()
        let logs = try String(contentsOf: directory.appendingPathComponent("egasu.log"), encoding: .utf8)
        return (snapshot, logs)
    }

    private func progress(
        _ lines: [MetricLine],
        _ label: String
    ) -> (used: Double, limit: Double)? {
        guard case .progress(_, let used, let limit, _, _, _, _) = lines.first(where: { $0.label == label }) else {
            return nil
        }
        return (used, limit)
    }
}

private func makeCursorJWT(includeSubject: Bool) -> String {
    let payload = includeSubject
        ? #"{"exp":9999999999,"sub":"google-oauth2|user"}"#
        : #"{"exp":9999999999}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class OptionalCursorSQLite: SQLiteAccessing, @unchecked Sendable {
    private let values: [String: String]

    init(values: [String: String]) {
        self.values = values
    }

    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) {
            return value
        }
        return nil
    }

    func execute(path: String, sql: String) throws {}
}
