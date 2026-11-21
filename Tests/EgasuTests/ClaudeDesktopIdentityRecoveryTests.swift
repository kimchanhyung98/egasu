import XCTest
@testable import Egasu

extension ClaudeDesktopAuthStoreTests {
    @MainActor
    func testRestrictedStoredLoginUsesOnlyEligibleDesktopAfterFileAuthenticationFails() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let now = now
        let path = "/tmp/claude"
        let other = "22222222-2222-4222-8222-222222222222"
        for (desktopAccount, allowed, expectedUsage) in [
            (account, true, true), (other, true, false), (account, false, false)
        ] {
            let fixture = try makeFixture(
                activeOrganization: organization, activeAccountUUID: desktopAccount,
                v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
            )
            fixture.files.files["\(path)/.claude.json"] = """
                {"oauthAccount":{"accountUuid":"\(account)","organizationUuid":"\(organization)"}}
                """
            fixture.files.files["\(path)/.credentials.json"] =
                #"{"claudeAiOauth":{"accessToken":"revoked-file","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            let restricted = #"{"claudeAiOauth":{"accessToken":"restricted","scopes":["user:inference"]}}"#
            let http = RoutingHTTPClient { request in
                if request.headers["Authorization"] == "Bearer revoked-file" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                XCTAssertEqual(request.headers["Authorization"], "Bearer desktop-token")
                XCTAssertEqual(request.url.path, "/api/oauth/usage")
                return HTTPResponse(
                    statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":25}}"#.utf8))
            }
            let runtime = ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": path]),
                    files: fixture.files, keychain: FakeKeychain(restricted),
                    desktop: fixture.store, allowsDesktopFallback: allowed, now: { now }),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
                now: { now }, pricing: { TestPricing.bundled })
            let snapshot = await ProviderRefreshContext.$isManual.withValue(true) { await runtime.refresh() }
            let paths = ["/api/oauth/profile"] + (expectedUsage ? ["/api/oauth/usage"] : [])
            XCTAssertEqual(http.requests.map(\.url.path), paths)
            XCTAssertEqual(fixture.keyReader.calls.isEmpty, !allowed)
            XCTAssertEqual(snapshot.authenticationIssue, expectedUsage ? nil : .signInNeeded)
            XCTAssertEqual(snapshot.line(label: "Session") != nil, expectedUsage)
        }
    }

    @MainActor
    func testNewKeychainLoginWinsBeforeAndDuringRestrictedDesktopFallback() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let other = "22222222-2222-4222-8222-222222222222"
        let now = now
        enum SwitchPoint: Sendable {
            case fileResponse, desktopKeyRead, desktopResponse
        }
        for switchPoint in [SwitchPoint.fileResponse, .desktopKeyRead, .desktopResponse] {
            let fixture = try makeFixture(
                activeOrganization: organization, activeAccountUUID: switchPoint == .desktopResponse ? account : other,
                v2: [cacheKey(organization: organization): tokenEntry("desktop", expiresIn: 3_600)])
            fixture.files.files["/tmp/claude/.claude.json"] = """
                {"oauthAccount":{"accountUuid":"\(account)","organizationUuid":"\(organization)"}}
                """
            fixture.files.files["/tmp/claude/.credentials.json"] =
                #"{"claudeAiOauth":{"accessToken":"file","scopes":["user:profile"]}}"#
            let keychain = FakeKeychain(#"{"claudeAiOauth":{"accessToken":"restricted","scopes":["user:inference"]}}"#)
            let fresh = #"{"claudeAiOauth":{"accessToken":"new-cli","scopes":["user:profile"]}}"#
            if switchPoint == .desktopKeyRead {
                fixture.keyReader.onRead = { keychain.value = fresh }
            }
            let http = RoutingHTTPClient { request in
                switch request.headers["Authorization"] {
                case "Bearer file":
                    if switchPoint == .fileResponse { keychain.value = fresh }
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                case "Bearer desktop":
                    keychain.value = fresh
                    return HTTPResponse(
                        statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":5}}"#.utf8))
                default:
                    XCTAssertEqual(request.headers["Authorization"], "Bearer new-cli")
                    return HTTPResponse(
                        statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":70}}"#.utf8))
                }
            }
            let provider = ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]), files: fixture.files,
                    keychain: keychain, desktop: fixture.store, now: { now }),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
                now: { now }, pricing: { TestPricing.bundled })

            let snapshot = await provider.refresh()

            let expected =
                ["Bearer file"] + (switchPoint == .desktopResponse ? ["Bearer desktop"] : []) + ["Bearer new-cli"]
            XCTAssertEqual(http.requests.compactMap { $0.headers["Authorization"] }, expected)
            XCTAssertEqual(
                snapshot.line(label: "Session"),
                .progress(
                    label: "Session", used: 70, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs))
        }
    }

    @MainActor
    func testLosingCLIProfileScopeFallsBackToDesktopDuringSameRefresh() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let fixture = try makeFixture(
            activeOrganization: organization,
            activeAccountUUID: account,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        fixture.files.files["/tmp/claude/.claude.json"] = """
            {"oauthAccount":{"accountUuid":"\(account)","organizationUuid":"\(organization)"}}
            """
        let path = "/tmp/claude/.credentials.json"
        fixture.files.files[path] = """
            {"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}
            """
        let http = RoutingHTTPClient { request in
            if request.url.path == "/v1/oauth/token" {
                let body = #"{"access_token":"fresh","refresh_token":"rotated","scope":"user:inference"}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer desktop-token")
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42}}"#.utf8))
        }
        let now = now
        let runtime = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: fixture.files, keychain: FakeKeychain(), desktop: fixture.store, now: { now }),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
            now: { now }, pricing: { TestPricing.bundled })

        let snapshot = await runtime.refresh()

        XCTAssertEqual(http.requests.map(\.url.path), ["/v1/oauth/token", "/api/oauth/usage"])
        XCTAssertNotNil(snapshot.line(label: "Session"))
        XCTAssertNil(snapshot.authenticationIssue)
        let saved = try XCTUnwrap(ClaudeAuthStore.parseCredentials(try fixture.files.readText(path))?.claudeAiOauth)
        XCTAssertEqual(saved.refreshToken, "rotated")
        XCTAssertEqual(saved.scopes, ["user:inference"])
    }

    @MainActor
    func testLegacyDesktopLoginRecoversIdentityWithoutWritingCredentials() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let originalFiles = fixture.files.files
        let keychain = FakeKeychain()
        let organization = organization
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer desktop-token")
            let body = request.url.path.hasSuffix("/profile")
                ? #"{"account":{"uuid":"11111111-1111-4111-8111-111111111111"},"organization":{"uuid":"\#(organization)"}}"#
                : #"{"five_hour":{"utilization":42}}"#
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let now = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: fixture.files, keychain: keychain,
                                       desktop: fixture.store, now: { now }),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { now }, pricing: { TestPricing.bundled }
        )
        let result = await provider.refresh()

        XCTAssertEqual(result.line(label: "Session"), .progress(
            label: "Session", used: 42, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
        ))
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertEqual(fixture.files.files, originalFiles)
        XCTAssertNil(keychain.value)
    }

    @MainActor
    func testLegacyDesktopProfile401NeverExchangesRefreshToken() async throws {
        let fixture = try makeFixture(
            activeOrganization: organization,
            v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
        )
        let originalFiles = fixture.files.files
        let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
        let now = now
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(environment: FakeEnvironment(), files: fixture.files, keychain: FakeKeychain(),
                                       desktop: fixture.store, now: { now }),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { now }, pricing: { TestPricing.bundled }
        )
        let result = await provider.refresh()

        XCTAssertEqual(badge(result.lines, "Error"), ClaudeAuthError.desktopTokenExpired.localizedDescription)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
        XCTAssertEqual(fixture.files.files, originalFiles)
    }

    @MainActor
    func testLegacyDesktopFallbackMustMatchBoundHomeIdentity() async throws {
        let account = "11111111-1111-4111-8111-111111111111"
        let otherAccount = "22222222-2222-4222-8222-222222222222"
        let cases: [(homeOrganization: String?, profileAccount: String, profileOrganization: String, allowed: Bool)] = [
            (organization, account, organization, true),
            (organization, otherAccount, organization, false),
            (organization, account, otherOrganization, false),
            (nil, account, organization, true),
            (nil, account, otherOrganization, true),
            (nil, otherAccount, organization, false)
        ]
        for testCase in cases {
            let primaryRequestPath = testCase.homeOrganization == nil ? "/api/oauth/profile" : "/api/oauth/usage"
            let fixture = try makeFixture(
                activeOrganization: testCase.profileOrganization,
                v2: [cacheKey(organization: testCase.profileOrganization): tokenEntry("desktop-token", expiresIn: 3_600)]
            )
            var homeIdentity = ["accountUuid": account]
            if let organization = testCase.homeOrganization { homeIdentity["organizationUuid"] = organization }
            fixture.files.files["/tmp/claude/.claude.json"] = String(
                decoding: try JSONSerialization.data(withJSONObject: ["oauthAccount": homeIdentity]), as: UTF8.self
            )
            let originalFiles = fixture.files.files
            let credentials = #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            let keychain = FakeKeychain(credentials)
            let http = RoutingHTTPClient { request in
                if request.headers["Authorization"] == "Bearer revoked-cli" {
                    XCTAssertEqual(request.url.path, primaryRequestPath)
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                XCTAssertEqual(request.headers["Authorization"], "Bearer desktop-token")
                let body = request.url.path.hasSuffix("/profile")
                    ? #"{"account":{"uuid":"\#(testCase.profileAccount)"},"organization":{"uuid":"\#(testCase.profileOrganization)"}}"#
                    : #"{"five_hour":{"utilization":42}}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
            }
            let now = now
            let provider = ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                    files: fixture.files, keychain: keychain, desktop: fixture.store, now: { now }
                ),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), now: { now }, pricing: { TestPricing.bundled }
            )

            let result = await provider.refresh()

            if testCase.allowed {
                XCTAssertEqual(result.line(label: "Session"), .progress(
                    label: "Session", used: 42, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs
                ))
                XCTAssertEqual(http.requests.map(\.url.path), [
                    primaryRequestPath, "/api/oauth/profile", "/api/oauth/usage"
                ])
            } else {
                XCTAssertEqual(badge(result.lines, "Error"), ClaudeUsageStateStore.StoreError.identityUnavailable.localizedDescription)
                XCTAssertNil(result.line(label: "Session"))
                XCTAssertEqual(http.requests.map(\.url.path), [primaryRequestPath, "/api/oauth/profile"])
            }
            XCTAssertEqual(fixture.files.files, originalFiles)
            XCTAssertEqual(keychain.value, credentials)
        }
    }
}
