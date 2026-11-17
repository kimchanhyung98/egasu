import XCTest
@testable import Egasu

// MARK: - Range aggregation

final class CursorSpendRangeTests: XCTestCase {
    func testSubcentCostsRoundOncePerDisplayedPeriod() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        var lines: [MetricLine] = []
        let history = CursorUsageMapper.appendSpendLines(
            rows: [makeRow(date: now, cost: 0.004, tokens: 1), makeRow(date: yesterday, cost: 0.004, tokens: 1)],
            now: now, pricing: .empty, to: &lines
        )
        XCTAssertEqual(history.series.daily.map(\.costUSD), [0.004, 0.004])
        let total = try XCTUnwrap(values(lines, "Last 30 Days")?.first?.number)
        XCTAssertEqual(total, 0.008)
        XCTAssertEqual(Formatters.currency(total), "$0.01")
        XCTAssertEqual(try XCTUnwrap(modelBreakdown(lines, "Last 30 Days")).totalCostUSD, 0.008)
    }

    func testAppendSpendLinesBucketsRowsByLocalDay() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: now)
        let startOfLast30 = cal.date(byAdding: .day, value: -29, to: startOfToday)!

        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                              // 오늘
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200),    // 어제
            makeRow(date: startOfLast30, cost: 0.50, tokens: 50),                                     // -29d 경계: last30만 포함
            makeRow(date: cal.date(byAdding: .day, value: -40, to: now)!, cost: 5.00, tokens: 999)    // 오래된 행 (provider가 fetch 범위 제한)
        ]

        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        // 토큰과 비용은 서버 보고값이며 추정 표시 없음.
        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 1.00, kind: .dollars, estimated: false), MetricValue(number: 100, kind: .count, label: "tokens")])
        XCTAssertEqual(values(lines, "Yesterday"), [MetricValue(number: 2.00, kind: .dollars, estimated: false), MetricValue(number: 200, kind: .count, label: "tokens")])
        // Last 30 Days는 fetch된 전체 일자 합산 (provider가 API를 30일 window로 제한)
        XCTAssertEqual(values(lines, "Last 30 Days"), [MetricValue(number: 8.50, kind: .dollars, estimated: false), MetricValue(number: 1349, kind: .count, label: "tokens")])
    }

    func testZeroActivityLeavesTilesUnbacked() {
        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: [], now: Date(), pricing: TestPricing.bundled, to: &lines)

        // fetch 성공 + 행 없음: 모든 기간 idle → spend 타일 미추가, "No data"로 fallback
        XCTAssertNil(values(lines, "Today"))
        XCTAssertNil(values(lines, "Yesterday"))
        XCTAssertNil(values(lines, "Last 30 Days"))
    }

    func testAppendSpendLinesAlsoAppendsUsageTrend() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let cal = Calendar.current
        let rows = [
            makeRow(date: now, cost: 1.00, tokens: 100),                                           // 오늘
            makeRow(date: cal.date(byAdding: .day, value: -1, to: now)!, cost: 2.00, tokens: 200)  // 어제
        ]

        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        guard case .chart(let label, let points, let note) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected a Usage Trend chart line")
        }
        XCTAssertEqual(label, "Usage Trend")
        // Cursor token은 서버 사용 이벤트 출처 — note에 해당 출처 명시.
        XCTAssertEqual(note, "From your Cursor usage history.")
        XCTAssertEqual(points.count, 31, "one bar per calendar day across the 31-day window")
        XCTAssertEqual(points.last?.value, 100, "today's tokens land on the last bar")
        XCTAssertEqual(points[29].value, 200, "yesterday's tokens land on the second-to-last bar")
    }

    func testNoRowsLeavesNoUsageTrend() {
        // 조회된 이벤트가 없으면 추이 차트 미추가("No data").
        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: [], now: Date(), pricing: TestPricing.bundled, to: &lines)
        XCTAssertNil(lines.first(where: { $0.label == "Usage Trend" }))
    }

    func testUnknownModelsAndCostOnlyEventsKeepReportedCost() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            makeRow(date: now, cost: 1.004, tokens: 100, model: "composer-1"),
            makeRow(date: now, cost: 2.006, tokens: 200, model: "new-model"),
            makeRow(date: now, cost: 3, tokens: 0, model: "")
        ]
        var lines: [MetricLine] = []
        let history = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: .empty, to: &lines)

        XCTAssertEqual(
            values(lines, "Today"),
            [
                MetricValue(number: 6.01, kind: .dollars), MetricValue(number: 300, kind: .count, label: "tokens")
            ])
        XCTAssertEqual(unknown(lines, "Today"), [])
        XCTAssertTrue(history.unknownModelsByDay.isEmpty)
        XCTAssertEqual(history.estimatedCost, false)
        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.sourceNote, WidgetData.cursorUsageHistoryNote)
        XCTAssertEqual(Set(breakdown.models.map(\.model)), ["composer-1", "new-model", "Other"])
        XCTAssertEqual(breakdown.models.first { $0.model == "Other" }?.costUSD, 3)
    }

    func testModelBreakdownGroupsThinkingEffortSlugsIntoFamilies() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // thinking-effort/fast 조합별 slug를 canonical base model로 그룹핑, 원시 slug는 tooltip variant로 유지
        let rows = [
            makeRow(date: now, cost: 3.00, tokens: 300, model: "claude-opus-4-8-thinking-max"),
            makeRow(date: now, cost: 1.00, tokens: 100, model: "claude-opus-4-8-thinking-high"),
            makeRow(date: now, cost: 2.00, tokens: 200, model: "gpt-5.5-extra-high-fast"),
            makeRow(date: now, cost: 0.50, tokens: 50, model: "gpt-5.5")
        ]

        var lines: [MetricLine] = []
        _ = CursorUsageMapper.appendSpendLines(rows: rows, now: now, pricing: TestPricing.bundled, to: &lines)

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["claude-opus-4-8", "gpt-5.5"])

        let opus = try XCTUnwrap(breakdown.models.first { $0.model == "claude-opus-4-8" })
        XCTAssertEqual(opus.totalTokens, 400)
        XCTAssertEqual(opus.costUSD, 4.00)
        XCTAssertEqual(opus.variants?.map(\.model), ["claude-opus-4-8-thinking-max", "claude-opus-4-8-thinking-high"],
                       "variants keep the raw slugs, largest spend first")
        XCTAssertEqual(opus.variants?.map(\.costUSD), [3.00, 1.00])

        let gpt = try XCTUnwrap(breakdown.models.first { $0.model == "gpt-5.5" })
        XCTAssertEqual(gpt.variants?.map(\.model), ["gpt-5.5-extra-high-fast", "gpt-5.5"],
                       "a -fast canonical folds into its base family")
    }

    func testIncludedOnlyDayKeepsTokensAndZeroReportedSpend() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var lines: [MetricLine] = []
        let history = CursorUsageMapper.appendSpendLines(
            rows: [makeRow(date: now, cost: 0, tokens: 100, model: "unlisted")],
            now: now, pricing: .empty, to: &lines
        )
        XCTAssertEqual(
            values(lines, "Today"),
            [
                MetricValue(number: 0, kind: .dollars), MetricValue(number: 100, kind: .count, label: "tokens")
            ])
        XCTAssertEqual(history.series.daily.first?.costUSD, 0)
        XCTAssertEqual(unknown(lines, "Today"), [])
        guard case .chart(_, let points, _) = lines.first(where: { $0.label == "Usage Trend" }) else {
            return XCTFail("expected usage trend")
        }
        XCTAssertEqual(points.last?.value, 100)
    }

    private func modelBreakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = lines.first(where: { $0.label == label }) else { return nil }
        return breakdown
    }

    private func unknown(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    private func makeRow(date: Date, cost: Double, tokens: Int, model: String = "composer-1") -> CursorUsageEvent {
        CursorUsageEvent(
            date: date,
            model: model,
            tokens: TokenBreakdown(input: tokens),
            costUSD: cost
        )
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = lines.first(where: { $0.label == label }) else { return nil }
        return values
    }
}

// MARK: - Provider integration + render shape

@MainActor
final class CursorSpendProviderTests: XCTestCase {
    func testSpendTrackingUsesServerChargesAndRetainsUnlistedModelTokens() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let yesterday = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -1, to: now))
        let body = try CursorEventFixture.page([
            CursorEventFixture.event(date: now, model: "composer-1", tokens: 1_000_000, cents: 13),
            CursorEventFixture.event(
                date: now, model: "new-model", tokens: 500_000, cents: 20, kind: "USAGE_EVENT_KIND_INCLUDED"),
            CursorEventFixture.event(date: yesterday, model: "new-model", tokens: 200_000, cents: 7)
        ])

        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { request in
            let url = request.url.absoluteString
            if url.contains("get-filtered-usage-events") {
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            if url.contains("GetCurrentPeriodUsage") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("""
                {
                  "enabled": true,
                  "billingCycleEnd": 1772592000000,
                  "planUsage": { "limit": 40000, "remaining": 32000, "totalPercentUsed": 20 }
                }
                """.utf8))
            }
            if url.contains("GetPlanInfo") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"planInfo":{"planName":"pro plan"}}"#.utf8))
            }
            if url.contains("GetCreditGrantsBalance") {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"hasCreditGrants":false}"#.utf8))
            }
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        let provider = CursorProvider(
            authStore: CursorAuthStore(
                sqlite: FakeSQLite(values: [CursorAuthStore.accessTokenKey: accessToken]),
                keychain: FakeKeychain()
            ),
            usageClient: CursorUsageClient(http: http),
            now: { now },
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(http.requests.contains { $0.url.absoluteString.contains("get-filtered-usage-events") },
                      "Cursor refresh must load usage events for spend metrics")
        // live quota 미터 유지, spend 타일 + trend 존재
        XCTAssertTrue(snapshot.lines.contains { $0.label == "Total usage" })
        for label in ["Today", "Yesterday", "Last 30 Days", "Usage Trend"] {
            XCTAssertNotNil(snapshot.lines.first { $0.label == label }, "\(label) line must be present")
        }
        let ids = Set(provider.widgetDescriptors.map(\.id))
        for id in ["cursor.today", "cursor.yesterday", "cursor.last30", "cursor.trend"] {
            XCTAssertTrue(ids.contains(id), "\(id) descriptor must be present")
        }

        // 미등록 모델도 서버 비용을 사용하므로 가격 누락 경고 없음.
        XCTAssertEqual(unknownModels(snapshot.lines, "Today"), [])
        XCTAssertEqual(unknownModels(snapshot.lines, "Yesterday"), [])
        XCTAssertEqual(unknownModels(snapshot.lines, "Last 30 Days"), [])
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.costUSD, 0.13)
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 1_500_000)
        XCTAssertEqual(snapshot.usageHistory?.estimatedCost, false)
        XCTAssertEqual(
            provider.widgetDescriptors.first { $0.id == "cursor.trend" }?.historyResource?.estimatedCost, false)
    }

    private func unknownModels(_ lines: [MetricLine], _ label: String) -> [String]? {
        guard case .values(_, _, _, _, let unknownModels, _) = lines.first(where: { $0.label == label }) else { return nil }
        return unknownModels
    }

    func testSpendTileRendersCombinedCostAndTokensWithValueTooltip() async {
        let cursor = CursorProvider()
        let descriptor = try! XCTUnwrap(cursor.widgetDescriptors.first { $0.id == "cursor.today" })

        // 결합 타일은 달러 + 라벨된 token count — 실제 $0.00 보고(예: OpenRouter)는 숨기지 않고 "$0.00 · 0 tokens"로 렌더
        let cases: [(Double, Int, String, String)] = [
            (12.34, 891_000, "$12.34", "$12.34 · 891K tokens"),
            (0.0, 0, "$0.00", "$0.00 · 0 tokens")
        ]
        for (dollars, tokens, expectedValue, expectedDetail) in cases {
            let runtime = TestProviderRuntime(
                provider: cursor.provider,
                descriptors: [descriptor],
                snapshot: ProviderSnapshot(
                    providerID: cursor.provider.id,
                    displayName: cursor.provider.displayName,
                    lines: [.values(label: "Today", values: [
                        MetricValue(number: dollars, kind: .dollars, estimated: false),
                        MetricValue(number: Double(tokens), kind: .count, label: "tokens")
                    ])]
                )
            )
            let defaults = isolatedDefaults("render-\(expectedValue)")
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [cursor.provider], descriptors: [descriptor]),
                providers: [runtime],
                cache: isolatedCache(defaults),
                defaults: defaults
            )
            await store.refreshAll()

            store.meterStyle = .remaining
            let remaining = store.data(for: descriptor)
            store.meterStyle = .used
            let used = store.data(for: descriptor)

            XCTAssertTrue(remaining.hasData)
            XCTAssertEqual(remaining.valueText, expectedValue)
            XCTAssertEqual(remaining.unboundedDetail, expectedDetail)
            XCTAssertNil(remaining.infoNote)
            // unbounded: 두 meter style에서 동일
            XCTAssertEqual(used.valueText, remaining.valueText)
            XCTAssertEqual(used.unboundedDetail, remaining.unboundedDetail)
            XCTAssertEqual(used.infoNote, remaining.infoNote)
        }
    }

    // MARK: helpers

    private func isolatedDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.CursorSpend.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func isolatedCache(_ defaults: UserDefaults) -> ProviderSnapshotCache {
        ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots", ttl: 600, now: { Date() })
    }
}

// MARK: - Client request contract

final class CursorUsageClientRequestTests: XCTestCase {
    func testFetchUsageEventsUsesJSONPagingAndSessionCookie() async throws {
        let accessToken = makeCursorJWT(sub: "google-oauth2|user_abc123")
        let http = RoutingHTTPClient { _ in
            HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"totalUsageEventsCount":0}"#.utf8))
        }
        let response = try await CursorUsageClient(http: http).fetchUsageEventsPage(
            accessToken: accessToken, start: Date(timeIntervalSince1970: 1_000),
            end: Date(timeIntervalSince1970: 2_000), page: 2
        )
        XCTAssertEqual(response?.statusCode, 200)
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, CursorUsageClient.usageEventsURL)
        XCTAssertEqual(request.headers["Cookie"], "WorkosCursorSessionToken=user_abc123%3A%3A\(accessToken)")
        XCTAssertEqual(request.headers["Content-Type"], "application/json")
        XCTAssertEqual(request.headers["Origin"], "https://cursor.com")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: Any])
        XCTAssertEqual(body["startDate"] as? String, "1000000")
        XCTAssertEqual(body["endDate"] as? String, "2000000")
        XCTAssertEqual(body["page"] as? Int, 2)
        XCTAssertEqual(body["pageSize"] as? Int, 1_000)
    }
}

// MARK: - Shared test helpers (file-private; mirror CursorProviderTests)

private func makeCursorJWT(sub: String = "google-oauth2|user", exp: Double = 9_999_999_999) -> String {
    let payload = #"{"sub":"\#(sub)","exp":\#(exp)}"#
    let encoded = Data(payload.utf8).base64EncodedString()
        .replacingOccurrences(of: "=", with: "")
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
    return "a.\(encoded).c"
}

private final class FakeSQLite: SQLiteAccessing, @unchecked Sendable {
    var values: [String: String]
    init(values: [String: String] = [:]) { self.values = values }
    func queryValue(path: String, sql: String) throws -> String? {
        for (key, value) in values where sql.contains(key) { return value }
        return nil
    }
    func execute(path: String, sql: String) throws {}
}
