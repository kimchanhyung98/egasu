import XCTest

@testable import Egasu

@MainActor
final class ClaudeManagedRotationSwitchTests: XCTestCase {
    func testSharedRefreshCompletesBeforeSwitchSavesTheDepartingAccount() async throws {
        try await checkSwitchDuringRotation(rotateShared: true)
    }

    func testInactiveRefreshCompletesBeforeSwitchAppliesTheSavedAccount() async throws {
        try await checkSwitchDuringRotation(rotateShared: false)
    }

    func testFailedRefreshReleasesTheAccountSwitch() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/token") {
                await Self.switchWhileRefreshing(fixture)
                return HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"invalid_grant"}"#.utf8))
            }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: fixture.keychain,
                scope: .accountSnapshot(profileID: fixture.b.id)),
            usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
            pricing: { TestPricing.bundled })

        let result = await provider.refresh()
        XCTAssertNil(result.liveQuotaObservedAt)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/token") }.count, 1)
        try fixture.assertSavedAccountsUnchanged()
        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
    }

    private func checkSwitchDuringRotation(rotateShared: Bool) async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let account = rotateShared ? "a" : "b"
        let scope: ClaudeCredentialScope = rotateShared ? .standard : .accountSnapshot(profileID: fixture.b.id)
        let statePath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json").path
        let accountState = try XCTUnwrap(fixture.entryA.claudeOAuthAccount)
        let auth = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles([statePath: #"{"oauthAccount":\#(accountState)}"#]),
            keychain: fixture.keychain, scope: scope, allowsDesktopFallback: false, pinsSharedHome: rotateShared)
        let http = RoutingHTTPClient { request in
            if request.url.path.hasSuffix("/token") {
                await Self.switchWhileRefreshing(fixture)
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"access_token":"rotated-access-\#(account)","refresh_token":"rotated-refresh-\#(account)","expires_in":3600}"#
                            .utf8))
            }
            if request.headers["Authorization"] == "Bearer token-\(account)" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer rotated-access-\(account)")
            if request.url.path.hasSuffix("/profile") {
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"account":{"uuid":"acct-\#(account)"},"organization":{"uuid":"org-\#(account)"}}"#.utf8))
            }
            return HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(
                    #"{"five_hour":{"utilization":25,"resets_at":"2099-01-01T00:00:00Z"}}"#.utf8))
        }
        let provider = ClaudeProvider(
            authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
            usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            includeSharedUsage: false, pricing: { TestPricing.bundled })

        let result = await provider.refresh()
        XCTAssertNotNil(result.liveQuotaObservedAt)
        XCTAssertEqual(http.requests.filter { $0.url.path.hasSuffix("/token") }.count, 1)

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        let bLogin = try XCTUnwrap(fixture.switcher.readSharedAuthentication(family: "claude"))
        let bToken = ClaudeAuthStore.parseCredentials(bLogin.credential)?.claudeAiOauth?.refreshToken
        XCTAssertEqual(bToken, rotateShared ? "refresh-token-b" : "rotated-refresh-b")

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        let aLogin = try XCTUnwrap(fixture.switcher.readSharedAuthentication(family: "claude"))
        let aToken = ClaudeAuthStore.parseCredentials(aLogin.credential)?.claudeAiOauth?.refreshToken
        XCTAssertEqual(aToken, rotateShared ? "rotated-refresh-a" : "refresh-token-a")
    }

    private static func switchWhileRefreshing(_ fixture: AccountSwitchRecoveryFixture) async {
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            XCTFail("The account switched before OAuth returned")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .rotationInProgress)
        }
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertNoThrow(try fixture.assertSavedAccountsUnchanged())
    }
}
