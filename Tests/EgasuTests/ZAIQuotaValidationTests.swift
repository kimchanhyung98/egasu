import XCTest
@testable import Egasu

final class ZAIQuotaValidationMapperTests: XCTestCase {
    func testFailedBusinessEnvelopeNeverBecomesNormalQuota() {
        for fields in [#""success":false"#, #""code":401"#, #""code":500,"success":true"#] {
            let body = Data("""
            {\(fields),"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":10}]}}
            """.utf8)
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(body), fields) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse)
            }
        }
        for fields in [#""code":0"#, #""code":200,"success":true"#] {
            let body = Data("{\(fields),\"data\":{\"limits\":[]}}".utf8)
            XCTAssertNoThrow(try ZAIUsageMapper.mapQuota(body), fields)
        }
    }

    func testQuotaLevelPreservesPlanWhenSubscriptionIsUnavailable() throws {
        let quota = Data(#"{"code":200,"success":true,"data":{"level":" MAX ","limits":[]}}"#.utf8)
        XCTAssertEqual(try ZAIUsageMapper.map(quotaBody: quota, subscriptionBody: nil).plan, "GLM Coding Max")

        let subscription = Data(#"{"data":[{"productName":"GLM Coding Pro Annual"}]}"#.utf8)
        XCTAssertEqual(
            try ZAIUsageMapper.map(quotaBody: quota, subscriptionBody: subscription).plan,
            "GLM Coding Pro Annual"
        )
    }

    func testCreditAndTokenTypesKeepBothFieldAliasesWithoutDuplicatingEntries() throws {
        for kind in ["CREDIT_LIMIT", "TOKENS_LIMIT"] {
            for fields in [
                ["type": kind], ["name": kind],
                ["type": "FUTURE_LIMIT", "name": kind],
                ["type": kind, "name": "FUTURE_LIMIT"],
                ["type": kind, "name": kind]
            ] {
                var entry: [String: Any] = fields
                entry.merge(["unit": 3, "number": 5, "percentage": "25"]) { _, value in value }
                let body = try JSONSerialization.data(withJSONObject: ["data": ["limits": [entry]]])

                let lines = try ZAIUsageMapper.mapQuota(body)

                XCTAssertEqual(lines, [.progress(label: "Session", used: 25, limit: 100, format: .percent,
                                                periodDurationMs: 18_000_000)], "\(fields)")
            }
        }
    }

    func testEquivalentCreditAndTokenWindowsProduceOneMeter() throws {
        let body = Data(#"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":25},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8)
        XCTAssertEqual(try ZAIUsageMapper.mapQuota(body), [.progress(label: "Session", used: 25, limit: 100, format: .percent, periodDurationMs: 18_000_000)])
    }

    func testConflictingWindowsFailInsteadOfSelectingAnArbitraryQuota() {
        for values in [("25", "30", "5"), ("25", "25", "3")] {
            let body = Data("""
            {"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":\(values.0)},{"type":"TOKENS_LIMIT","unit":3,"number":\(values.2),"percentage":\(values.1)}]}}
            """.utf8)
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(body)) { error in
                XCTAssertTrue(error is ZAIUsageError)
            }
        }
    }

    func testMixedCreditTokenAndSearchQuotasKeepSeparateWindows() throws {
        let body = Data(
            #"""
            {"data":{"limits":[
              {"name":"CREDIT_LIMIT","unit":3,"number":5,"percentage":12},
              {"type":"TOKENS_LIMIT","unit":6,"number":1,"percentage":34},
              {"type":"CREDIT_LIMIT","unit":5,"number":1,"percentage":80},
              {"type":"TIME_LIMIT","usage":1000,"currentValue":7}
            ]}}
            """#.utf8)

        let lines = try ZAIUsageMapper.mapQuota(body)
        XCTAssertEqual(lines.map(\.label), ["Session", "Weekly", "Monthly", "Web Searches"])
        XCTAssertEqual(
            lines[2],
            .progress(
                label: "Monthly", used: 80, limit: 100, format: .percent,
                periodDurationMs: ZAIUsageMapper.monthlyPeriodMs))
        XCTAssertEqual(
            lines[3], .progress(label: "Web Searches", used: 7, limit: 1000, format: .count(suffix: "searches")))
    }

    func testExplicitMonthInDaysAndWeeklySearchQuotaKeepTheirOwnDurations() throws {
        let body = Data(
            #"""
            {"data":{"limits":[
              {"type":"CREDIT_LIMIT","unit":5,"number":2,"percentage":99},
              {"type":"TOKENS_LIMIT","unit":4,"number":31,"percentage":23},
              {"type":"TIME_LIMIT","unit":6,"number":1,"usage":300,"currentValue":44}
            ]}}
            """#.utf8)
        XCTAssertEqual(
            try ZAIUsageMapper.mapQuota(body),
            [
                .progress(
                    label: "Monthly", used: 23, limit: 100, format: .percent, periodDurationMs: 31 * MetricPeriod.dayMs),
                .progress(
                    label: "Web Searches", used: 44, limit: 300, format: .count(suffix: "searches"),
                    periodDurationMs: MetricPeriod.weekMs)
            ])
    }

    func testMalformedResetIsRejectedForMonthlyCreditAndSearchQuotas() throws {
        for fields in [
            #""type":"TOKENS_LIMIT","percentage":95"#,
            #""type":"TIME_LIMIT","usage":100,"currentValue":95"#
        ] {
            for reset in [#""invalid""#, "false", "-1"] {
                let body = Data(
                    """
                    {"limits":[{\(fields),"unit":5,"number":1,"nextResetTime":\(reset)}]}
                    """.utf8)
                XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(body)) {
                    XCTAssertEqual($0 as? ZAIUsageError, .invalidResponse)
                }
            }
            let noReset = Data("{\"limits\":[{\(fields),\"unit\":5,\"number\":1}]}".utf8)
            let nullReset = Data("{\"limits\":[{\(fields),\"unit\":5,\"number\":1,\"nextResetTime\":null}]}".utf8)
            XCTAssertEqual(try ZAIUsageMapper.mapQuota(noReset), try ZAIUsageMapper.mapQuota(nullReset))
        }
    }

    func testCreditQuotaRequiresValidPercentageAndWindow() {
        for fields in [
            #""unit":3,"number":5"#,
            #""unit":3,"number":5,"percentage":null"#,
            #""unit":3,"number":5,"percentage":true"#,
            #""unit":3,"number":5,"percentage":"NaN""#,
            #""unit":3,"number":5,"percentage":"Infinity""#,
            #""unit":3,"number":5,"percentage":"invalid""#,
            #""unit":true,"number":5,"percentage":1"#,
            #""unit":3,"number":0,"percentage":1"#,
            #""unit":3,"number":-1,"percentage":1"#,
            #""unit":3,"number":1e300,"percentage":1"#
        ] {
            let body = Data("{\"data\":{\"limits\":[{\"type\":\"CREDIT_LIMIT\",\(fields)}]}}".utf8)
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(body), fields) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse)
            }
        }
    }

    func testMissingRequiredValuesNeverBecomeZeroUsage() {
        let malformedLimits = [
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5}]}}"#,
            #"{"data":{"limits":[{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":true}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","usage":1000}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":10}]}}"#,
            #"{"data":{"limits":[{"type":"TIME_LIMIT","currentValue":-1,"usage":1000}]}}"#
        ]

        for body in malformedLimits {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, body)
            }
        }
    }

    func testMalformedEnvelopeIsRejectedButExplicitEmptyLimitsRemainValid() throws {
        for body in ["not-json", #"{"data":[]}"#, #"{"data":{}}"#, #"{"data":{"limits":{}}}"#] {
            XCTAssertThrowsError(try ZAIUsageMapper.mapQuota(Data(body.utf8)), body) { error in
                XCTAssertEqual(error as? ZAIUsageError, .invalidResponse, body)
            }
        }

        let lines = try ZAIUsageMapper.mapQuota(Data(#"{"data":{"limits":[]}}"#.utf8))
        XCTAssertNotNil(lines.first { $0.label == "Status" })
    }

    func testUnknownEntriesDoNotHideKnownMeters() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70},{"type":"TOKENS_LIMIT","unit":3,"number":5,"percentage":25}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Session" })
        XCTAssertNil(lines.first { $0.label == "Weekly" })
    }

    func testOnlyUnknownLimitsRemainForwardCompatibleNoData() throws {
        let body = Data(
            #"{"data":{"limits":[{"type":"FUTURE_LIMIT"},{"type":"TOKENS_LIMIT","unit":99,"number":1,"percentage":70}]}}"#.utf8
        )

        let lines = try ZAIUsageMapper.mapQuota(body)

        XCTAssertNotNil(lines.first { $0.label == "Status" })
    }
}

@MainActor
final class ZAIQuotaValidationProviderTests: XCTestCase {
    func testHTTP200FailedQuotaEnvelopeReturnsErrorWithoutUsage() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "test-key"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                let body = request.url == ZAIUsageClient.quotaURL
                    ? #"{"success":false,"code":500,"data":{"limits":[]}}"# : #"{"data":[]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }),
            pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.totalSpendLines)
    }

    func testCreditRefreshSurvivesSubscriptionFailureAndExportsExistingResources() async throws {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                guard request.url == ZAIUsageClient.quotaURL else {
                    return HTTPResponse(statusCode: 503, headers: [:], body: Data())
                }
                    return HTTPResponse(
                        statusCode: 200, headers: [:],
                        body: Data(
                            #"""
                            {"data":{"limits":[
                              {"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":0},
                              {"type":"CREDIT_LIMIT","unit":6,"number":1,"percentage":98},
                              {"type":"CREDIT_LIMIT","unit":5,"number":1,"percentage":7}
                            ]}}
                            """#.utf8))
            }),
            pricing: { .empty }
        )

        let snapshot = await provider.refresh()
        let descriptors = provider.widgetDescriptors
        let state = LocalUsageAPI.State(enabledOrderedIDs: ["zai"], knownIDs: ["zai"],
                                        snapshots: ["zai": snapshot], limitDescriptors: ["zai": descriptors])
        let body = try XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let zai = try XCTUnwrap(providers["zai"] as? [String: Any])
        let resources = try XCTUnwrap(zai["resources"] as? [String: Any])
        for (key, used, duration) in [
            ("session", 0.0, 18_000.0), ("weekly", 98.0, 604_800.0), ("monthly", 7.0, 2_592_000.0)
        ] {
            let resource = try XCTUnwrap(resources[key] as? [String: Any])
            XCTAssertEqual(resource["unit"] as? String, "percent")
            XCTAssertEqual(resource["used"] as? Double, used)
            XCTAssertEqual(resource["limit"] as? Double, 100)
            XCTAssertEqual(resource["windowSeconds"] as? Double, duration)
            XCTAssertNil(resource["resetsAt"])
        }
        XCTAssertNil(snapshot.plan)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.authenticationIssue)
        XCTAssertNotNil(snapshot.liveQuotaObservedAt)
        let observation = try XCTUnwrap(provider.usageTimerObservations.first { $0.timerID == "zai.session" })
        XCTAssertFalse(observation.canStart(at: Date()))
        XCTAssertEqual(descriptors.first { $0.id == "zai.session" }?.softLimitWindows, [])
        XCTAssertEqual(descriptors.first { $0.id == "zai.weekly" }?.softLimitWindows, [.weekly])
    }

    func testMissingUsageReportsInvalidResponseInsteadOfZeroMeter() async {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(
                files: FakeFiles(),
                environment: FakeEnvironment(["ZAI_API_KEY": "zai-test"])
            ),
            usageClient: ZAIUsageClient(http: RoutingHTTPClient { request in
                if request.url == ZAIUsageClient.quotaURL {
                    return HTTPResponse(
                        statusCode: 200,
                        headers: [:],
                        body: Data(#"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5}]}}"#.utf8)
                    )
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"data":[]}"#.utf8))
            }),
            pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .decoding)
        XCTAssertNil(snapshot.line(label: "Session"))
    }
}
