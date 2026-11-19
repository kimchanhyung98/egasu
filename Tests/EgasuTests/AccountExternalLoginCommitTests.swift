import XCTest
@testable import Egasu

@MainActor
final class AccountExternalLoginCommitTests: XCTestCase {
    func testManualReconciliationReadsAndWritesKeychainOffMainThroughRollback() async throws {
        for persistsSelection in [true, false] {
            let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { persistsSelection })
            let rotated = AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a")
            fixture.keychain.currentUserValues[fixture.baseService] = rotated.credential
            fixture.keychain.beforeRead = { _ in XCTAssertFalse(Thread.isMainThread) }
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
