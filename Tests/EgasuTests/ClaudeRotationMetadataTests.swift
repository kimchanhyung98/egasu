import Foundation
import XCTest

@testable import Egasu

final class ClaudeRotationMetadataTests: XCTestCase {
    private let credential = """
        {"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","expiresAt":1,"extra":["active"]},
         "mcpOAuth":{"server":"mcp1"}}
        """

    @MainActor
    func testLosingProfileScopeDuringRefreshStopsRequestsAndPreservesLocalSpend() async throws {
        let now = Date(timeIntervalSince1970: 1_771_603_200)
        let home = try ClaudeLogFixture.makeHome(files: [
            "project/session.jsonl": ClaudeLogFixture.usageLine(
                timestamp: EgasuISO8601.string(from: now), input: 100, output: 50, costUSD: 0.25)
        ])
        let path = "/fixture/claude/.credentials.json"
        let rotation = """
            {"access_token":"fresh","refresh_token":"rotated","scope":"user:inference"}
            """
        let tokenPath = "/v1/oauth/token"
        let cases: [(expired: Bool, knownAccount: Bool, requests: [String])] = [
            (true, true, [tokenPath]),
            (false, true, ["/api/oauth/usage", tokenPath]),
            (false, false, ["/api/oauth/profile", tokenPath])
        ]
        for scenario in cases {
            let expiry = scenario.expired ? 1 : 4_102_444_800_000
            let credential = """
                {"claudeAiOauth":{"accessToken":"old","refreshToken":"refresh","expiresAt":\(expiry),
                 "subscriptionType":"pro","scopes":["user:profile","user:inference"]}}
                """
            let files = FakeFiles([path: credential])
            if scenario.knownAccount { files.files["/fixture/claude/.claude.json"] = claudeUsageTestIdentity() }
            let http = RoutingHTTPClient { request in
                if request.url.path == tokenPath {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(rotation.utf8))
                }
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            let runtime = ClaudeProvider(
                authStore: ClaudeAuthStore(
                    environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/fixture/claude"]), files: files,
                    keychain: FakeKeychain(), now: { now }),
                usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
                logUsageScanner: ClaudeLogFixture.scanner(home: home), includeSharedUsage: false,
                now: { now }, pricing: { TestPricing.bundled })

            let snapshot = await runtime.refresh()

            XCTAssertEqual(http.requests.map(\.url.path), scenario.requests)
            XCTAssertEqual(snapshot.warning, ClaudeUsageMapper.missingProfileScopeWarning)
            XCTAssertEqual(snapshot.authenticationIssue, .signInNeeded)
            XCTAssertNotNil(snapshot.line(label: "Today"))
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertTrue(runtime.usageTimerObservations.isEmpty)
            let saved = try XCTUnwrap(ClaudeAuthStore.parseCredentials(try files.readText(path))?.claudeAiOauth)
            XCTAssertEqual(saved.scopes, ["user:inference"])
            XCTAssertEqual(saved.refreshToken, "rotated")
        }
    }

    @MainActor
    func testFileFallbackAfterKeychainScopeLossVerifiesAccountBeforeSavingUsage() async throws {
        for useEnvironmentToken in [false, true] {
            for fileAccount in ["account-a", "account-b"] {
                let path = "/fixture/claude"
                var environment = ["CLAUDE_CONFIG_DIR": path]
                if useEnvironmentToken { environment["CLAUDE_CODE_OAUTH_TOKEN"] = "environment" }
                let files = FakeFiles([
                    "\(path)/.claude.json": claudeUsageTestIdentity("account-a"),
                    "\(path)/.credentials.json":
                        #"{"claudeAiOauth":{"accessToken":"file-token","scopes":["user:profile"]}}"#
                ])
                let keychain = ServiceKeychain()
                let auth = ClaudeAuthStore(
                    environment: FakeEnvironment(environment), files: files, keychain: keychain,
                    allowsDesktopFallback: false)
                let service = try XCTUnwrap(auth.keychainServiceCandidates().first)
                keychain.currentUserValues[service] = """
                    {"claudeAiOauth":{"accessToken":"cli","refreshToken":"refresh","expiresAt":1,"scopes":["user:profile"]}}
                    """
                let http = RoutingHTTPClient { request in
                    let body: String
                    switch request.url.path {
                    case "/v1/oauth/token":
                        body = #"{"access_token":"fresh","refresh_token":"rotated","scope":"user:inference"}"#
                    case "/api/oauth/profile":
                        XCTAssertEqual(request.headers["Authorization"], "Bearer file-token")
                        body = #"{"account":{"uuid":"\#(fileAccount)"},"organization":{"uuid":"test-org"}}"#
                    default:
                        XCTAssertEqual(request.headers["Authorization"], "Bearer file-token")
                        body = #"{"five_hour":{"utilization":42}}"#
                    }
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
                }
                let usageStore = isolatedClaudeUsageStore()
                let runtime = ClaudeProvider(
                    authStore: auth, usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: usageStore,
                    logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
                    pricing: { TestPricing.bundled })

                let snapshot = await runtime.refresh()

                let matches = fileAccount == "account-a"
                let expectedRequests = ["/v1/oauth/token", "/api/oauth/profile"] + (matches ? ["/api/oauth/usage"] : [])
                XCTAssertEqual(http.requests.map(\.url.path), expectedRequests)
                XCTAssertEqual(snapshot.line(label: "Session") != nil, matches)
                let lease = try await usageStore.acquire(accountKey: "account-a|test-org", usageURL: auth.oauthConfig().usageURL)
                XCTAssertEqual(try lease.read().lastGood != nil, matches)
            }
        }
    }

    func testRotationPreservesConcurrentMCPAndOAuthMetadataChanges() throws {
        let service = "Claude Code-credentials"
        let keychain = ServiceKeychain(currentUserValues: [service: credential])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, allowsDesktopFallback: false)
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "a2"
        updated.oauth.refreshToken = "r2"
        updated.oauth.expiresAt = 2
        keychain.currentUserValues[service] =
            credential
            .replacingOccurrences(of: "mcp1", with: "mcp2")
            .replacingOccurrences(of: "active", with: "changed")

        XCTAssertTrue(try store.save(updated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let value = try XCTUnwrap(keychain.currentUserValues[service])
        let saved = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(value))
        XCTAssertEqual(saved["mcpOAuth"] as? [String: String], ["server": "mcp2"])
        let oauth = try XCTUnwrap(saved["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["extra"] as? [String], ["changed"])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(value)?.claudeAiOauth, updated.oauth)
    }

    func testHexFileRotationKeepsExtendedFieldsAndOtherScopesIntact() throws {
        let directory = "/fixture/claude"
        let path = directory + "/.credentials.json"
        let files = FakeFiles([path: "0x" + credential.utf8.map { String(format: "%02x", $0) }.joined()])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": "other account"])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: files, keychain: keychain,
            scope: .configDir(path: directory, keychainLiteral: directory))
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "a2"

        XCTAssertTrue(try store.save(updated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let saved = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(try files.readText(path)))
        XCTAssertEqual(saved["mcpOAuth"] as? [String: String], ["server": "mcp1"])
        let oauth = try XCTUnwrap(saved["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["extra"] as? [String], ["active"])
        XCTAssertEqual(oauth["refreshToken"] as? String, "r1")
        XCTAssertEqual(keychain.currentUserValues, ["Claude Code-credentials": "other account"])
    }

    func testRefreshWaitsForAccountReplacementAndRejectsThePreviousGeneration() throws {
        let profile = AccountProfile(
            id: UUID().uuidString, family: "claude", label: "Test", identityKey: "account|org", createdAt: .distantPast)
        let keychain = ServiceKeychain()
        let vault = AccountCredentialVault(keychain: keychain)
        let original = AccountCredentialVault.Entry(credential: credential, claudeOAuthAccount: nil)
        let replacement = AccountCredentialVault.Entry(
            credential: credential.replacingOccurrences(of: "a1", with: "new-login"), claudeOAuthAccount: nil)
        try vault.save(original, profile: profile)
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id))
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "old-account-rotation"
        let rotation = updated
        let generation = ClaudeCredentialGeneration(candidates)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        do {
            AccountCredentialMutationLock.acquire(family: "claude")
            defer { AccountCredentialMutationLock.release(family: "claude") }
            DispatchQueue.global().async(group: finished) {
                started.signal()
                do {
                    let applied = try store.save(rotation, ifUnchanged: generation)
                    XCTAssertFalse(applied)
                } catch {
                    XCTFail("Unexpected rotation failure: \(error)")
                }
            }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.2), .timedOut)
            try vault.save(replacement, profile: profile)
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try vault.load(profile: profile), replacement)
    }

    func testSnapshotRotationPreservesAccountIdentityAndCredentialExtensions() throws {
        let profileID = UUID().uuidString
        let service = AccountCredentialVault.service(family: "claude", profileID: profileID)
        let account = #"{"accountUuid":"a","organizationUuid":"org"}"#
        let entry = AccountCredentialVault.Entry(credential: credential, claudeOAuthAccount: account)
        let keychain = ServiceKeychain(currentUserValues: [
            service: String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profileID))
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "a2"

        XCTAssertTrue(try store.save(updated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let saved = try XCTUnwrap(
            AccountCredentialVault(keychain: keychain).load(family: "claude", profileID: profileID))
        XCTAssertEqual(saved.claudeOAuthAccount, account)
        let document = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(saved.credential))
        XCTAssertEqual(document["mcpOAuth"] as? [String: String], ["server": "mcp1"])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(saved.credential)?.claudeAiOauth, updated.oauth)
        XCTAssertEqual(Set(keychain.currentUserValues.keys), [service])
    }
}
