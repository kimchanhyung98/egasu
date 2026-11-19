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

        XCTAssertThrowsError(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))

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
}
