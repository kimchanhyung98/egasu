import XCTest
@testable import Egasu

@MainActor
final class AccountExternalLoginCommitTests: XCTestCase {
    func testManualReconciliationKeepsKeychainWritesAndApprovalReadsOffMain() async throws {
        for persistsSelection in [true, false] {
            let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { persistsSelection })
            let rotated = AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a")
            fixture.keychain.currentUserValues[fixture.baseService] = rotated.credential
            let keychain = fixture.keychain
            let sharedService = fixture.baseService
            keychain.beforeRead = { service in
                // 메인 스레드는 Claude Code 공유 항목의 최종 확인만 수행.
                if Thread.isMainThread { XCTAssertEqual(service, sharedService) }
            }
            fixture.keychain.beforeWrite = { _, _ in XCTAssertFalse(Thread.isMainThread) }

            let result = await ProviderRefreshContext.$isManual.withValue(true) {
                await claudeReconciliationResult(fixture.importer, in: fixture.store)
            }
            fixture.keychain.beforeRead = nil
            fixture.keychain.beforeWrite = nil
            if persistsSelection {
                XCTAssertEqual(try result.get(), .updated(profileID: fixture.a.id))
            } else {
                XCTAssertThrowsError(try result.get()) {
                    XCTAssertEqual($0 as? AccountCredentialSwitcher.Error, .selectionSaveFailed)
                }
            }
            XCTAssertEqual(
                try fixture.switcher.loadSnapshot(for: fixture.a), persistsSelection ? rotated : fixture.entryA)
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        }
    }

    func testIncompleteWorkspaceRollbackKeepsVaultGenerationForRecovery() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { false })
        let replacement = AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a")
        fixture.keychain.currentUserValues[fixture.baseService] = replacement.credential
        let workspace = try fixture.workspace.directory(family: "claude", profileID: fixture.a.id)
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: workspace.path, environment: FakeEnvironment())
        fixture.keychain.beforeWrite = { key, value in
            if key == service, ClaudeAuthStore.parseCredentials(value)?.claudeAiOauth?.accessToken == "token-a" {
                throw SwitchRecoveryKeychain.Failure.injected
            }
        }

        let result = await claudeReconciliationResult(fixture.importer, in: fixture.store)

        XCTAssertThrowsError(try result.get()) {
            XCTAssertEqual($0 as? AccountCredentialSwitcher.Error, .selectionSaveFailed)
        }
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), replacement)
        XCTAssertNotNil(try fixture.store.pendingIdentityReplacement())
        fixture.keychain.beforeWrite = nil
        XCTAssertTrue(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store))
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), replacement)
        XCTAssertEqual(fixture.keychain.currentUserValues[service], replacement.credential)
        XCTAssertEqual(
            try String(contentsOf: workspace.appendingPathComponent(".credentials.json"), encoding: .utf8),
            replacement.credential)
    }

    func testExternalLoginChangedAtSelectionCommitDoesNotSelectStaleAccount() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let external = AccountSwitchRecoveryFixture.entry("c")
        let keychain = fixture.keychain
        let base = fixture.baseService
        let state = fixture.root.appendingPathComponent(".claude.json")
        let account = try XCTUnwrap(external.claudeOAuthAccount)
        keychain.beforeRead = { service in
            guard service == base, Thread.isMainThread else { return }
            keychain.beforeRead = nil
            keychain.currentUserValues[base] = external.credential
            try Data(#"{"oauthAccount":\#(account)}"#.utf8).write(to: state)
        }

        let result = await claudeReconciliationResult(fixture.importer, in: fixture.store)

        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged) }
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), external)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testSelectionChangedDuringWorkspaceUpdateKeepsNewSelectionAndRestoresSnapshot() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a")
        fixture.keychain.currentUserValues[fixture.baseService] = rotated.credential
        let started = expectation(description: "writing profile workspace credential")
        let gate = SwitchRecoveryReadGate(started: started)
        let directory = try fixture.workspace.directory(family: "claude", profileID: fixture.a.id)
        let workspaceService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: directory.path, environment: FakeEnvironment())
        fixture.keychain.beforeWrite = { service, _ in
            if service == workspaceService { try gate.pauseOnce() }
        }
        defer { gate.release() }
        let task = Task {
            try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
        }
        await fulfillment(of: [started], timeout: 3)
        fixture.store.setPreferred(family: "claude", profileID: fixture.b.id)
        gate.release()

        do {
            _ = try await task.value
            XCTFail("The selection changed while saving credentials")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), fixture.entryA)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }
}
