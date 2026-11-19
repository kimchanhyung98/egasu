import XCTest
import os
@testable import Egasu

@MainActor
final class AccountSwitchJournalSourceTests: XCTestCase {
    func testAppliedObservationBlocksRotationUntilSelectionIsSaved() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let base = fixture.baseService
        let keychain = fixture.keychain
        let target = fixture.entryB.credential
        let blocked = OSAllocatedUnfairLock(initialState: false)
        keychain.beforeRead = { service in
            guard !Thread.isMainThread, service == base, keychain.currentUserValues[base] == target else { return }
            do {
                try AccountCredentialMutationLock.beginClaudeRotation {}
                AccountCredentialMutationLock.endClaudeRotation()
            } catch {
                blocked.withLock { $0 = error as? ClaudeAuthError == .credentialsChanged }
            }
        }
        defer { keychain.beforeRead = nil }

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertTrue(blocked.withLock { $0 })
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
        try AccountCredentialMutationLock.beginClaudeRotation {}
        AccountCredentialMutationLock.endClaudeRotation()
    }

    func testRotationBeforeRecoveryCommitKeepsTheSelectionAndJournal() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let rotated = AccountSwitchRecoveryFixture.entry("b", token: "new-target-generation")
        let base = fixture.baseService
        let keychain = fixture.keychain
        let reads = OSAllocatedUnfairLock(initialState: 0)
        keychain.beforeRead = { service in
            guard service == base else { return }
            let isFinalCheck = reads.withLock {
                $0 += 1
                return $0 == 2
            }
            if isFinalCheck { keychain.currentUserValues[base] = rotated.credential }
        }
        defer { keychain.beforeRead = nil }

        XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store)) {
            XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged)
        }

        XCTAssertEqual(keychain.currentUserValues[base], rotated.credential)
        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
    }

    func testNewJournalRejectsDifferentSourceEvenWithIdenticalLogin() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        try fixture.seedLegacyMirrors(fixture.entryA)
        let record = try fixture.stageIntent()
        XCTAssertNotNil(record.sourceID)
        fixture.keychain.currentUserValues.removeValue(forKey: fixture.baseService)
        let writes = fixture.keychain.writeCount

        XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))
        await assertSwitchFails {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
    }

    func testTargetRecoveryIgnoresUnrelatedCredentialFields() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        var credential = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(fixture.entryB.credential.utf8)) as? [String: Any]
        )
        credential["mcpOAuth"] = ["local": "test-only"]
        let raw = String(decoding: try JSONSerialization.data(withJSONObject: credential), as: UTF8.self)
        fixture.keychain.currentUserValues[fixture.baseService] = raw

        XCTAssertTrue(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))

        XCTAssertEqual(fixture.keychain.currentUserValues[fixture.baseService], raw)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
    }

    func testLegacyJournalAcceptsTheOriginalCompleteState() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent(legacy: true)
        XCTAssertNil(record.sourceID)
        let raw = try String(contentsOfFile: fixture.journal.path, encoding: .utf8)
        XCTAssertFalse(raw.contains("sourceID"))
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        try fixture.seedLegacyMirrors(fixture.entryB)

        XCTAssertTrue(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))

        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
    }

    func testExplicitRetryMigratesKnownLegacyPartialWriteAndLeavesMirrorsAlone() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.stageIntent(legacy: true)
        fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
        XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        let file = fixture.root.appendingPathComponent(".claude/.credentials.json")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), fixture.entryA.credential)
        XCTAssertNil(try fixture.journal.load())
    }

    func testFailedSwitchToThirdAccountCanRetryFromThePreviousMixedState() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let original = try fixture.stageIntent()
        try fixture.switcher.mergeClaudeOAuthAccount(
            fixture.entryB.claudeOAuthAccount, at: fixture.root.appendingPathComponent(".claude.json"))
        let mixed = try fixture.switcher.readClaudeSwitchState()
        let c = try fixture.store.add(family: "claude", label: "C", identityKey: "acct-c|org-c", id: "profile-c")
        let entryC = AccountSwitchRecoveryFixture.entry("c")
        try fixture.switcher.saveSnapshot(entryC, for: c)
        let base = fixture.baseService
        fixture.keychain.beforeWrite = { service, _ in
            if service == base { throw SwitchRecoveryKeychain.Failure.injected }
        }

        await assertSwitchFails { try await fixture.selectionSwitcher.switchAuthentication(to: c, in: fixture.store) }

        let failed = try XCTUnwrap(fixture.journal.load())
        XCTAssertNotEqual(failed.id, original.id)
        XCTAssertEqual(failed.selectedProfileID, c.id)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), mixed)
        fixture.keychain.beforeWrite = nil

        try await fixture.selectionSwitcher.switchAuthentication(to: c, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), entryC)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), c.id)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testRetryAfterAccountStagingRecognizesThePreviouslyObservedExternalLogin() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let external = AccountSwitchRecoveryFixture.entry("c")
        try fixture.switcher.applySharedAuthentication(external, family: "claude")
        let base = fixture.baseService
        fixture.keychain.beforeWrite = { service, _ in
            if service == base { throw SwitchRecoveryKeychain.Failure.injected }
        }
        await assertSwitchFails {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }
        fixture.keychain.beforeWrite = nil
        let record = try XCTUnwrap(fixture.journal.load())
        try fixture.switcher.mergeClaudeOAuthAccount(
            fixture.entryB.claudeOAuthAccount, at: fixture.root.appendingPathComponent(".claude.json"))
        let rotated = AccountSwitchRecoveryFixture.entry("c", token: "rotated-c")
        fixture.keychain.currentUserValues[base] = rotated.credential

        await assertSwitchFails {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }

        XCTAssertEqual(try fixture.journal.load(), record)
        XCTAssertEqual(fixture.keychain.currentUserValues[base], rotated.credential)
        fixture.keychain.currentUserValues[base] = external.credential

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testRecoveryUsesTheRefreshInteractionPolicyForBothKeychainReads() async throws {
        for isManual in [false, true] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            _ = try fixture.stageIntent()
            try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
            let before = fixture.keychain.noninteractiveReadServices.count
            let store = try fixture.freshStore()
            let result = try await ProviderRefreshContext.$isManual.withValue(isManual) {
                try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)
            }

            XCTAssertEqual(result, .updated(profileID: fixture.b.id))
            XCTAssertEqual(
                Array(fixture.keychain.noninteractiveReadServices.dropFirst(before)),
                isManual ? [] : [fixture.baseService, fixture.baseService])
            XCTAssertNil(try fixture.journal.load())
        }
    }

    func testRecoveryKeepsSelectionAndJournalWhileTheSharedLoginIsLocked() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        do {
            let lock = try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: fixture.root)
            defer { withExtendedLifetime(lock) {} }
            XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store)) {
                XCTAssertEqual($0 as? ClaudeShellLoginMigrationError, .busy)
            }
            do {
                try await fixture.selectionSwitcher.recoverInterruptedSwitchAfterStartup(
                    in: fixture.store, allowInteraction: false)
                XCTFail("Recovery should wait for the current shared login operation to finish")
            } catch {
                XCTAssertEqual(error as? ClaudeShellLoginMigrationError, .busy)
            }
            XCTAssertEqual(try fixture.journal.load(), record)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        }

        XCTAssertTrue(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
    }
}
