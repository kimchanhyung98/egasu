import XCTest
@testable import Egasu

@MainActor
final class ClaudeOAuthConfigTests: XCTestCase {
    func testProductionAndStagingKeepHTTPSAndClientOverrides() throws {
        let production = try store().oauthConfig()
        XCTAssertEqual(production.usageURL.absoluteString, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(production.refreshURL.absoluteString, "https://platform.claude.com/v1/oauth/token")

        let staging = try store([
            "USER_TYPE": "ant", "USE_STAGING_OAUTH": "1", "CLAUDE_CODE_OAUTH_CLIENT_ID": "fixture-client"
        ]).oauthConfig()
        XCTAssertEqual(staging.usageURL.absoluteString, "https://api-staging.anthropic.com/api/oauth/usage")
        XCTAssertEqual(staging.refreshURL.absoluteString, "https://platform.staging.ant.dev/v1/oauth/token")
        XCTAssertEqual(staging.clientID, "fixture-client")
    }

    func testCustomHTTPSKeepsPathAndOverridesLocalBase() throws {
        let auth = store([
            "USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1",
            "CLAUDE_LOCAL_OAUTH_API_BASE": "http://remote.example",
            "CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://custom.example/prefix/"
        ])
        let config = try auth.oauthConfig()

        XCTAssertEqual(config.usageURL.absoluteString, "https://custom.example/prefix/api/oauth/usage")
        XCTAssertEqual(config.refreshURL.absoluteString, "https://custom.example/prefix/v1/oauth/token")
        XCTAssertEqual(auth.keychainServiceCandidates(), ["Claude Code-custom-oauth-credentials"])
    }

    func testLocalDevelopmentDefaultKeepsLoopbackHTTP() throws {
        let auth = store(["USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1"])
        let config = try auth.oauthConfig()

        XCTAssertEqual(config.usageURL.absoluteString, "http://localhost:8000/api/oauth/usage")
        XCTAssertEqual(config.refreshURL.absoluteString, "http://localhost:8000/v1/oauth/token")
        XCTAssertEqual(auth.keychainServiceCandidates(), ["Claude Code-local-oauth-credentials"])
    }

    func testExplicitLoopbackHostsAllowHTTP() throws {
        for base in ["http://localhost:8000", "HTTP://LOCALHOST:8000", "http://127.0.0.1:8000", "http://[::1]:8000"] {
            for environment in endpointEnvironments(base) {
                let config = try store(environment).oauthConfig()
                XCTAssertEqual(config.usageURL.absoluteString, "\(base)/api/oauth/usage")
                XCTAssertEqual(config.refreshURL.absoluteString, "\(base)/v1/oauth/token")
            }
        }
    }

    func testUnsafeEndpointsFailWithoutProductionFallback() {
        let bases = [
            "http://remote.example", "http://192.168.1.20:8000",
            "http://localhost.remote.example", "http://127.0.0.1.remote.example",
            "http://localhost@remote.example", "http://[::ffff:192.168.1.20]",
            "http://localhost.", "http://127.1", "http://2130706433",
            "http://fixture-secret:fixture-secret@remote.example/fixture-secret?fixture-secret#fixture-secret",
            "http://fixture-secret:fixture-secret@exa mple.test?fixture-secret",
            "ftp://localhost", "file:///tmp/oauth", "/relative/oauth", "https:///missing-host"
        ]
        for base in bases {
            for environment in endpointEnvironments(base) {
                let auth = store(environment)
                XCTAssertThrowsError(try auth.oauthConfig(), base) { error in
                    guard case ClaudeAuthError.invalidOAuthURL = error else {
                        return XCTFail("Unexpected error: \(error)")
                    }
                    XCTAssertFalse(error.localizedDescription.contains("fixture-secret"))
                    XCTAssertFalse(UserFacingErrors.message(error).contains("fixture-secret"))
                }
                XCTAssertEqual(auth.keychainServiceCandidates().count, 1)
            }
        }
    }

    func testProviderRejectsRemoteHTTPBeforeSendingAnyCredentials() async {
        for environment in endpointEnvironments("http://remote.example") {
            for (expiresAt, hasIdentity) in [(4_102_444_800_000, true), (1, true), (1, false)] {
                var fixtureFiles = [
                    "/tmp/claude/.credentials.json": #"{"claudeAiOauth":{"accessToken":"fixture-access","refreshToken":"fixture-refresh","expiresAt":\#(expiresAt),"scopes":["user:profile"]}}"#
                ]
                if hasIdentity { fixtureFiles["/tmp/claude/.claude.json"] = claudeUsageTestIdentity() }
                let files = FakeFiles(fixtureFiles)
                let http = FakeHTTPClient(response: HTTPResponse(statusCode: 503, headers: [:], body: Data()))
                let auth = ClaudeAuthStore(
                    environment: FakeEnvironment(environment.merging(["CLAUDE_CONFIG_DIR": "/tmp/claude"]) { _, value in value }),
                    files: files, keychain: FakeKeychain(), allowsDesktopFallback: false
                )
                let provider = ClaudeProvider(
                    authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                    usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                    includeSharedUsage: false, pricing: { TestPricing.bundled }
                )

                let result = await provider.refresh()

                XCTAssertTrue(http.requests.isEmpty)
                XCTAssertFalse(result.lines.isEmpty)
                XCTAssertTrue(result.lines.allSatisfy(\.isError))
                XCTAssertEqual(files.files, fixtureFiles)
            }
        }
    }

    private func store(_ environment: [String: String] = [:]) -> ClaudeAuthStore {
        ClaudeAuthStore(environment: FakeEnvironment(environment), files: FakeFiles(), keychain: FakeKeychain())
    }

    private func endpointEnvironments(_ base: String) -> [[String: String]] {
        [
            ["CLAUDE_CODE_CUSTOM_OAUTH_URL": base],
            ["USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1", "CLAUDE_LOCAL_OAUTH_API_BASE": base]
        ]
    }
}

extension ClaudeDesktopAuthStoreTests {
    @MainActor
    func testNonProductionOAuthDoesNotReadSeedOrSendDesktopCredentials() async throws {
        let environments = [
            ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://custom.example"],
            ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://api.anthropic.com"],
            ["USER_TYPE": "ant", "USE_LOCAL_OAUTH": "1"],
            ["USER_TYPE": "ant", "USE_STAGING_OAUTH": "1"]
        ]
        for environment in environments {
            let fixture = try makeFixture(
                activeOrganization: organization,
                activeAccountUUID: "11111111-1111-4111-8111-111111111111",
                v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)],
                requiresInteraction: true
            )
            let now = now
            let auth = ClaudeAuthStore(
                environment: FakeEnvironment(environment), files: fixture.files,
                keychain: FakeKeychain(), desktop: fixture.store, now: { now }
            )
            for forceDesktopFallback in [false, true] {
                let load = auth.loadCredentialSet(
                    allowDesktopInteraction: true, forceDesktopFallback: forceDesktopFallback
                )
                XCTAssertTrue(load.candidates.isEmpty)
                XCTAssertEqual(load.desktopStatus, forceDesktopFallback ? .notFound : .notChecked)
            }
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
            let provider = ClaudeProvider(
                authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                includeSharedUsage: false, now: { now }, pricing: { TestPricing.bundled }
            )

            let hasCredentials = await provider.hasLocalCredentials()
            let snapshot = await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }

            XCTAssertFalse(hasCredentials)
            XCTAssertEqual(badge(snapshot.lines, "Error"), ClaudeAuthError.notLoggedIn.localizedDescription)
            XCTAssertTrue(fixture.keyReader.calls.isEmpty)
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    @MainActor
    func testProductionOAuthKeepsDesktopFallbackAndSeedingWithIgnoredOverrides() async throws {
        let environments: [[String: String]] = [
            [:],
            ["USE_LOCAL_OAUTH": "1", "USE_STAGING_OAUTH": "1"],
            ["USER_TYPE": "ant", "USE_LOCAL_OAUTH": "0", "USE_STAGING_OAUTH": "0"],
            ["CLAUDE_LOCAL_OAUTH_API_BASE": "http://localhost:8000"],
            ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "  "],
            ["CLAUDE_CODE_OAUTH_CLIENT_ID": "fixture-client"]
        ]
        for environment in environments {
            let fixture = try makeFixture(
                activeOrganization: organization,
                activeAccountUUID: "11111111-1111-4111-8111-111111111111",
                v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
            )
            let now = now
            let auth = ClaudeAuthStore(
                environment: FakeEnvironment(environment), files: fixture.files,
                keychain: FakeKeychain(), desktop: fixture.store, now: { now }
            )
            let http = FakeHTTPClient(
                response: HTTPResponse(
                    statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42}}"#.utf8)
                )
            )
            let provider = ClaudeProvider(
                authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                includeSharedUsage: false, now: { now }, pricing: { TestPricing.bundled }
            )

            let hasCredentials = await provider.hasLocalCredentials()
            let snapshot = await provider.refresh()

            XCTAssertTrue(hasCredentials)
            XCTAssertNotNil(snapshot.line(label: "Session"))
            XCTAssertNil(badge(snapshot.lines, "Error"))
            XCTAssertEqual(http.requests.map(\.url.absoluteString), ["https://api.anthropic.com/api/oauth/usage"])
            XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer desktop-token")
        }
    }

    @MainActor
    func testCustomOAuthPreservesCLIFailureAndInvalidURLErrorWithoutDesktopFallback() async throws {
        let cases: [(String, ClaudeAuthError, Int)] = [
            ("https://custom.example", .tokenExpired, 1),
            ("https://exa mple.com", .invalidOAuthURL, 0)
        ]
        for (baseURL, expectedError, expectedRequests) in cases {
            let fixture = try makeFixture(
                activeOrganization: organization,
                activeAccountUUID: "11111111-1111-4111-8111-111111111111",
                v2: [cacheKey(organization: organization): tokenEntry("desktop-token", expiresIn: 3_600)]
            )
            fixture.files.files["/tmp/claude/.claude.json"] = claudeUsageTestIdentity()
            fixture.files.files["/tmp/claude/.credentials.json"] =
                #"{"claudeAiOauth":{"accessToken":"revoked-cli","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
            let now = now
            let auth = ClaudeAuthStore(
                environment: FakeEnvironment([
                    "CLAUDE_CONFIG_DIR": "/tmp/claude", "CLAUDE_CODE_CUSTOM_OAUTH_URL": baseURL
                ]),
                files: fixture.files, keychain: FakeKeychain(), desktop: fixture.store, now: { now }
            )
            let http = FakeHTTPClient(response: HTTPResponse(statusCode: 401, headers: [:], body: Data()))
            let provider = ClaudeProvider(
                authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
                includeSharedUsage: false, now: { now }, pricing: { TestPricing.bundled }
            )

            let snapshot = await ProviderRefreshContext.$isManual.withValue(true) { await provider.refresh() }

            XCTAssertEqual(badge(snapshot.lines, "Error"), expectedError.localizedDescription)
            XCTAssertEqual(http.requests.count, expectedRequests)
            XCTAssertTrue(http.requests.allSatisfy { $0.headers["Authorization"] == "Bearer revoked-cli" })
            XCTAssertTrue(fixture.keyReader.calls.isEmpty)
        }
    }
}
