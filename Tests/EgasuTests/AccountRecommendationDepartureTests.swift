import XCTest
@testable import Egasu

@MainActor
final class AccountRecommendationDepartureTests: XCTestCase {
    func testCodexRecommendationKeepsSavedAccountsWhenSharedLoginChangesDuringCurrentSnapshotRead() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let current = try fixture.store.add(family: "codex", label: "Current", identityKey: "current", id: "codex-a")
        let target = try fixture.store.add(family: "codex", label: "Target", identityKey: "target", id: "codex-b")
        func entry(_ identity: String, token: String) -> AccountCredentialVault.Entry {
            .init(
                credential: #"{"tokens":{"access_token":"\#(token)","account_id":"\#(identity)"}}"#,
                claudeOAuthAccount: nil)
        }
        let savedCurrent = entry("current", token: "saved-current")
        let savedTarget = entry("target", token: "saved-target")
        for (profile, saved) in [(current, savedCurrent), (target, savedTarget)] {
            try fixture.switcher.saveSnapshot(saved, for: profile)
            try fixture.switcher.writeWorkspaceAuthentication(saved, for: profile)
        }
        try fixture.switcher.applySharedAuthentication(entry("current", token: "active-current"), family: "codex")

        let external = entry("external", token: "external-login")
        let sharedPath = fixture.root.appendingPathComponent(".codex/auth.json")
        let currentService = AccountCredentialVault.service(family: "codex", profileID: current.id)
        let writeCount = fixture.keychain.writeCount
        fixture.keychain.beforeRead = { service in
            if service == currentService {
                try Data(external.credential.utf8).write(to: sharedPath, options: .atomic)
            }
        }
        let recommendation = AccountSwitchRecommendation(current: current, target: target)
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: target, in: fixture.store) { identity in
                try recommendation.validate(departure: identity, latest: recommendation)
            }
            XCTFail("The external login must remain active")
        } catch CodexAuthError.credentialsChanged {}
        fixture.keychain.beforeRead = nil

        XCTAssertEqual(fixture.keychain.writeCount, writeCount)
        for (profile, saved) in [(current, savedCurrent), (target, savedTarget)] {
            let home = try fixture.workspace.directory(family: "codex", profileID: profile.id).path
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: profile), saved)
            XCTAssertEqual(try fixture.switcher.readAuthentication(family: "codex", home: home), saved)
        }
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "codex"), current.id)
    }
}
