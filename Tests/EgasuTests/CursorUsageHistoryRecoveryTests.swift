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
        for descriptor in CursorProvider().widgetDescriptors.filter(\.isSpendTile) {
            let data = fixture.store.data(for: descriptor)
            XCTAssertTrue(data.hasData, descriptor.id)
            XCTAssertTrue(data.isZeroUsage, descriptor.id)
        }
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

    func testLiveQuotaWithoutBillingCycleCanNotifyWithoutProvidingASoftLimit() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
        XCTAssertEqual(snapshot.liveQuotaAccountKey, "history-fixture")
        XCTAssertEqual(snapshot.liveQuotaObservedAt, fixture.clock.now)
        XCTAssertNil(
            SoftLimitObservation.project(
                snapshot: snapshot, descriptors: CursorProvider().widgetDescriptors, window: .all,
                now: fixture.clock.now))
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
        for descriptor in CursorProvider().widgetDescriptors.filter(\.isSpendTile) {
            let data = fixture.store.data(for: descriptor)
            XCTAssertFalse(data.hasData, descriptor.id)
            XCTAssertTrue(data.selectedValues.isEmpty, descriptor.id)
        }

        await fixture.http.setFailure(nil)
        await fixture.http.setBody(try body(tokens: [200]))
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 200)
    }

    func testQuotaFailureRetainsOnlyVerifiedCurrentAccountIncludingAfterRestart() async throws {
        for identity in ["history-fixture", "different-account", nil] {
            let fixture = try makeFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            fixture.sqlite.setToken(try token(identity: identity))
            await fixture.http.failQuota()

            _ = await fixture.store.refresh(providerID: "cursor", force: true)

            let sameAccount = identity == "history-fixture"
            XCTAssertNotNil(fixture.store.providerErrors["cursor"])
            XCTAssertEqual(fixture.store.snapshots["cursor"]?.line(label: "Total usage") != nil, sameAccount)
            XCTAssertEqual(fixture.store.localSnapshots["cursor"]?.usageHistory != nil, sameAccount)
            let restarted = makeStore(
                sqlite: fixture.sqlite, http: fixture.http, clock: fixture.clock,
                cache: ProviderSnapshotCache(userDefaults: fixture.defaults), defaults: fixture.defaults)
            XCTAssertNil(restarted.snapshots["cursor"])
            _ = await restarted.refresh(providerID: "cursor", force: true)
            XCTAssertEqual(restarted.snapshots["cursor"]?.usageHistory != nil, sameAccount)
        }
    }

    func testScheduledRefreshRechecksLoginAndReusesOnlyTheSameCursorAccountWithinTTL() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)

        fixture.sqlite.setToken(try token(identity: "history-fixture", expiresAt: 9_999_999_998))
        let same = await fixture.store.refresh(providerID: "cursor")
        XCTAssertEqual(same, .cacheHit)
        let beforeSwitch = await fixture.http.quotaRequests
        XCTAssertEqual(beforeSwitch, 1)

        fixture.sqlite.setToken(try token(identity: "another-account"))
        await fixture.http.setBody(try body(tokens: [200]))
        let changed = await fixture.store.refresh(providerID: "cursor")

        XCTAssertEqual(changed, .refreshed)
        let afterSwitch = await fixture.http.quotaRequests
        XCTAssertEqual(afterSwitch, 2)
        XCTAssertEqual(fixture.store.snapshots["cursor"]?.usageHistory?.series.daily.first?.totalTokens, 200)
        XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "cursor"), "another-account")
    }

    func testScheduledRefreshDoesNotApplyPreviousCursorAccountFailureBackoffToNewLogin() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        await fixture.http.failQuota()
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        XCTAssertNotNil(fixture.store.providerErrors["cursor"])

        fixture.sqlite.setToken(try token(identity: "new-login"))
        await fixture.http.failQuota(false)
        let switched = await fixture.store.refresh(providerID: "cursor")

        XCTAssertEqual(switched, .refreshed)
        XCTAssertNil(fixture.store.providerErrors["cursor"])
        XCTAssertEqual(fixture.store.snapshots["cursor"]?.producedByIdentityKey, "new-login")
        XCTAssertEqual(fixture.store.snapshots["cursor"]?.liveQuotaAccountKey, "new-login")
    }

    func testWaitingBatchDoesNotShowAQueuedCursorRefreshForItsFreshAccountCache() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let first = TestProviderRuntime(
            provider: MockData.codex, descriptors: [],
            snapshot: .make(provider: MockData.codex, plan: nil, lines: [], refreshedAt: now))
        let cursor = CursorProvider(
            authStore: CursorAuthStore(sqlite: fixture.sqlite, keychain: FakeKeychain()),
            usageClient: CursorUsageClient(http: fixture.http), now: { [clock = fixture.clock] in clock.now },
            pricing: { .empty })
        let queue = BackgroundWorkQueue()
        let store = WidgetDataStore(
            registry: .from([first, cursor]), providers: [first, cursor], cache: fixture.cache,
            defaults: fixture.defaults, now: { fixture.clock.now }, workQueue: queue)
        _ = await store.refresh(providerID: "cursor", force: true)

        let acquired = await queue.acquire("hold-first-provider")
        let ticket = try XCTUnwrap(acquired)
        let batch = Task { await store.refreshAll() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while queue.pendingCount == 0 && ContinuousClock.now < deadline { await Task.yield() }

        XCTAssertEqual(queue.pendingCount, 1)
        XCTAssertTrue(store.isRefreshQueued(for: "codex"))
        XCTAssertFalse(store.isRefreshQueued(for: "cursor"))
        queue.finish(ticket)
        await batch.value
        let quotaRequests = await fixture.http.quotaRequests
        XCTAssertEqual(quotaRequests, 1)
    }

    func testTimeoutPreservesDisplayOnlyForVerifiedCursorLogin() async throws {
        for identity in ["history-fixture", "new-login", nil] {
            let fixture = try makeFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            var previous = try XCTUnwrap(fixture.store.snapshots["cursor"])
            previous.liveQuotaObservedAt = fixture.clock.now
            fixture.cache.store(previous, producedByIdentityKey: "history-fixture")
            let updatedToken = try token(identity: identity, expiresAt: 9_999_999_998)
            let delayed = RoutingHTTPClient { [sqlite = fixture.sqlite] _ in
                sqlite.setToken(updatedToken)
                try await Task.sleep(for: .seconds(60))
                throw URLError(.timedOut)
            }
            let cursor = CursorProvider(
                authStore: CursorAuthStore(sqlite: fixture.sqlite, keychain: FakeKeychain()),
                usageClient: CursorUsageClient(http: delayed))
            let store = WidgetDataStore(
                registry: .from([cursor]), providers: [cursor], cache: fixture.cache, defaults: fixture.defaults,
                providerRefreshTimeout: 1, providerIdentityKeys: ["cursor": "history-fixture"])
            XCTAssertNotNil(store.snapshots["cursor"]?.usageHistory)

            let outcome = await store.refresh(providerID: "cursor", force: true)

            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(delayed.requests.first?.url, CursorUsageClient.usageURL)
            XCTAssertTrue(store.providerErrors["cursor"]?.contains("timed out") == true)
            if identity == "history-fixture" {
                let retained = try XCTUnwrap(store.snapshots["cursor"])
                XCTAssertEqual(retained.usageHistory, previous.usageHistory)
                XCTAssertEqual(retained.line(label: "Total usage"), previous.line(label: "Total usage"))
                XCTAssertEqual(retained.refreshedAt, previous.refreshedAt)
                XCTAssertNil(retained.liveQuotaObservedAt)
                XCTAssertNil(fixture.cache.snapshot(providerID: "cursor")?.liveQuotaObservedAt)
            } else {
                XCTAssertNil(store.snapshots["cursor"])
            }
            XCTAssertEqual(fixture.cache.producedByIdentityKey(providerID: "cursor"), "history-fixture")
            await store.waitForAccountRefreshes(providerIDs: ["cursor"])
        }
    }

    func testQuotaFailureDropsMismatchedMemoryOnlySnapshot() throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        let provider = CursorProvider(authStore: CursorAuthStore(sqlite: fixture.sqlite, keychain: FakeKeychain()))
        let store = ProviderSnapshotStore(
            registry: .from([provider]), cache: fixture.cache, identityKeys: [:], familyTotalHistoryCardIDs: [],
            isProviderEnabled: { _ in true }, now: { self.now })
        var old = ProviderSnapshot(providerID: "cursor", displayName: "Cursor", lines: [])
        old.producedByIdentityKey = "previous"
        XCTAssertTrue(store.useCachedSnapshot(old))
        var failure = ProviderSnapshot.error(provider: provider.provider, error: CursorUsageError.connectionFailed)
        failure.producedByIdentityKey = "current"

        _ = store.accept(failure, from: provider)

        XCTAssertNil(store.localSnapshots["cursor"])
    }

    func testTimeoutNeverPromptsWhenCursorKeychainAccountIsUnverified() async throws {
        let fixture = try makeFixture()
        defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
        _ = await fixture.store.refresh(providerID: "cursor", force: true)
        fixture.sqlite.membershipType = "free"
        let keychain = LockedCursorRecoveryKeychain()
        let delayed = RoutingHTTPClient { _ in
            try await Task.sleep(for: .seconds(60))
            throw URLError(.timedOut)
        }
        let cursor = CursorProvider(
            authStore: CursorAuthStore(sqlite: fixture.sqlite, keychain: keychain),
            usageClient: CursorUsageClient(http: delayed))
        let store = WidgetDataStore(
            registry: .from([cursor]), providers: [cursor], cache: fixture.cache, defaults: fixture.defaults,
            providerRefreshTimeout: 1, providerIdentityKeys: ["cursor": "history-fixture"])
        XCTAssertNotNil(store.snapshots["cursor"]?.usageHistory)

        let outcome = await store.refresh(providerID: "cursor", force: true)
        await store.waitForAccountRefreshes(providerIDs: ["cursor"])

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(delayed.requests.first?.url, CursorUsageClient.usageURL)
        XCTAssertTrue(store.providerErrors["cursor"]?.contains("timed out") == true)
        XCTAssertNil(store.snapshots["cursor"])
        XCTAssertEqual(keychain.interactionRequests, [true, true, false])
    }

    func testCLIVerifiesCursorAccountBeforeUsingFreshCache() async throws {
        for (identity, stamp) in [
            ("history-fixture", "history-fixture"), ("current", "old"), (nil, "old"), ("current", nil)
        ] as [(String?, String?)] {
            let fixture = try makeFixture()
            defer { fixture.defaults.removePersistentDomain(forName: fixture.suite) }
            _ = await fixture.store.refresh(providerID: "cursor", force: true)
            var cached = try XCTUnwrap(fixture.store.localSnapshots["cursor"])
            cached.refreshedAt = Date()
            cached.quotaObservedAt = Date()
            fixture.cache.store(cached, producedByIdentityKey: stamp)
            fixture.sqlite.setToken(try token(identity: identity))
            await fixture.http.failQuota()
            let provider = CursorProvider(
                authStore: CursorAuthStore(sqlite: fixture.sqlite, keychain: FakeKeychain()),
                usageClient: CursorUsageClient(http: fixture.http)
            )

            let cacheKey = "openusage.providerSnapshots.v10"
            let saved = try XCTUnwrap(fixture.defaults.data(forKey: cacheKey))
            let result = try await UsageReader(userDefaults: fixture.defaults, providers: [provider])
                .read(providerID: "cursor")

            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
            let providers = try XCTUnwrap(object["providers"] as? [String: Any])
            let sameAccount = identity == "history-fixture"
            XCTAssertEqual(providers["cursor"] != nil, sameAccount)
            XCTAssertEqual(result.warnings.isEmpty, sameAccount)
            XCTAssertEqual(fixture.defaults.data(forKey: cacheKey), saved)
        }
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
    private var quotaFailed = false
    private var failure: Int?
    private var retryAfter: String?
    private(set) var historyRequests = 0
    private(set) var quotaRequests = 0

    init(body: Data, clock: CursorHistoryClock) { self.body = body; self.clock = clock }

    func failQuota(_ failed: Bool = true) { quotaFailed = failed }
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
            quotaRequests += 1
            if quotaFailed { return HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
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
    private var membership: String?
    var membershipType: String? {
        get { lock.withLock { membership } }
        set { lock.withLock { membership = newValue } }
    }

    init(accessToken: String) { self.accessToken = accessToken }
    func setToken(_ token: String) { lock.withLock { accessToken = token } }

    func queryValue(path: String, sql: String) throws -> String? {
        lock.withLock {
            if sql.contains(CursorAuthStore.accessTokenKey) { return accessToken }
            if sql.contains(CursorAuthStore.membershipTypeKey) { return membership }
            return nil
        }
    }

    func execute(path: String, sql: String) throws {}
}

private final class LockedCursorRecoveryKeychain: KeychainAccessing, @unchecked Sendable {
    private let lock = NSLock()
    private var reads: [Bool] = []
    var interactionRequests: [Bool] { lock.withLock { reads } }

    func readGenericPassword(service: String) throws -> String? {
        try readGenericPassword(service: service, allowInteraction: true)
    }

    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        lock.withLock { reads.append(allowInteraction) }
        if !allowInteraction { throw KeychainError.readFailed("Keychain requires approval") }
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws {}
    func deleteGenericPassword(service: String) throws {}
}
