import XCTest
@testable import Egasu

@MainActor
final class AccountSelectionDepartureTests: XCTestCase {
    func testForeignTokenAndOrganizationCannotReplaceDeparture() async throws {
        for identity in ["acct-c|org-c", "acct-a|other-org"] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let changed = AccountSwitchRecoveryFixture.entry("a", token: "foreign-token")
            fixture.keychain.currentUserValues[fixture.baseService] = changed.credential
            fixture.http.identities["foreign-token"] = identity
            let state = try fixture.switcher.readClaudeSwitchState()
            let writes = fixture.keychain.writeCount

            await assertSwitchFails {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }

            try fixture.assertSavedAccountsUnchanged()
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
            XCTAssertEqual(fixture.keychain.writeCount, writes)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
            XCTAssertNil(try fixture.journal.load())
            XCTAssertEqual(fixture.http.requests.count, 1)
        }
    }

    func testRejectedReconciliationCannotBeBypassedByManualSwitch() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        fixture.keychain.currentUserValues[fixture.baseService] = AccountSwitchRecoveryFixture.entry("c").credential
        fixture.http.identities["token-c"] = "acct-c|org-c"
        let importer = AccountCredentialImporter(
            keychain: fixture.keychain, environment: FakeEnvironment([:]), homeDirectory: fixture.root,
            workspace: fixture.workspace, httpClient: fixture.http
        )
        let reconciliation = await claudeReconciliationResult(importer, in: fixture.store)
        XCTAssertThrowsError(try reconciliation.get())

        await assertSwitchFails {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }

        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(fixture.http.requests.count, 2)
    }

    func testProfileFailuresPreserveDepartureAndDoNotStartJournal() async throws {
        for status in [401, 429, 500, 200] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            _ = try fixture.rotateDefaultCredentials()
            fixture.http.response = HTTPResponse(statusCode: status, headers: [:], body: Data())
            let state = try fixture.switcher.readClaudeSwitchState()
            let writes = fixture.keychain.writeCount

            await assertSwitchFails {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }

            try fixture.assertSavedAccountsUnchanged()
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
            XCTAssertEqual(fixture.keychain.writeCount, writes)
            XCTAssertNil(try fixture.journal.load())
        }
    }

    func testUnchangedDepartureDoesNotRequestProfile() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertTrue(fixture.http.requests.isEmpty)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testVerifiedDefaultRotationIsPreservedOnceAndRestored() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = try fixture.rotateDefaultCredentials(replacingRefreshToken: true)

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(fixture.http.requests.count, 1)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), rotated)
        let home = try fixture.workspace.directory(family: "claude", profileID: fixture.a.id).path
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), rotated)
        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
        XCTAssertEqual(fixture.http.requests.count, 1)
        XCTAssertNil(try fixture.journal.load())
    }

    func testLoginChangeDuringVerificationStopsBeforeAnySave() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let external = AccountSwitchRecoveryFixture.entry("c")
        fixture.http.beforeResponse = { [keychain = fixture.keychain, base = fixture.baseService] in
            keychain.currentUserValues[base] = external.credential
        }
        let writes = fixture.keychain.writeCount

        await assertSwitchFails {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }

        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.keychain.currentUserValues[fixture.baseService], external.credential)
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.journal.load())
    }

    func testSelectionRevisionAndCancellationDuringVerificationStopBeforeJournal() async throws {
        for mutation in ["selection", "revision", "snapshot", "cancellation"] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            _ = try fixture.rotateDefaultCredentials()
            let started = expectation(description: "Profile request started: \(mutation)")
            let gate = SwitchRecoveryReadGate(started: started)
            fixture.http.beforeResponse = { try gate.pauseOnce() }
            defer { gate.release() }
            let task = Task {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }
            await fulfillment(of: [started], timeout: 3)
            switch mutation {
            case "selection":
                fixture.store.setPreferred(family: "claude", profileID: fixture.b.id)
            case "revision":
                let transaction = try fixture.store.beginIdentityReplacement(
                    profileID: fixture.a.id, with: fixture.a.identityKey, replacesSharedAuthentication: false
                )
                _ = try fixture.store.commitIdentityReplacement(transaction)
            case "snapshot":
                try fixture.switcher.saveSnapshot(
                    AccountSwitchRecoveryFixture.entry("a", token: "newer-saved-token"), for: fixture.a
                )
            default:
                task.cancel()
            }
            let writes = fixture.keychain.writeCount
            gate.release()
            await assertSwitchFails { try await task.value }

            XCTAssertEqual(fixture.keychain.writeCount, writes)
            XCTAssertNil(try fixture.journal.load())
            if mutation != "snapshot" {
                try fixture.assertSavedAccountsUnchanged()
            } else {
                XCTAssertEqual(
                    try fixture.switcher.loadSnapshot(for: fixture.a),
                    AccountSwitchRecoveryFixture.entry("a", token: "newer-saved-token")
                )
            }
        }
    }

    func testSynchronousSwitchRejectsUnverifiedDeparture() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let state = try fixture.switcher.readClaudeSwitchState()
        let writes = fixture.keychain.writeCount

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: fixture.b, from: fixture.a))

        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
        XCTAssertNil(try fixture.journal.load())
    }

    func testSynchronousSwitchCannotCaptureTokenChangedAfterVerification() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(comparedTo: fixture.entryA)
        fixture.keychain.currentUserValues[fixture.baseService] = AccountSwitchRecoveryFixture.entry("c").credential
        let state = try fixture.switcher.readClaudeSwitchState()
        let writes = fixture.keychain.writeCount

        XCTAssertThrowsError(
            try fixture.switcher.switchAuthentication(
                to: fixture.b, from: fixture.a, verifiedClaudeDeparture: verified
            ))

        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
    }
}
