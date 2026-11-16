import XCTest
@testable import Egasu

@MainActor
final class AccountSynchronousDepartureGenerationTests: XCTestCase {
    func testAuthenticationChangesAfterDepartureVerificationStopBeforeAnyWrite() async throws {
        for change in ["same-account-token", "foreign-account", "logout"] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            _ = try fixture.rotateDefaultCredentials()
            let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(comparedTo: fixture.entryA)
            XCTAssertNotNil(verified)
            XCTAssertEqual(fixture.http.requests.count, 1)

            switch change {
            case "same-account-token":
                fixture.keychain.currentUserValues[fixture.baseService] =
                    AccountSwitchRecoveryFixture.entry("a", token: "newer-a").credential
            case "foreign-account":
                let external = AccountSwitchRecoveryFixture.entry("c")
                fixture.keychain.currentUserValues[fixture.baseService] = external.credential
                try Data(#"{"oauthAccount":\#(external.claudeOAuthAccount!)}"#.utf8)
                    .write(to: fixture.root.appendingPathComponent(".claude.json"))
            default:
                fixture.keychain.currentUserValues.removeValue(forKey: fixture.baseService)
                try FileManager.default.removeItem(at: fixture.root.appendingPathComponent(".claude/.credentials.json"))
            }
            let state = try fixture.switcher.readClaudeSwitchState()
            let writes = fixture.keychain.writeCount
            let registry = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)

            XCTAssertThrowsError(
                try fixture.switcher.switchAuthentication(
                    to: fixture.b, from: fixture.a, verifiedClaudeDeparture: verified
                ), change
            ) {
                XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged, change)
            }

            XCTAssertEqual(fixture.keychain.writeCount, writes, change)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state, change)
            XCTAssertEqual(fixture.defaults.data(forKey: AccountProfilesStore.storageKey), registry, change)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id, change)
            XCTAssertEqual(fixture.store.authenticationRevision, 0, change)
            XCTAssertNil(try fixture.store.pendingIdentityReplacement(), change)
            XCTAssertNil(try fixture.journal.load(), change)
            try fixture.assertSavedAccountsUnchanged()
        }
    }
}
