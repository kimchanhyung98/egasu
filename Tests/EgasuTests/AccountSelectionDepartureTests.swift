import XCTest
import os
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

    func testBareSharedIdentityPreservesVerifiedFullSnapshotAndRestores() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let bare = AccountCredentialVault.Entry(
            credential: AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-a"}"#
        )
        try fixture.switcher.applySharedAuthentication(bare, family: "claude")

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        let saved = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.a))
        XCTAssertEqual(fixture.http.requests.count, 1)
        XCTAssertEqual(saved.credential, bare.credential)
        XCTAssertEqual(fixture.switcher.identity(of: saved, family: "claude")?.identityKey, fixture.a.identityKey)
        let home = try fixture.workspace.directory(family: "claude", profileID: fixture.a.id).path
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), saved)
        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.a, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), saved)
        XCTAssertNil(try fixture.journal.load())
    }

    func testBareSharedIdentityProfileFailurePreservesState() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let bare = AccountCredentialVault.Entry(
            credential: AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-a"}"#
        )
        try fixture.switcher.applySharedAuthentication(bare, family: "claude")
        fixture.http.response = HTTPResponse(statusCode: 401, headers: [:], body: Data())
        let state = try fixture.switcher.readClaudeSwitchState()
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            XCTFail("Expected the profile verification failure")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .tokenExpired)
        }
        XCTAssertEqual(fixture.http.requests.count, 1)
        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.journal.load())
    }

    func testBareSharedIdentityWriteFailureKeepsSnapshotAndAllowsExplicitRetry() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let bare = AccountCredentialVault.Entry(
            credential: AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-a"}"#
        )
        fixture.keychain.currentUserValues[fixture.baseService] = bare.credential
        try Data(#"{"oauthAccount":\#(bare.claudeOAuthAccount!)}"#.utf8)
            .write(to: fixture.root.appendingPathComponent(".claude.json"))
        fixture.keychain.beforeWrite = { _, value in
            if value == fixture.entryB.credential { throw SwitchRecoveryKeychain.Failure.injected }
        }
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            XCTFail("Expected the injected write failure")
        } catch {
            XCTAssertTrue(error is SwitchRecoveryKeychain.Failure)
        }
        let saved = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.a))
        XCTAssertEqual(saved.credential, bare.credential)
        XCTAssertEqual(fixture.switcher.identity(of: saved, family: "claude")?.identityKey, fixture.a.identityKey)
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        fixture.keychain.beforeWrite = nil
        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), saved)
        XCTAssertNil(try fixture.journal.load())
    }

    func testLegacyBareProfilePreservesVerifiedRawAndRestores() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let legacy = try fixture.store.add(family: "claude", label: "Legacy", identityKey: "acct-a", id: "legacy")
        let old = AccountCredentialVault.Entry(
            credential: fixture.entryA.credential, claudeOAuthAccount: #"{"accountUuid":"acct-a"}"#
        )
        let rotated = AccountCredentialVault.Entry(
            credential: AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a").credential,
            claudeOAuthAccount: old.claudeOAuthAccount
        )
        try fixture.switcher.saveSnapshot(old, for: legacy)
        try fixture.switcher.writeWorkspaceAuthentication(old, for: legacy)
        try fixture.switcher.applySharedAuthentication(rotated, family: "claude")
        fixture.store.setPreferred(family: "claude", profileID: legacy.id)

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: legacy), rotated)
        XCTAssertEqual(fixture.http.requests.count, 1)
        let home = try fixture.workspace.directory(family: "claude", profileID: legacy.id).path
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), rotated)
        try await fixture.selectionSwitcher.switchAuthentication(to: legacy, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
        XCTAssertNil(try fixture.journal.load())
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

    func testDepartureSnapshotReadsLeaveMainActorResponsive() async throws {
        for blockedRead in [1, 2] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let service = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
            let threads = OSAllocatedUnfairLock(initialState: [Bool]())
            let started = expectation(description: "Departure snapshot read \(blockedRead)")
            let gate = SwitchRecoveryReadGate(started: started)
            fixture.keychain.beforeRead = { observedService in
                guard observedService == service else { return }
                let count = threads.withLock {
                    $0.append(Thread.isMainThread)
                    return $0.count
                }
                if count == blockedRead { try gate.pauseOnce() }
            }
            defer {
                gate.release()
                fixture.keychain.beforeRead = nil
            }
            let operation = Task {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }
            await fulfillment(of: [started], timeout: 3)
            XCTAssertEqual(threads.withLock { $0 }, Array(repeating: false, count: blockedRead))
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
            gate.release()
            try await operation.value

            fixture.keychain.beforeRead = nil
            XCTAssertEqual(threads.withLock { $0 }, [false, false])
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
            XCTAssertNil(try fixture.journal.load())
        }
    }

    func testChangesDuringDepartureSnapshotRecheckStopBeforeWriting() async throws {
        for mutation in [
            "profile", "preferred", "revision", "pending", "journal", "snapshot", "shared", "state", "cancel"
        ] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let service = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
            let reads = OSAllocatedUnfairLock(initialState: 0)
            let started = expectation(description: "Departure snapshot recheck: \(mutation)")
            let gate = SwitchRecoveryReadGate(started: started)
            fixture.keychain.beforeRead = { observedService in
                guard observedService == service else { return }
                let count = reads.withLock {
                    $0 += 1
                    return $0
                }
                if count == 2 { try gate.pauseOnce() }
            }
            defer {
                gate.release()
                fixture.keychain.beforeRead = nil
            }
            let operation = Task {
                try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            }
            await fulfillment(of: [started], timeout: 3)
            switch mutation {
            case "profile":
                try fixture.store.rename(profileID: fixture.b.id, to: "Renamed B")
            case "preferred":
                fixture.store.setPreferred(family: "claude", profileID: fixture.b.id)
            case "revision", "pending":
                let transaction = try fixture.store.beginIdentityReplacement(
                    profileID: fixture.a.id, with: fixture.a.identityKey, replacesSharedAuthentication: false
                )
                if mutation == "revision" { _ = try fixture.store.commitIdentityReplacement(transaction) }
            case "journal":
                _ = try fixture.stageIntent()
            case "snapshot":
                try fixture.switcher.saveSnapshot(
                    AccountSwitchRecoveryFixture.entry("a", token: "newer-snapshot"), for: fixture.a
                )
            case "shared":
                fixture.keychain.currentUserValues[fixture.baseService] = fixture.entryB.credential
            case "state":
                fixture.keychain.currentUserValues[fixture.scopedService] = fixture.entryB.credential
            default:
                operation.cancel()
            }
            let profiles = fixture.store.profiles
            let preferred = fixture.store.preferredProfileID(family: "claude")
            let revision = fixture.store.authenticationRevision
            let pending = try fixture.store.pendingIdentityReplacement()
            let journal = try fixture.journal.load()
            let sharedState = try fixture.switcher.readClaudeSwitchState()
            let snapshot = try fixture.switcher.loadSnapshot(for: fixture.a)
            let writes = fixture.keychain.writeCount
            gate.release()
            await assertSwitchFails { try await operation.value }
            fixture.keychain.beforeRead = nil

            XCTAssertEqual(fixture.keychain.writeCount, writes, mutation)
            XCTAssertEqual(fixture.store.profiles, profiles, mutation)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), preferred, mutation)
            XCTAssertEqual(fixture.store.authenticationRevision, revision, mutation)
            XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), pending, mutation)
            XCTAssertEqual(try fixture.journal.load(), journal, mutation)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), sharedState, mutation)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), snapshot, mutation)
        }
    }

    func testSynchronousSwitchCannotCaptureTokenChangedAfterVerification() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let verification = try await fixture.switcher.readSharedClaudeExternalAuthentication(comparedTo: fixture.entryA)
        let verified = try XCTUnwrap(verification)
        fixture.keychain.currentUserValues[fixture.baseService] = AccountSwitchRecoveryFixture.entry("c").credential
        let state = try fixture.switcher.readClaudeSwitchState()
        let writes = fixture.keychain.writeCount

        XCTAssertThrowsError(
            try fixture.switcher.switchAuthentication(
                to: fixture.b, from: fixture.a, verifiedClaudeDeparture: verified
            )
        ) { error in
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }

        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
    }
}
