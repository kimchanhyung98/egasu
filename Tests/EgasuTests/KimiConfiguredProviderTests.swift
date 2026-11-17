import Foundation
import os
import XCTest
@testable import Egasu

@MainActor
final class KimiConfiguredProviderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000)
    private let globalSlot = "kimi-code-env-0e4f99c69cc27850"

    func testGlobalOAuthUsesConfiguredServerAndScopedCredential() async throws {
        let fixture = try fixture(domain: "ai")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let before = fixture.files.files
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url.absoluteString, "https://api.kimi.ai/coding/v1/usages")
            XCTAssertEqual(request.headers["Authorization"], "Bearer scoped-token")
            return Self.usageResponse
        }
        let provider = provider(fixture, http: http)

        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()

        XCTAssertTrue(detected)
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(fixture.files.files, before)
    }

    func testGlobalRefreshWritesOnlyItsSlotAndUsesGlobalOAuthHost() async throws {
        let fixture = try fixture(domain: "ai", expiresAt: 2_060)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let standardPath = fixture.home.appendingPathComponent("credentials/kimi-code.json").path
        fixture.files.files[standardPath] = Self.credential("other-region", expiresAt: 9_000)
        let originalStandard = fixture.files.files[standardPath]
        let http = RoutingHTTPClient { request in
            if request.method == "POST" {
                XCTAssertEqual(request.url.absoluteString, "https://auth.kimi.ai/api/oauth/token")
                XCTAssertTrue(
                    FileManager.default.fileExists(
                        atPath: fixture.home.appendingPathComponent("oauth/kimi-code-env-0e4f99c69cc27850.lock").path
                ))
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8
                ))
            }
            XCTAssertEqual(request.url.absoluteString, "https://api.kimi.ai/coding/v1/usages")
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated")
            return Self.usageResponse
        }

        let snapshot = await provider(fixture, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.method), ["POST", "GET"])
        XCTAssertEqual(fixture.files.files[standardPath], originalStandard)
        let saved = try XCTUnwrap(fixture.files.files[fixture.credential.path])
        XCTAssertEqual(ProviderParse.jsonObject(Data(saved.utf8))?["access_token"] as? String, "rotated")
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent("oauth/\(globalSlot).lock").path
        ))
    }

    func testCodeAPIKeyUsesEachConfiguredServerWithoutRefreshingOrWriting() async throws {
        for domain in ["com", "ai"] {
            let fixture = try fixture(domain: domain, apiKey: "test-code-key")
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            let before = fixture.files.files
            let http = RoutingHTTPClient { request in
                XCTAssertEqual(request.url.absoluteString, "https://api.kimi.\(domain)/coding/v1/usages")
                XCTAssertEqual(request.headers["Authorization"], "Bearer test-code-key")
                return Self.usageResponse
            }
            let provider = provider(fixture, http: http)

            let detected = await provider.hasLocalCredentials()
            let snapshot = await provider.refresh()

            XCTAssertTrue(detected)
            XCTAssertTrue(provider.usageTimerObservations.isEmpty)
            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(http.requests.map(\.method), ["GET"])
            XCTAssertEqual(fixture.files.files, before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent("oauth").path))
        }
    }

    func testRejectedAPIKeyDoesNotAttemptOAuthRefresh() async throws {
        let fixture = try fixture(domain: "ai", apiKey: "test-rejected-key")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let before = fixture.files.files
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }

        let snapshot = await provider(fixture, http: http).refresh()

        XCTAssertEqual(http.requests.map(\.method), ["GET"])
        XCTAssertEqual(snapshot.errorCategory, .authInvalid)
        XCTAssertEqual(
            snapshot.lines.first,
            .badge(
                label: MetricLine.errorBadgeLabel,
                text: "Kimi API key was rejected. Check the CLI provider settings.", colorHex: "#EF4444"
        ))
        XCTAssertEqual(fixture.files.files, before)
    }

    func testMissingConfiguredAPIKeyIsAnExpectedAuthenticationFailure() async throws {
        for declaration in ["api_key = \"\"", "api_key_env = \"MISSING_KIMI_KEY\""] {
            let fixture = try fixture(domain: "ai", apiKey: "")
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            let path = fixture.home.appendingPathComponent("config.toml").path
            fixture.files.files[path] = fixture.files.files[path]?
                .replacingOccurrences(of: "api_key = \"\"", with: declaration)
            let before = fixture.files.files
            let http = RoutingHTTPClient { _ in
                XCTFail("Missing configured keys must not use another credential")
                return Self.usageResponse
            }
            let provider = provider(fixture, http: http)
            let detected = await provider.hasLocalCredentials()
            let snapshot = await provider.refresh()

            XCTAssertFalse(detected)
            XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
            XCTAssertEqual(
                snapshot.lines.first,
                .badge(
                    label: MetricLine.errorBadgeLabel,
                    text: "Kimi API key is missing. Check the CLI provider settings.", colorHex: "#EF4444"
                )
            )
            XCTAssertTrue(http.requests.isEmpty)
            XCTAssertEqual(fixture.files.files, before)
        }
        XCTAssertEqual(KimiAuthError.configurationInvalid.errorCategory, .authInvalid)
        XCTAssertEqual(KimiAuthError.apiKeyRejected.errorCategory, .authInvalid)
    }

    func testAnthropicCodeAPIKeyUsesCanonicalUsageEndpoint() async throws {
        for domain in ["com", "ai"] {
            let fixture = try fixture(domain: domain, apiKey: "anthropic-code-key")
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            let path = fixture.home.appendingPathComponent("config.toml").path
            fixture.files.files[path] = fixture.files.files[path]?
                .replacingOccurrences(of: "type = \"kimi\"", with: "type = \"anthropic\"")
                .replacingOccurrences(of: "/coding/v1\"", with: "/coding/\"")
            let http = RoutingHTTPClient { request in
                XCTAssertEqual(request.url.absoluteString, "https://api.kimi.\(domain)/coding/v1/usages")
                XCTAssertEqual(request.headers["Authorization"], "Bearer anthropic-code-key")
                return Self.usageResponse
            }

            let snapshot = await provider(fixture, http: http).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(http.requests.count, 1)
        }
    }

    func testUnauthorizedGlobalOAuthRetriesOnlyItsOwnServer() async throws {
        let fixture = try fixture(domain: "ai")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let http = RoutingHTTPClient { request in
            if request.method == "POST" {
                XCTAssertEqual(request.url.absoluteString, "https://auth.kimi.ai/api/oauth/token")
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"access_token":"rotated","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8
                ))
            }
            XCTAssertEqual(request.url.absoluteString, "https://api.kimi.ai/coding/v1/usages")
            return request.headers["Authorization"] == "Bearer rotated"
                ? Self.usageResponse : HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let snapshot = await provider(fixture, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST", "GET"])
    }

    func testConfigurationChangeBeforeLockedReloadStopsRefresh() async throws {
        let fixture = try fixture(domain: "ai", expiresAt: 2_060)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let files = SwitchingConfigurationFiles(base: fixture.files)
        let http = RoutingHTTPClient { _ in
            XCTFail("Changed authentication must not refresh the original account")
            return Self.usageResponse
        }
        let now = now
        let provider = KimiProvider(
            authStore: KimiAuthStore(files: files, environment: FakeEnvironment(["KIMI_CODE_HOME": fixture.home.path])),
            usageClient: KimiUsageClient(http: http, now: { now }), now: { now }, pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(fixture.files.files[fixture.credential.path], Self.credential("scoped-token", expiresAt: 2_060))
    }

    func testUsageTimerRetainsGlobalServerAndDoesNotWriteTokenToConfig() async throws {
        let fixture = try fixture(domain: "ai", token: Self.jwt)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let http = RoutingHTTPClient { _ in Self.usageResponse }
        let provider = provider(fixture, http: http)
        _ = await provider.quotaSnapshot()
        let observation = try XCTUnwrap(provider.usageTimerObservations.first)
        let cli = ConfigCaptureCLI()
        let session = try await provider.prepareUsageTimer(
            observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli)
        )

        _ = await session?.send { true }

        let config = try XCTUnwrap(cli.config)
        XCTAssertTrue(config.contains("https://api.kimi.ai/coding/v1"))
        XCTAssertFalse(config.contains(Self.jwt))
        XCTAssertEqual(cli.request?.environment["EGASU_KIMI_TOKEN"], Self.jwt)
    }

    func testIdenticalSubjectsOnDifferentServersHaveDifferentTimerAccounts() async throws {
        var keys: [String] = []
        for domain in ["com", "ai"] {
            let fixture = try fixture(domain: domain, token: Self.jwt)
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            let provider = provider(fixture, http: RoutingHTTPClient { _ in Self.usageResponse })
            _ = await provider.quotaSnapshot()
            keys.append(try XCTUnwrap(provider.usageTimerObservations.first?.accountKey))
        }
        XCTAssertNotEqual(keys[0], keys[1])
    }

    func testValidLegacyOAuthRetainsUsageTimerObservation() async throws {
        let fixture = try fixture(domain: "com")
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let files = FakeFiles([
            fixture.home.appendingPathComponent(".kimi/credentials/kimi-code.json").path:
                Self.credential(Self.jwt, expiresAt: 9_000)
        ])
        let now = now
        let provider = KimiProvider(
            authStore: KimiAuthStore(files: files, environment: FakeEnvironment(), homeDirectory: { fixture.home }),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { _ in Self.usageResponse }),
            now: { now }, pricing: { .empty }
        )

        let snapshot = await provider.quotaSnapshot()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(provider.usageTimerObservations.count, 1)
    }

    func testTimerCanLaunchAfterCredentialsRotateDuringPreparation() async throws {
        let fixture = try fixture(domain: "ai", token: Self.jwt)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let rotated = Self.jwt + "-rotated"
        let http = RoutingHTTPClient { request in
            if request.method == "POST" {
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                    #"{"access_token":"\#(rotated)","refresh_token":"rotated-refresh","expires_in":3600}"#.utf8
                ))
            }
            return Self.usageResponse
        }
        let provider = provider(fixture, http: http)
        _ = await provider.quotaSnapshot()
        let observation = try XCTUnwrap(provider.usageTimerObservations.first)
        fixture.files.files[fixture.credential.path] = Self.credential(Self.jwt, expiresAt: 2_060)
        let cli = ConfigCaptureCLI()

        let session = try await provider.prepareUsageTimer(
            observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli)
        )
        _ = await session?.send { true }

        XCTAssertNotNil(cli.config)
        XCTAssertEqual(cli.request?.environment["EGASU_KIMI_TOKEN"], rotated)
    }

    func testChangingConfiguredServerAfterPreparationBlocksTimer() async throws {
        let fixture = try fixture(domain: "ai", token: Self.jwt)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        let provider = provider(fixture, http: RoutingHTTPClient { _ in Self.usageResponse })
        _ = await provider.quotaSnapshot()
        let observation = try XCTUnwrap(provider.usageTimerObservations.first)
        let cli = ConfigCaptureCLI()
        let session = try await provider.prepareUsageTimer(
            observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli)
        )
        let configPath = fixture.home.appendingPathComponent("config.toml").path
        fixture.files.files[configPath] = fixture.files.files[configPath]?.replacingOccurrences(of: ".kimi.ai", with: ".kimi.com")
        fixture.files.files[fixture.home.appendingPathComponent("credentials/kimi-code.json").path]
            = Self.credential(Self.jwt, expiresAt: 9_000)

        _ = await session?.send { true }

        XCTAssertNil(cli.config)
        XCTAssertNil(cli.request)
    }

    func testTimerAcceptsMissingOrZeroExpiryAndRequiresFiniteExpiryBuffer() async throws {
        for expiry in [nil, 0, 2_090, 2_121] as [Double?] {
            let fixture = try fixture(domain: "ai", token: Self.jwt)
            defer { try? FileManager.default.removeItem(at: fixture.home) }
            var body: [String: Any] = ["access_token": Self.jwt]
            if let expiry { body["expires_at"] = expiry }
            fixture.files.files[fixture.credential.path] = String(
                decoding: try JSONSerialization.data(withJSONObject: body), as: UTF8.self)
            let provider = provider(fixture, http: RoutingHTTPClient { _ in Self.usageResponse })
            _ = await provider.quotaSnapshot()
            let observation = try XCTUnwrap(provider.usageTimerObservations.first)
            let cli = ConfigCaptureCLI()
            do {
                let prepared = try await provider.prepareUsageTimer(
                    observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli))
                let session = try XCTUnwrap(prepared)
                _ = await session.send { true }
                XCTAssertNotNil(cli.request)
                XCTAssertNotEqual(expiry, 2_090)
            } catch {
                XCTAssertEqual(expiry, 2_090)
                XCTAssertNil(cli.request)
            }
        }
    }

    func testQueuedTimerRechecksRemainingTokenLifetimeBeforeLaunch() async throws {
        let fixture = try fixture(domain: "ai", token: Self.jwt, expiresAt: 2_121)
        defer { try? FileManager.default.removeItem(at: fixture.home) }
        fixture.files.files[fixture.credential.path] = fixture.files.files[fixture.credential.path]?
            .replacingOccurrences(of: #","refresh_token":"test-refresh""#, with: "")
        let clock = OSAllocatedUnfairLock(initialState: now)
        let provider = KimiProvider(
            authStore: KimiAuthStore(files: fixture.files, environment: FakeEnvironment(["KIMI_CODE_HOME": fixture.home.path])),
            usageClient: KimiUsageClient(http: RoutingHTTPClient { _ in Self.usageResponse }, now: { clock.withLock { $0 } }),
            now: { clock.withLock { $0 } }, pricing: { .empty })
        _ = await provider.quotaSnapshot()
        let observation = try XCTUnwrap(provider.usageTimerObservations.first)
        let cli = ConfigCaptureCLI()
        let prepared = try await provider.prepareUsageTimer(
            observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli))
        let session = try XCTUnwrap(prepared)
        clock.withLock { $0.addTimeInterval(122) }

        let result = await session.send { true }

        XCTAssertFalse(result.launched)
        XCTAssertNil(cli.request)
    }

    private func fixture(
        domain: String, token: String = "scoped-token", expiresAt: Double = 9_000, apiKey: String? = nil
    ) throws -> Fixture {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-config-test-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let slot = domain == "com" ? "kimi-code" : globalSlot
        let credential = home.appendingPathComponent("credentials/\(slot).json")
        var config = """
        [providers."managed:kimi-code"]
        type = "kimi"
        base_url = "https://api.kimi.\(domain)/coding/v1"
        """
        if let apiKey {
            config += "\napi_key = \"\(apiKey)\"\n"
        } else {
            config += """

            [providers."managed:kimi-code".oauth]
            storage = "file"
            key = "oauth/\(slot)"
            oauth_host = "https://auth.kimi.\(domain)"
            """
        }
        return Fixture(
            home: home, credential: credential,
            files: FakeFiles([
                home.appendingPathComponent("config.toml").path: config,
                credential.path: Self.credential(token, expiresAt: expiresAt)
        ]))
    }

    private func provider(_ fixture: Fixture, http: any HTTPClient) -> KimiProvider {
        let now = now
        return KimiProvider(
            authStore: KimiAuthStore(
                files: fixture.files,
                environment: FakeEnvironment(["KIMI_CODE_HOME": fixture.home.path])),
            usageClient: KimiUsageClient(http: http, now: { now }), now: { now }, pricing: { .empty }
        )
    }

    private static func credential(_ token: String, expiresAt: Double) -> String {
        #"{"access_token":"\#(token)","refresh_token":"test-refresh","expires_at":\#(expiresAt),"expires_in":3600}"#
    }

    private static let jwt = "e30." + Data(#"{"sub":"same-subject"}"#.utf8).base64EncodedString() + ".signature"
    private nonisolated static let usageResponse = HTTPResponse(
        statusCode: 200, headers: [:],
        body: Data(
            #"""
    {"usages":{"limit_5h":{"used_ratio":0,"reset_time":"2099-01-01T00:00:00Z"},"limit_7d":{"used_ratio":0.2}}}
    """#.utf8))

    private struct Fixture: Sendable {
        var home: URL
        var credential: URL
        var files: FakeFiles
    }

    private final class SwitchingConfigurationFiles: TextFileAccessing, @unchecked Sendable {
        let base: FakeFiles
        var configurationReads = 0

        init(base: FakeFiles) { self.base = base }
        func exists(_ path: String) -> Bool { base.exists(path) }
        func readText(_ path: String) throws -> String {
            if path.hasSuffix("/config.toml") {
                configurationReads += 1
                if configurationReads > 1 {
                    return """
                    [providers."managed:kimi-code"]
                    base_url = "https://api.kimi.com/coding/v1"
                    api_key = "new-account-key"
                    """
                }
            }
            return try base.readText(path)
        }
        func writeText(_ path: String, _ text: String) throws { try base.writeText(path, text) }
        func remove(_ path: String) throws { try base.remove(path) }
    }

    private final class ConfigCaptureCLI: UsageTimerCLIExecuting {
        var config: String?
        var request: StreamingProcessRequest?

        func execute(
            _ configuration: UsageTimerCLIConfiguration, canLaunch: @escaping @MainActor () async -> Bool
        ) async -> UsageTimerExecutionResult {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-timer-test-\(UUID())")
            defer { try? FileManager.default.removeItem(at: directory) }
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                guard await canLaunch() else { return .init(launched: false, completed: false) }
                request = try UsageTimerCLIExecutor().makeRequest(
                    configuration, executable: URL(fileURLWithPath: "/test/kimi"), directory: directory
                )
                config = try String(contentsOf: directory.appendingPathComponent("config.toml"), encoding: .utf8)
                return .init(launched: false, completed: false)
            } catch {
                XCTFail("Unexpected timer setup error: \(error)")
                return .init(launched: false, completed: false)
            }
        }
    }
}
