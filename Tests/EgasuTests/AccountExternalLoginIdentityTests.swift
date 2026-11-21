import XCTest
@testable import Egasu

@MainActor
final class AccountExternalLoginIdentityTests: XCTestCase {
    func testUnchangedCredentialDoesNotTrustSavedOrganizationForAccountOnlyMetadata() async throws {
        for status in [200, 500] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let other = try fixture.store.add(
                family: "claude", label: "Other Organization", identityKey: "acct-a|other-org", id: "other-org"
            )
            let previousOther = AccountCredentialVault.Entry(
                credential: AccountSwitchRecoveryFixture.entry("a", token: "saved-other").credential,
                claudeOAuthAccount: #"{"accountUuid":"acct-a","organizationUuid":"other-org"}"#
            )
            try fixture.switcher.saveSnapshot(previousOther, for: other)
            try fixture.switcher.writeWorkspaceAuthentication(previousOther, for: other)
            try Data(#"{"oauthAccount":{"accountUuid":"acct-a"}}"#.utf8)
                .write(to: fixture.root.appendingPathComponent(".claude.json"))
            let before = try fixture.switcher.readClaudeSwitchState()
            let registry = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)
            let writes = fixture.keychain.writeCount
            let http = ClaudeReconciliationHTTPClient()
            http.identities["token-a"] = other.identityKey
            if status != 200 {
                http.response = HTTPResponse(statusCode: status, headers: [:], body: Data())
            }
            let importer = AccountCredentialImporter(
                keychain: fixture.keychain, environment: FakeEnvironment(),
                homeDirectory: fixture.root, workspace: fixture.workspace, httpClient: http
            )

            let result = await claudeReconciliationResult(importer, in: fixture.store)

            XCTAssertEqual(http.requests.count, 1)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
            try fixture.assertSavedAccountsUnchanged()
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
            if status == 200 {
                XCTAssertEqual(try result.get(), .updated(profileID: other.id))
                XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), other.id)
                let snapshot = try XCTUnwrap(fixture.switcher.loadSnapshot(for: other))
                XCTAssertEqual(snapshot.credential, fixture.entryA.credential)
                XCTAssertEqual(
                    fixture.switcher.identity(of: snapshot, family: "claude")?.identityKey, other.identityKey)
                let home = try fixture.workspace.directory(family: "claude", profileID: other.id).path
                XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), snapshot)
            } else {
                XCTAssertThrowsError(try result.get()) {
                    XCTAssertEqual($0 as? ClaudeUsageError, .requestFailed(status))
                }
                XCTAssertEqual(fixture.keychain.writeCount, writes)
                XCTAssertEqual(fixture.defaults.data(forKey: AccountProfilesStore.storageKey), registry)
                XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
                XCTAssertEqual(fixture.store.authenticationRevision, 0)
                XCTAssertEqual(try fixture.switcher.loadSnapshot(for: other), previousOther)
                let home = try fixture.workspace.directory(family: "claude", profileID: other.id).path
                XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), previousOther)
            }
        }
    }
}
