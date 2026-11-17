import XCTest
@testable import Egasu

@MainActor
final class CursorUsageHistoryRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMalformedEventPagePreservesLastGoodHistoryAndLogsDegradation() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        let initial = try XCTUnwrap(fixture.store.localSnapshots["cursor"]?.usageHistory)
        XCTAssertEqual(initial.series.daily.first?.totalTokens, 100)
        await fixture.http.setBody(try body(tokens: [-1]))

        let logs = try await captureLogs {
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
        }

        let retained = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(retained.usageHistory, initial)
        XCTAssertEqual(retained.isDegraded, true)
        XCTAssertEqual(retained.warning, "Cursor usage history could not be refreshed. Try again later.")
        XCTAssertNotNil(retained.line(label: "Total usage"))
        XCTAssertNotNil(retained.line(label: "Today"))
        XCTAssertNil(fixture.store.providerErrors["cursor"])
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["cursor"])["cursor"]?.usageHistory, initial)
        XCTAssertTrue(logs.contains("operation=history_scan result=degraded category=decoding"), logs)
        XCTAssertTrue(logs.contains("usage events history could not be loaded completely"), logs)
    }

    func testEmptyEventPageClearsLastGoodHistoryWithoutDegradation() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 100)
        await fixture.http.setBody(try body(tokens: []))

        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(try XCTUnwrap(snapshot.usageHistory).series.daily, [])
        XCTAssertNil(snapshot.isDegraded)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNil(snapshot.line(label: "Usage Trend"))
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
        XCTAssertEqual(fixture.cache.loadSnapshots(providerIDs: ["cursor"])["cursor"]?.usageHistory?.series.daily, [])
    }

    func testMixedValidAndInvalidPagePreservesEntirePreviousHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 100)
        await fixture.http.setBody(try body(tokens: [40, -1]))

        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(snapshot.usageHistory?.series.daily.first?.totalTokens, 100)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertNotNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
    }

    func testAccountChangeDoesNotReusePreviousHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 100)
        fixture.sqlite.setToken(try token(identity: "different-account"))
        await fixture.http.setFailure(500)

        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.line(label: "Today"))
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNil(fixture.cache.loadSnapshots(providerIDs: ["cursor"])["cursor"]?.usageHistory)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "cursor"), "different-account")

        await fixture.http.setFailure(nil)
        await fixture.http.setBody(try body(tokens: [200]))
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 200)
    }

    func testRestartRetainsHistoryOnlyForTheSameAccountAfterTokenRotation() async throws {
        for identity in ["history-fixture", "different-account"] {
            let fixture = try makeFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            fixture.sqlite.setToken(try token(identity: identity, expiresAt: 9_999_999_998))
            await fixture.http.setFailure(500)
            let cache = ProviderSnapshotCache(userDefaults: fixture.defaults, now: { fixture.clock.now })
            let store = makeStore(
                sqlite: fixture.sqlite, http: fixture.http, clock: fixture.clock,
                cache: cache, defaults: fixture.defaults
            )

            _ = await store.refresh(providerID: "cursor", force: true)

            let snapshot = try XCTUnwrap(store.localSnapshots["cursor"])
            XCTAssertEqual(
                snapshot.usageHistory?.series.daily.first?.totalTokens, identity == "history-fixture" ? 100 : nil)
            XCTAssertNotNil(snapshot.line(label: "Total usage"))
            XCTAssertNotNil(snapshot.warning)
            XCTAssertEqual(cache.producedByIdentityKey(providerID: "cursor"), identity)
            let exported = try JSONEncoder().encode(snapshot)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            XCTAssertNil(object["producedByIdentityKey"])
            XCTAssertFalse(String(decoding: exported, as: UTF8.self).contains(identity))
        }
    }

    func testUnknownAccountCannotReusePreviousHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        fixture.sqlite.setToken(try token(identity: nil))

        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNotNil(snapshot.line(label: "Total usage"))
        XCTAssertNotNil(snapshot.warning)
        XCTAssertNil(fixture.cache.producedByIdentityKey(providerID: "cursor"))
    }

    func testLegacyCacheWithoutAccountStampCannotSupplyHistory() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        let previous = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        fixture.cache.store(previous)
        await fixture.http.setFailure(500)
        let cache = ProviderSnapshotCache(userDefaults: fixture.defaults, now: { fixture.clock.now })
        let store = makeStore(
            sqlite: fixture.sqlite, http: fixture.http, clock: fixture.clock,
            cache: cache, defaults: fixture.defaults
        )

        _ = await store.refresh(providerID: "cursor", force: true)

        XCTAssertNil(store.localSnapshots["cursor"]?.usageHistory)
        XCTAssertNotNil(store.localSnapshots["cursor"]?.line(label: "Total usage"))
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "cursor"), "history-fixture")
    }

    func testRateLimitWaitStartsWhenResponseArrivesAndResumesAfterDeadline() async throws {
        for (header, delay) in [("120", 120.0), (nil, 3_600.0)] as [(String?, Double)] {
            let clock = CursorHistoryClock(now)
            let fixture = try makeFixture(clock: clock)
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            await fixture.http.setFailure(429, retryAfter: header)
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            XCTAssertNil(fixture.store.localSnapshots["cursor"]?.usageHistory)
            XCTAssertNotNil(fixture.store.localSnapshots["cursor"]?.warning)
            await fixture.http.setFailure(nil)

            clock.advance(delay - 1)
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            let waitingCount = await fixture.http.historyRequests
            XCTAssertEqual(waitingCount, 1)
            XCTAssertNil(fixture.store.localSnapshots["cursor"]?.usageHistory)

            clock.advance(2)
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            let resumedCount = await fixture.http.historyRequests
            XCTAssertEqual(resumedCount, 2)
            XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 100)
            XCTAssertNil(fixture.store.localSnapshots["cursor"]?.warning)
        }
    }

    func testRetryAfterAcceptsHTTPDateAndRejectsInvalidValues() {
        XCTAssertEqual(CursorProvider.retryDate("120", receivedAt: now), now.addingTimeInterval(120))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        XCTAssertEqual(
            CursorProvider.retryDate(formatter.string(from: now.addingTimeInterval(300)), receivedAt: now),
            now.addingTimeInterval(300))
        for invalid in [nil, "-1", "NaN", "inf", "garbage"] {
            XCTAssertEqual(CursorProvider.retryDate(invalid, receivedAt: now), now.addingTimeInterval(3_600))
        }
    }

    private func makeFixture(clock: CursorHistoryClock? = nil) throws -> (
        store: WidgetDataStore, http: CursorRecoveryHTTP, cache: ProviderSnapshotCache, defaults: UserDefaults,
        suite: String,
        sqlite: CursorRecoverySQLite, clock: CursorHistoryClock
    ) {
        let clock = clock ?? CursorHistoryClock(now)
        let http = CursorRecoveryHTTP(body: try body(tokens: [100]), clock: clock)
        let sqlite = CursorRecoverySQLite(accessToken: try token(identity: "history-fixture"))
        let suite = "EgasuTests.CursorUsageHistoryRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { clock.now })
        let store = makeStore(sqlite: sqlite, http: http, clock: clock, cache: cache, defaults: defaults)
        return (store, http, cache, defaults, suite, sqlite, clock)
    }

    private func makeStore(
        sqlite: CursorRecoverySQLite, http: CursorRecoveryHTTP, clock: CursorHistoryClock,
        cache: ProviderSnapshotCache, defaults: UserDefaults
    ) -> WidgetDataStore {
        let provider = CursorProvider(
            authStore: CursorAuthStore(sqlite: sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: http), now: { clock.now }, pricing: { TestPricing.bundled }
        )
        return WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults, now: { clock.now }
        )
    }

    private func token(identity: String?, expiresAt: Int = 9_999_999_999) throws -> String {
        var claims: [String: Any] = ["exp": expiresAt]
        if let identity { claims["sub"] = "google-oauth2|\(identity)" }
        let payload = try JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return "a.\(payload).c"
    }

    private func body(tokens: [Int]) throws -> Data {
        try CursorEventFixture.page(tokens.map { CursorEventFixture.event(date: now, tokens: $0, cents: 5) })
    }

    private func captureLogs(_ operation: () async -> Void) async throws -> String {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgasuTests.CursorRecovery.\(UUID().uuidString)", isDirectory: true)
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
        await operation()
        return try String(contentsOf: directory.appendingPathComponent("egasu.log"), encoding: .utf8)
    }
}

private actor CursorRecoveryHTTP: HTTPClient {
    private var body: Data
    private let clock: CursorHistoryClock
    private var failure: Int?
    private var retryAfter: String?
    private(set) var historyRequests = 0

    init(body: Data, clock: CursorHistoryClock) { self.body = body; self.clock = clock }

    func setBody(_ body: Data) { self.body = body }
    func setFailure(_ status: Int?, retryAfter: String? = nil) {
        failure = status
        self.retryAfter = retryAfter
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let url = request.url.absoluteString
        let body: String
        if url.contains("get-filtered-usage-events") {
            historyRequests += 1
            if let failure {
                clock.advance(15)
                return HTTPResponse(
                    statusCode: failure, headers: retryAfter.map { ["retry-after": $0] } ?? [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: self.body)
        } else if url.contains("GetCurrentPeriodUsage") {
            body = #"{"enabled":true,"planUsage":{"limit":100,"remaining":75,"totalPercentUsed":25}}"#
        } else if url.contains("GetPlanInfo") {
            body = #"{"planInfo":{"planName":"pro"}}"#
        } else if url.contains("GetCreditGrantsBalance") {
            body = #"{"hasCreditGrants":false}"#
        } else if url.contains("api/auth/stripe") {
            body = #"{"customerBalance":0}"#
        } else {
            return HTTPResponse(statusCode: 404, headers: [:], body: Data())
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}

private final class CursorHistoryClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var now: Date { lock.withLock { date } }
    func advance(_ interval: TimeInterval) { lock.withLock { date.addTimeInterval(interval) } }
}

private final class CursorRecoverySQLite: SQLiteAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var accessToken: String

    init(accessToken: String) { self.accessToken = accessToken }
    func setToken(_ token: String) { lock.withLock { accessToken = token } }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.withLock { sql.contains(CursorAuthStore.accessTokenKey) ? accessToken : nil }
    }

    func execute(path: String, sql: String) throws {}
}
