import XCTest
@testable import Egasu

/// 테스트별 임시 sink와 명시적 level로 전역 상태 경쟁 차단
final class AppLogTests: XCTestCase {
    private var tempDir: URL!
    private var sink: LogFile!
    private var originalSink: LogFile!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgasuTests.AppLog.\(UUID().uuidString)", isDirectory: true)
        sink = LogFile(directory: tempDir, fileName: "egasu.log")
        sink.open()
        originalSink = AppLog.sink
        AppLog.sink = sink
    }

    override func tearDownWithError() throws {
        AppLog.sink = originalSink
        AppLog.reloadLevel() // 이후 코드용으로 실제 저장된 floor 복원
        if let tempDir, FileManager.default.fileExists(atPath: tempDir.path) {
            try FileManager.default.removeItem(at: tempDir)
        }
    }

    private func fileContents() throws -> String {
        try String(contentsOf: tempDir.appendingPathComponent("egasu.log"), encoding: .utf8)
    }

    func testUnreadableAPIKeyLogsTheFailureWithoutTheKeyOrPath() throws {
        AppLog.reloadLevel(.info)
        let path = OpenRouterAuthStore.configPaths[0]
        let privateKey = "private-key-for-log-fixture"
        let files = FakeFiles([path: privateKey])
        files.unreadablePaths = [path]
        let store = OpenRouterAuthStore(files: files, environment: FakeEnvironment())

        XCTAssertThrowsError(try store.requireAPIKey())
        XCTAssertThrowsError(try store.deleteAPIKey())

        let log = try fileContents()
        XCTAssertTrue(log.contains("operation=credential_read result=failure category=credential_access"))
        XCTAssertTrue(log.contains("operation=credential_remove result=failure category=permission"))
        XCTAssertFalse(log.contains(privateKey))
        XCTAssertFalse(log.contains(path))
    }

    func testCLIUsesTheContainingAppsLogLevel() throws {
        let suite = "EgasuTests.AppLog.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set("debug", forKey: LogLevelSetting.key)
        AppLog.reloadLevel(defaults: defaults)
        AppLog.debug(.refresh, "visible-cli-debug")
        defaults.set("error", forKey: LogLevelSetting.key)
        AppLog.reloadLevel(defaults: defaults)
        AppLog.warn(.refresh, "hidden-cli-warning")

        let log = try fileContents()
        XCTAssertTrue(log.contains("visible-cli-debug"))
        XCTAssertFalse(log.contains("hidden-cli-warning"))
    }

    func testProviderLogTagsGroupAccountsAndPreserveCollectorNames() throws {
        AppLog.error(LogTag.plugin("codex@profile-private"), "quota unavailable")
        AppLog.error(LogTag.auth("claude@profile-private"), "login unavailable")
        AppLog.error(LogTag.plugin("pi"), "history unavailable")

        let log = try fileContents()
        XCTAssertTrue(log.contains("[plugin:codex] quota unavailable"))
        XCTAssertTrue(log.contains("[auth:claude] login unavailable"))
        XCTAssertTrue(log.contains("[plugin:pi] history unavailable"))
        XCTAssertFalse(log.contains("profile-private"))
    }

    func testInfoFloorSuppressesDebugButKeepsInfoAndError() throws {
        AppLog.reloadLevel(.info)
        AppLog.debug(.cache, "debug-below-floor")
        AppLog.info(.refresh, "info-at-floor")
        AppLog.error(.http, "error-always")

        let contents = try fileContents()
        XCTAssertFalse(contents.contains("debug-below-floor"), contents)
        XCTAssertTrue(contents.contains("info-at-floor"), contents)
        XCTAssertTrue(contents.contains("error-always"), contents)
    }

    func testDebugFloorLetsDebugThrough() throws {
        AppLog.reloadLevel(.debug)
        AppLog.debug(.cache, "debug-now-visible")
        XCTAssertTrue(try fileContents().contains("debug-now-visible"))
    }

    @MainActor
    func testHTTPLogsExcludeRequestAndResponsePayloadsAtEveryStatus() async throws {
        AppLog.reloadLevel(.debug)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HTTPLogURLProtocol.self]
        let session = URLSessionHTTPClient.makeCookieFreeSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = URLSessionHTTPClient()

        for status in [200, 400, 401, 500] {
            let url = try XCTUnwrap(URL(string: "https://egasu-log-test.invalid/\(status)?token=PRIVATE_QUERY_VALUE"))
            let response = try await client.send(
                HTTPRequest(
                    method: "POST", url: url,
                    headers: ["Authorization": "Bearer PRIVATE_AUTH_VALUE", "Cookie": "session=PRIVATE_COOKIE_VALUE"],
                    body: Data("PRIVATE_REQUEST_BODY".utf8)
                ), using: session)
            XCTAssertEqual(response.statusCode, status)
            XCTAssertEqual(String(decoding: response.body, as: UTF8.self), HTTPLogURLProtocol.body)
            XCTAssertEqual(response.header("x-private-header"), "PRIVATE_RESPONSE_HEADER")
        }

        let contents = try fileContents()
        for status in [200, 400, 401, 500] {
            XCTAssertTrue(contents.contains("POST https://egasu-log-test.invalid/\(status)?token="), contents)
            XCTAssertTrue(contents.contains("-> \(status)"), contents)
        }
        for value in [
            "PRIVATE_QUERY_VALUE", "PRIVATE_AUTH_VALUE", "PRIVATE_COOKIE_VALUE",
            "PRIVATE_REQUEST_BODY", "PRIVATE_RESPONSE_HEADER", HTTPLogURLProtocol.body
        ] {
            XCTAssertFalse(contents.contains(value), contents)
        }
    }

    func testDynamicProviderURLsUseFixedLogLabels() async throws {
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 200, headers: [:], body: Data()))
        let tenant = "https://private-org.example.invalid/private-account"
        let config = ClaudeOAuthConfig(
            usageURL: try XCTUnwrap(URL(string: tenant + "/usage")),
            refreshURL: try XCTUnwrap(URL(string: tenant + "/refresh")), clientID: "fixture")
        let claude = ClaudeUsageClient(httpClient: http)
        _ = try await claude.fetchUsage(accessToken: "fixture", config: config)
        _ = try await claude.fetchProfile(accessToken: "fixture", config: config)
        _ = try await claude.refreshToken("fixture", config: config)
        _ = try await DevinUsageClient(http: http).fetchUserStatus(
            auth: DevinAuth(apiKey: "fixture"), apiServerURL: tenant)
        _ = try await CopilotOrgBillingClient(http: http).fetchUsageSummary(org: "private-org", token: "fixture")
        let service = KimiService(baseURL: tenant, oauthHost: tenant)
        let kimi = KimiUsageClient(http: http)
        _ = try await kimi.fetchUsage(accessToken: "fixture", service: service)
        http.response = HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"access_token":"fixture","refresh_token":"fixture","expires_in":3600}"#.utf8))
        _ = try await kimi.refreshToken(refreshToken: "fixture", service: service)

        XCTAssertTrue(http.requests.allSatisfy { $0.url.absoluteString.contains("private-org") })
        XCTAssertEqual(
            http.requests.map(\.logTarget),
            [
                "claude.usage", "claude.profile", "claude.oauth_refresh", "devin.user_status",
                "copilot.org_billing_summary",
                "kimi.usage", "kimi.oauth_refresh"
            ])
    }

    @MainActor
    func testLocalAPIDoesNotLogUntrustedRequestText() throws {
        AppLog.reloadLevel(.debug)
        let server = LocalUsageServer(state: {
            LocalUsageAPI.State(enabledOrderedIDs: [], knownIDs: [], snapshots: [:], limitDescriptors: [:], errors: [:])
        })
        _ = server.route(head: "GET /v1/limits?token=OPAQUE_PRIVATE_VALUE HTTP/1.1\r\nHost: localhost\r\n")
        _ = server.route(head: "GET /v1/limits/PRIVATE_LIMITS_ACCOUNT_ID HTTP/1.1\r\nHost: localhost\r\n")
        _ = server.route(head: "GET /v1/usage/PRIVATE_USAGE_ACCOUNT_ID HTTP/1.1\r\nHost: localhost\r\n")
        _ = server.route(head: "PRIVATE_METHOD /unknown/private@example.com HTTP/1.1\r\nHost: localhost\r\n")
        let contents = try fileContents()
        XCTAssertFalse(contents.contains("OPAQUE_PRIVATE_VALUE"))
        XCTAssertFalse(contents.contains("PRIVATE_LIMITS_ACCOUNT_ID"))
        XCTAssertFalse(contents.contains("PRIVATE_USAGE_ACCOUNT_ID"))
        XCTAssertFalse(contents.contains("private@example.com"))
        XCTAssertFalse(contents.contains("PRIVATE_METHOD"))
        XCTAssertTrue(contents.contains("/v1/limits"))
        XCTAssertTrue(contents.contains("/v1/limits/provider"))
        XCTAssertTrue(contents.contains("/v1/usage/provider"))
    }

    @MainActor
    func testLocalAPIQueryOnlyTargetsLogUnknownRoute() throws {
        AppLog.reloadLevel(.debug)
        let server = LocalUsageServer(state: {
            LocalUsageAPI.State(enabledOrderedIDs: [], knownIDs: [], snapshots: [:])
        })

        for path in ["?", "?/v1/usage", "?/v1/limits", "?/v1/usage/PRIVATE_ACCOUNT"] {
            XCTAssertEqual(server.route(head: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n").status, 404)
        }

        let contents = try fileContents()
        XCTAssertEqual(contents.components(separatedBy: "GET unknown").count - 1, 4, contents)
        XCTAssertFalse(contents.contains("/v1/usage"), contents)
        XCTAssertFalse(contents.contains("/v1/limits"), contents)
        XCTAssertFalse(contents.contains("PRIVATE_ACCOUNT"), contents)
    }

    func testErrorFloorSuppressesEverythingButError() throws {
        AppLog.reloadLevel(.error)
        AppLog.warn(.http, "warn-below-error-floor")
        AppLog.info(.refresh, "info-below-error-floor")
        AppLog.error(.http, "error-still-written")

        let contents = try fileContents()
        XCTAssertFalse(contents.contains("warn-below-error-floor"), contents)
        XCTAssertFalse(contents.contains("info-below-error-floor"), contents)
        XCTAssertTrue(contents.contains("error-still-written"), contents)
    }

    func testWrittenLineCarriesLevelAndTag() throws {
        AppLog.reloadLevel(.info)
        AppLog.info(.refresh, "hello")
        // grep 친화 형태: `<timestamp> [INFO] [refresh] hello`
        let contents = try fileContents()
        XCTAssertTrue(contents.contains("[INFO] [refresh] hello"), contents)
    }

    func testAutoclosureIsNotEvaluatedBelowFloor() {
        AppLog.reloadLevel(.info)
        var built = false
        // `@autoclosure`로 감싸지므로 `emit`이 실제로 메시지를 만들 때만 side effect 발생
        func expensiveMessage() -> String {
            built = true
            return "expensive"
        }
        AppLog.debug(.cache, expensiveMessage())
        XCTAssertFalse(built, "a below-floor debug line must not build its message")
    }

    func testSecretInLineIsRedactedBeforeWrite() throws {
        AppLog.reloadLevel(.info)
        AppLog.info(.auth, "refreshing with token=sk-1234567890abcdefghij")
        let contents = try fileContents()
        XCTAssertFalse(contents.contains("sk-1234567890abcdefghij"), contents)
    }

    @MainActor
    func testSlowProviderRefreshWritesWarningAtDefaultLogLevel() async throws {
        AppLog.reloadLevel(.info)
        let provider = Provider(id: "slow-test", displayName: "Slow Test", icon: .providerMark("codex"))
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let defaultsName = "EgasuTests.AppLog.slow.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        var ticks = [100.0, 112.5]
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: []),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            monotonicNow: { ticks.count > 1 ? ticks.removeFirst() : ticks[0] }
        )

        _ = await store.refresh(providerID: provider.id, force: true)

        let contents = try fileContents()
        XCTAssertTrue(
            contents.contains("[WARN] [refresh] slow-test slow refresh (12500ms, threshold=10000ms)"),
            contents
        )
    }
}

private final class HTTPLogURLProtocol: URLProtocol, @unchecked Sendable {
    static let body = "PRIVATE_RESPONSE_BODY_WITH_UNSTRUCTURED_ACCOUNT_DETAILS"

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "egasu-log-test.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let status = Int(url.lastPathComponent),
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil,
                headerFields: ["X-Private-Header": "PRIVATE_RESPONSE_HEADER"]
            )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
