import XCTest
@testable import Egasu

final class ClaudeSharedLoginCredentialTests: XCTestCase {
    private let home = FileManager.default.homeDirectoryForCurrentUser
    private let environment = FakeEnvironment(["SHELL": "/bin/zsh"])
    private let file = "~/.claude/.credentials.json"
    private let latest = #"{"claudeAiOauth":{"accessToken":"current-cli","refreshToken":"current-refresh"}}"#
    private let stale = #"{"claudeAiOauth":{"accessToken":"old-copy","refreshToken":"old-refresh"}}"#

    func testLegacyWrapperUsesItsCurrentUserLoginAndOwnIdentityBeforeAndAfterRegistration() throws {
        let otherHome = "/other-claude"
        let environment = FakeEnvironment([
            "SHELL": "/bin/zsh", "CLAUDE_CONFIG_DIR": otherHome, "CLAUDE_CODE_OAUTH_TOKEN": "ambient"
        ])
        let files = FakeFiles([
            home.appendingPathComponent(".zshrc").path: legacyClaudeZshBlock(home: home),
            home.appendingPathComponent(".claude/.claude.json").path: claudeUsageTestIdentity("active"),
            home.appendingPathComponent(".claude.json").path: claudeUsageTestIdentity("stale"),
            file: stale,
            otherHome + "/.claude.json": claudeUsageTestIdentity("other"),
            otherHome + "/.credentials.json": stale
        ])
        let base = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let scoped = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home.appendingPathComponent(".claude").path, environment: environment)
        for managed in [false, true] {
            let keychain = ServiceKeychain(values: [scoped: stale], currentUserValues: [base: stale, scoped: latest])
            let auth = ClaudeAuthStore(
                environment: environment, files: files, keychain: keychain, pinsSharedHome: managed)
            let observer = DefaultAccountObserver(
                environment: environment, files: files, keychain: keychain, pinsClaudeSharedHome: managed)
            guard case .resolved(let observed, _, _) = observer.observeClaude() else {
                return XCTFail("Expected wrapper identity")
            }
            XCTAssertEqual(observed, "active|test-org")
            let load = auth.loadCredentialSet()
            XCTAssertNil(load.credentialError)
            XCTAssertEqual(load.candidates.map(\.source), [.keychainCurrentUser(service: scoped)])
            var credential = try XCTUnwrap(load.candidates.first)
            XCTAssertEqual(credential.accountIdentityKey, "active|test-org")
            XCTAssertEqual(credential.sharedLoginRoute, .legacy(configDir: home.appendingPathComponent(".claude").path))
            XCTAssertEqual(credential.oauth.accessToken, "current-cli")
            credential.oauth.accessToken = "rotated"
            XCTAssertTrue(try auth.save(credential, ifUnchanged: ClaudeCredentialGeneration(load.candidates)))
            let saved = try XCTUnwrap(keychain.currentUserValues[scoped])
            XCTAssertEqual(ClaudeAuthStore.parseCredentials(saved)?.claudeAiOauth?.accessToken, "rotated")
            XCTAssertEqual(keychain.currentUserValues[base], stale)
            XCTAssertEqual(keychain.values[scoped], stale)
            XCTAssertEqual(files.files[file], stale)
            keychain.currentUserValues[scoped] = nil
            XCTAssertTrue(auth.loadCredentialSet().candidates.isEmpty)
        }
        let explicit = ClaudeAuthStore(
            environment: environment, files: files, keychain: ServiceKeychain(),
            scope: .configDir(path: otherHome, keychainLiteral: otherHome))
        let explicitLogin = try XCTUnwrap(explicit.loadCredentialSet().candidates.first)
        XCTAssertEqual(explicitLogin.accountIdentityKey, "other|test-org")
        XCTAssertEqual(explicitLogin.oauth.accessToken, "old-copy")
    }

    @MainActor
    func testWrapperUsesItsProjectHistoryWhenAnotherConfigDirectoryIsExported() async throws {
        let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        let stamp = EgasuISO8601.string(from: now)
        let userHome = try ClaudeLogFixture.makeUserHome(claudeFiles: [
            "wrapper.jsonl": ClaudeLogFixture.usageLine(timestamp: stamp, input: 15, costUSD: 0.25)
        ])
        defer { try? FileManager.default.removeItem(at: userHome) }
        let otherHome = try ClaudeLogFixture.makeHome(files: [
            "other.jsonl": ClaudeLogFixture.usageLine(
                timestamp: stamp, input: 30, costUSD: 5, messageID: "msg_other", requestID: "req_other")
        ])
        defer { try? FileManager.default.removeItem(at: otherHome) }
        let environment = FakeEnvironment(["SHELL": "/bin/zsh", "CLAUDE_CONFIG_DIR": otherHome.path])
        let files = FakeFiles([
            home.appendingPathComponent(".zshrc").path: legacyClaudeZshBlock(home: home),
            home.appendingPathComponent(".claude/.claude.json").path: claudeUsageTestIdentity("active")
        ])
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home.appendingPathComponent(".claude").path, environment: environment)
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: environment, files: files, keychain: ServiceKeychain(currentUserValues: [service: latest])),
            usageClient: ClaudeUsageClient(
                httpClient: RoutingHTTPClient { request in
                    XCTAssertEqual(request.headers["Authorization"], "Bearer current-cli")
                    let body =
                        request.url.path == "/api/oauth/profile"
                        ? #"{"account":{"uuid":"active"},"organization":{"uuid":"test-org"}}"#
                        : #"{"five_hour":{"utilization":10}}"#
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
                }),
            usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogUsageScanner(
                environment: environment, homeDirectory: { userHome }, incrementalScanner: IncrementalJSONLScanner()),
            includeSharedUsage: false, now: { now }, pricing: { TestPricing.bundled })
        let snapshot = await provider.refresh()
        guard case .values(_, let amounts, _, _, _, _) = snapshot.lines.first(where: { $0.label == "Today" }) else {
            return XCTFail("Missing daily spend")
        }
        XCTAssertEqual(
            amounts,
            [.init(number: 0.25, kind: .dollars, estimated: true), .init(number: 15, kind: .count, label: "tokens")])
    }

    @MainActor
    func testUnregisteredWrapperVerifiesTheInnerAccountBeforeAnyUsageRequest() async {
        let files = FakeFiles([
            home.appendingPathComponent(".zshrc").path: legacyClaudeZshBlock(home: home),
            home.appendingPathComponent(".claude/.claude.json").path: claudeUsageTestIdentity("work"),
            home.appendingPathComponent(".claude.json").path: claudeUsageTestIdentity("other")
        ])
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home.appendingPathComponent(".claude").path, environment: environment)
        let auth = ClaudeAuthStore(
            environment: environment, files: files, keychain: ServiceKeychain(currentUserValues: [service: latest]))
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer current-cli")
            return HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(
                    #"{"account":{"uuid":"other"},"organization":{"uuid":"test-org"}}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            includeSharedUsage: false, pricing: { TestPricing.bundled }
        )

        let snapshot = await provider.refresh()

        XCTAssertTrue(snapshot.lines.contains(where: \.isError))
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile"])
    }

    func testWrapperObserverIgnoresOtherKeychainAccountsWhenTheIdentityFileIsMissing() {
        let files = FakeFiles([
            home.appendingPathComponent(".zshrc").path: legacyClaudeZshBlock(home: home), file: stale
        ])
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home.appendingPathComponent(".claude").path, environment: environment)
        let keychain = ServiceKeychain(values: [service: stale])
        keychain.modificationDates[service] = Date()
        let observer = DefaultAccountObserver(
            environment: environment, files: files, keychain: keychain, pinsClaudeSharedHome: true)

        XCTAssertEqual(observer.observeClaude(), .absent)
        keychain.currentUserModificationDates[service] = Date()
        XCTAssertEqual(observer.observeClaude(), .unresolved(reason: "credentials present but no identity file"))
    }

    func testMalformedWrapperAndDeniedKeychainCannotSelectTheOldFile() {
        let profilePath = home.appendingPathComponent(".zshrc").path
        let files = FakeFiles([profilePath: ClaudeLegacyShellProfile.startMarker, file: stale])
        let auth = ClaudeAuthStore(
            environment: environment, files: files, keychain: DeniedClaudeSharedKeychain(), pinsSharedHome: true)
        XCTAssertTrue(auth.loadCredentialSet().credentialError is ClaudeSharedLoginRoute.UnrecognizedSetup)

        files.files.removeValue(forKey: profilePath)
        let denied = auth.loadCredentialSet()
        XCTAssertTrue(denied.credentialError is KeychainError)
        XCTAssertTrue(denied.candidates.isEmpty)
    }

    func testSharedLoginStaysReadableAfterClaudeCodeRewritesTheKeychainItem() {
        let files = FakeFiles([home.appendingPathComponent(".claude.json").path: claudeUsageTestIdentity("active")])
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let keychain = AppAccessRevokedKeychain(currentUserValues: [service: latest])
        let auth = ClaudeAuthStore(environment: environment, files: files, keychain: keychain, pinsSharedHome: true)

        for allowInteraction in [false, true] {
            let load = auth.loadCredentialSet(allowAccountInteraction: allowInteraction)
            XCTAssertNil(load.credentialError)
            XCTAssertEqual(load.candidates.map(\.source), [.keychainCurrentUser(service: service)])
            XCTAssertEqual(load.candidates.first?.oauth.accessToken, "current-cli")
        }
        XCTAssertEqual(keychain.appReads, 0, "CLI가 쓴 공유 항목은 앱 프로세스 승인 없이 조회")
    }
}

/// `security add-generic-password -U` 이후처럼 앱 프로세스의 Keychain 접근만 거부되는 상태.
private final class AppAccessRevokedKeychain: KeychainAccessing, @unchecked Sendable {
    private let currentUserValues: [String: String]
    private(set) var appReads = 0

    init(currentUserValues: [String: String]) {
        self.currentUserValues = currentUserValues
    }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        appReads += 1
        throw KeychainError.readFailed("Couldn't read the saved account from Keychain (status -25293).")
    }

    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        try readAppOwnedPassword(service: service, forCurrentUser: false, allowInteraction: allowInteraction)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? { currentUserValues[service] }
    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws { XCTFail("unexpected write") }
    func deleteGenericPassword(service: String) throws { XCTFail("unexpected delete") }
}

private struct DeniedClaudeSharedKeychain: KeychainAccessing {
    func readGenericPassword(service: String) throws -> String? { throw KeychainError.accessBusy }
    func writeGenericPassword(service: String, value: String) throws { XCTFail("unexpected write") }
    func deleteGenericPassword(service: String) throws { XCTFail("unexpected delete") }
}
