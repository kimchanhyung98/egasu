import XCTest
@testable import Egasu

final class ClaudeScopedAuthStoreTests: XCTestCase {
    private let scope = ClaudeCredentialScope.configDir(
        path: "/Users/dev/.claude-work",
        keychainLiteral: "~/.claude-work"
    )

    func testScopedStoreReadsOnlyItsOwnCredentialSources() throws {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([
                // 타 account의 default-home 파일은 scoped card에 비가시
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "default-at"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        XCTAssertEqual(store.keychainServiceCandidates(), [scopedService], "never the bare default service")
        let load = store.loadCredentialSet()
        XCTAssertEqual(load.candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertEqual(load.desktopStatus, .notChecked, "a config-dir card never consults Desktop")
    }

    func testPinnedStandardStoreIgnoresAnAmbientConfigDirOverride() {
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
        let pinned = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/Users/dev/.claude-work"]),
            files: FakeFiles([
                "~/.claude/.credentials.json": #"{"claudeAiOauth": {"accessToken": "shared-file-at"}}"#,
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "other-at"}}"#,
            ]),
            keychain: ServiceKeychain(currentUserValues: [
                baseService: #"{"claudeAiOauth":{"accessToken":"shared-at"}}"#
            ]),
            pinsSharedHome: true
        )

        XCTAssertNil(pinned.claudeHomeOverride())
        XCTAssertEqual(pinned.keychainServiceCandidates(), [baseService])
        XCTAssertEqual(
            pinned.loadCredentialSet().candidates.map(\.oauth.accessToken), ["shared-at"],
            "the managed card uses the active Keychain item even if a credential file remains")
    }

    @MainActor
    func testPinnedProviderUsesTheCurrentSharedCLILoginInsteadOfExpiredCopies() async {
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/unrelated-claude"])
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sharedHome = home.appendingPathComponent(".claude").path
        let sharedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome, environment: environment
        )
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let current =
            #"{"claudeAiOauth":{"accessToken":"current-login","refreshToken":"current-refresh","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        let expired =
            #"{"claudeAiOauth":{"accessToken":"expired-login","refreshToken":"expired-refresh","expiresAt":1,"scopes":["user:profile"]}}"#
        let files = FakeFiles([
            home.appendingPathComponent(".claude.json").path: claudeUsageTestIdentity(),
            sharedHome + "/.claude.json":
                #"{"oauthAccount":{"accountUuid":"old-account","organizationUuid":"old-org"}}"#,
            "~/.claude/.credentials.json": expired
        ])
        let keychain = ServiceKeychain(
            values: [sharedService: expired], currentUserValues: [sharedService: expired, baseService: current])
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer current-login" else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url.path == "/api/oauth/profile" {
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"account":{"uuid":"account-a"},"organization":{"uuid":"test-org"}}"#.utf8
                    ))
            }
            guard request.url.path == "/api/oauth/usage" else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: environment, files: files, keychain: keychain, pinsSharedHome: true
            ),
            usageClient: ClaudeUsageClient(httpClient: http),
            usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            includeSharedUsage: false,
            pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("the selected account must expose its current CLI session usage")
        }
        XCTAssertEqual(used, 25)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        XCTAssertFalse(http.requests.contains { $0.url.path.hasSuffix("/token") })
        XCTAssertEqual(keychain.currentUserValues[sharedService], expired)
        XCTAssertEqual(keychain.currentUserValues[baseService], current)
        XCTAssertEqual(files.files["~/.claude/.credentials.json"], expired)
    }

    func testPinnedTokenRotationUpdatesOnlyTheDefaultCLICredential() throws {
        let environment = FakeEnvironment([:])
        let sharedHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let sharedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome, environment: environment
        )
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let current = #"{"claudeAiOauth":{"accessToken":"current-login","refreshToken":"current-refresh"}}"#
        let expired = #"{"claudeAiOauth":{"accessToken":"expired-login"}}"#
        let keychain = ServiceKeychain(currentUserValues: [sharedService: expired, baseService: current])
        let store = ClaudeAuthStore(
            environment: environment, files: FakeFiles([:]), keychain: keychain, pinsSharedHome: true
        )
        let candidates = store.loadCredentialSet().candidates
        var rotated = try XCTUnwrap(candidates.first)
        rotated.oauth.accessToken = "rotated-login"

        XCTAssertTrue(try store.save(rotated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let saved = try XCTUnwrap(keychain.currentUserValues[baseService])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(saved)?.claudeAiOauth?.accessToken, "rotated-login")
        XCTAssertEqual(keychain.currentUserValues[sharedService], expired)
    }

    func testPinnedStoreDoesNotRestoreScopedCredentialsAfterDefaultLogout() {
        let environment = FakeEnvironment([:])
        let sharedHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        let sharedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome, environment: environment
        )
        let credential = #"{"claudeAiOauth":{"accessToken":"stale-login","scopes":["user:profile"]}}"#
        let store = ClaudeAuthStore(
            environment: environment,
            files: FakeFiles([:]),
            keychain: ServiceKeychain(currentUserValues: [sharedService: credential]),
            allowsDesktopFallback: false, pinsSharedHome: true
        )

        XCTAssertTrue(store.loadCredentialSet().candidates.isEmpty)
    }

    @MainActor
    func testPinnedProviderSupportsDefaultFileCredentialsWithoutBaseKeychain() async {
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/unrelated-claude"])
        let home = FileManager.default.homeDirectoryForCurrentUser
        let sharedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home.appendingPathComponent(".claude").path, environment: environment
        )
        let files = FakeFiles([
            "~/.claude/.credentials.json":
                #"{"claudeAiOauth":{"accessToken":"default-file-login","expiresAt":4102444800000,"scopes":["user:profile"]}}"#,
            home.appendingPathComponent(".claude.json").path: claudeUsageTestIdentity()
        ])
        let keychain = ServiceKeychain(currentUserValues: [
            sharedService: #"{"claudeAiOauth":{"accessToken":"old-scoped-login"}}"#
        ])
        let auth = ClaudeAuthStore(
            environment: environment, files: files, keychain: keychain,
            allowsDesktopFallback: false, pinsSharedHome: true
        )
        let http = RoutingHTTPClient { request in
            guard request.headers["Authorization"] == "Bearer default-file-login"
            else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url.path == "/api/oauth/profile" {
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"account":{"uuid":"account-a"},"organization":{"uuid":"test-org"}}"#.utf8
                    ))
            }
            guard request.url.path == "/api/oauth/usage" else {
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(#"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00.000Z"}}"#.utf8)
            )
        }
        let provider = ClaudeProvider(
            authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            includeSharedUsage: false, pricing: { TestPricing.bundled }
        )

        let candidates = auth.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.source), [.file])
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["default-file-login"])
        let snapshot = await provider.refresh()

        guard case .progress(_, let used, _, _, _, _, _) = snapshot.line(label: "Session") else {
            return XCTFail("Default file authentication must expose session usage")
        }
        XCTAssertEqual(used, 25)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
    }

    func testScopedStoreNeverInheritsTheAmbientEnvironmentToken() {
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(["CLAUDE_CODE_OAUTH_TOKEN": "ambient-token"]),
            files: FakeFiles([
                "/Users/dev/.claude-work/.credentials.json": #"{"claudeAiOauth": {"accessToken": "work-at"}}"#,
            ]),
            keychain: ServiceKeychain(),
            scope: scope
        )

        let candidates = store.loadCredentialSet().candidates
        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["work-at"])
        XCTAssertFalse(candidates.contains { $0.source == .environment })
    }

    func testFootprintProbeSeesFileAndKeychainShapesWithoutReadingSecrets() {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "~/.claude-work", environment: FakeEnvironment([:])
        )
        let fileBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles(["/Users/dev/.claude-work/.credentials.json": "{}"]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertTrue(fileBacked.hasCredentialFootprint())

        let keychainBacked = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(values: [scopedService: "present"]),
            scope: scope
        )
        XCTAssertTrue(keychainBacked.hasCredentialFootprint())

        let bare = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            scope: scope
        )
        XCTAssertFalse(bare.hasCredentialFootprint())
    }

    func testStandardStoreDropsDesktopFallbackWhileExtraCardsExist() {
        // CLI login 없음 + Desktop 불허(추가 Claude card 존재) → Desktop 조회 없이 `.notFound` 보고
        let store = ClaudeAuthStore(
            environment: FakeEnvironment([:]),
            files: FakeFiles([:]),
            keychain: ServiceKeychain(),
            allowsDesktopFallback: false
        )

        let load = store.loadCredentialSet(forceDesktopFallback: true)
        XCTAssertEqual(load.desktopStatus, .notFound)
        XCTAssertTrue(load.candidates.isEmpty)
    }

    func testDefaultKeychainCannotBorrowAnOverrideHomesIdentity() {
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude-work"])
        let baseService = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let files = FakeFiles([
            "/tmp/claude-work/.claude.json": claudeUsageTestIdentity("work-account"),
            "/tmp/claude-work/.credentials.json": #"{"claudeAiOauth":{"accessToken":"work-token"}}"#,
            FileManager.default.homeDirectoryForCurrentUser.path + "/.claude.json": claudeUsageTestIdentity("personal-account")
        ])
        let keychain = ServiceKeychain(values: [baseService: #"{"claudeAiOauth":{"accessToken":"personal-token"}}"#])
        let store = ClaudeAuthStore(environment: environment, files: files, keychain: keychain)

        let candidates = store.loadCredentialSet().candidates

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["work-token"])
        XCTAssertEqual(candidates.first?.accountIdentityKey, "work-account|test-org")
    }

    func testHomeIdentityIsNotCopiedToAnUnverifiedFallbackCredential() {
        let environment = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude-work"])
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: "/tmp/claude-work", environment: environment
        )
        let files = FakeFiles([
            "/tmp/claude-work/.claude.json": claudeUsageTestIdentity("primary-account"),
            "/tmp/claude-work/.credentials.json": #"{"claudeAiOauth":{"accessToken":"other-token"}}"#
        ])
        let keychain = ServiceKeychain(values: [service: #"{"claudeAiOauth":{"accessToken":"primary-token"}}"#])
        let candidates = ClaudeAuthStore(environment: environment, files: files, keychain: keychain)
            .loadCredentialSet().candidates

        XCTAssertEqual(candidates.map(\.oauth.accessToken), ["primary-token", "other-token"])
        XCTAssertEqual(candidates.first?.accountIdentityKey, "primary-account|test-org")
        XCTAssertNil(candidates.last?.accountIdentityKey)
    }
}
