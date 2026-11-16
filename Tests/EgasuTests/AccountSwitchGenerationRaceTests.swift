import XCTest
import os
@testable import Egasu

@MainActor
final class AccountSwitchGenerationRaceTests: XCTestCase {
    func testChangedDepartureSnapshotIsNotOverwritten() async throws {
        for hasSnapshot in [true, false] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            _ = try fixture.rotateDefaultCredentials()
            if !hasSnapshot {
                try AccountCredentialVault(keychain: fixture.keychain).delete(profile: fixture.a)
            }
            let baseline = try fixture.switcher.loadSnapshot(for: fixture.a)
            XCTAssertEqual(baseline != nil, hasSnapshot)
            let verification = try await fixture.switcher.readSharedClaudeExternalAuthentication(comparedTo: baseline)
            let verified = try XCTUnwrap(verification)
            XCTAssertEqual(verified.baseline, baseline)
            let newer = AccountSwitchRecoveryFixture.entry("a", token: "newer-snapshot")
            try fixture.switcher.saveSnapshot(newer, for: fixture.a)
            let state = try fixture.switcher.readClaudeSwitchState()
            let writes = fixture.keychain.writeCount
            XCTAssertThrowsError(
                try fixture.switcher.switchAuthentication(
                    to: fixture.b, from: fixture.a, verifiedClaudeDeparture: verified
                )
            ) {
                XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged)
            }
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), newer)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
            XCTAssertEqual(fixture.keychain.writeCount, writes)
        }
    }

    func testDepartureSnapshotChangedAfterObservationIsNotOverwritten() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let state = try fixture.switcher.readClaudeSwitchState()
        let profiles = fixture.store.profiles
        let revision = fixture.store.authenticationRevision
        let snapshotService = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        let baseService = fixture.baseService
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let started = expectation(description: "shared read after snapshot recheck")
        let gate = SwitchRecoveryReadGate(started: started)
        fixture.keychain.beforeRead = { service in
            if service == snapshotService { reads.withLock { $0 += 1 } }
            if service == baseService, reads.withLock({ $0 }) == 2 { try gate.pauseOnce() }
        }
        defer { gate.release(); fixture.keychain.beforeRead = nil }
        let operation = Task {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }
        await fulfillment(of: [started], timeout: 3)
        let newer = AccountSwitchRecoveryFixture.entry("a", token: "newer-snapshot")
        try fixture.switcher.saveSnapshot(newer, for: fixture.a)
        let writes = fixture.keychain.writeCount
        gate.release()
        do {
            try await operation.value
            XCTFail("Expected credentialsChanged")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        fixture.keychain.beforeRead = nil
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), newer)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(fixture.store.profiles, profiles)
        XCTAssertEqual(fixture.store.authenticationRevision, revision)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        XCTAssertNotNil(try fixture.journal.load())
    }

    func testSharedAuthenticationChangedDuringFinalTargetReadIsNotOverwritten() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let foreign = AccountSwitchRecoveryFixture.entry("c")
        let targetService = AccountCredentialVault.service(family: "claude", profileID: fixture.b.id)
        let baseService = fixture.baseService
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let writesAtChange = OSAllocatedUnfairLock<Int?>(initialState: nil)
        let keychain = fixture.keychain
        keychain.beforeRead = { service in
            guard service == targetService else { return }
            let count = reads.withLock { value in
                value += 1
                return value
            }
            if count == 3 {
                keychain.currentUserValues[baseService] = foreign.credential
                writesAtChange.withLock { $0 = keychain.writeCount }
            }
        }
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            XCTFail("Expected credentialsChanged")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        keychain.beforeRead = nil
        XCTAssertEqual(reads.withLock { $0 }, 3)
        XCTAssertEqual(keychain.currentUserValues[baseService], foreign.credential)
        XCTAssertEqual(keychain.writeCount, writesAtChange.withLock { $0 })
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), fixture.entryB)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNotNil(try fixture.journal.load())
    }

    func testTargetChangedAfterInitialCheckIsNotApplied() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let state = try fixture.switcher.readClaudeSwitchState()
        let newer = AccountSwitchRecoveryFixture.entry("b", token: "newer-target")
        let encoded = String(decoding: try JSONEncoder().encode(newer), as: UTF8.self)
        let departingService = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        let targetService = AccountCredentialVault.service(family: "claude", profileID: fixture.b.id)
        let reads = OSAllocatedUnfairLock(initialState: 0)
        let keychain = fixture.keychain
        keychain.beforeRead = { service in
            guard service == departingService else { return }
            let count = reads.withLock { value in
                value += 1
                return value
            }
            if count == 3 { keychain.currentUserValues[targetService] = encoded }
        }
        do {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
            XCTFail("Expected credentialsChanged")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        keychain.beforeRead = nil
        XCTAssertGreaterThanOrEqual(reads.withLock { $0 }, 3)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), newer)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertTrue(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))
        XCTAssertNil(try fixture.journal.load())
        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), newer)
        XCTAssertNil(try fixture.journal.load())
    }

    func testChangedTargetSnapshotDoesNotApplyUnjournaledGeneration() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let started = expectation(description: "profile request")
        let gate = SwitchRecoveryReadGate(started: started)
        fixture.http.beforeResponse = { try gate.pauseOnce() }
        defer { gate.release() }
        let state = try fixture.switcher.readClaudeSwitchState()
        let profiles = fixture.store.profiles
        let revision = fixture.store.authenticationRevision
        let operation = Task {
            try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        }
        await fulfillment(of: [started], timeout: 3)
        let newer = AccountSwitchRecoveryFixture.entry("b", token: "newer-target")
        try fixture.switcher.saveSnapshot(newer, for: fixture.b)
        let writes = fixture.keychain.writeCount
        gate.release()
        do {
            try await operation.value
            XCTFail("Expected credentialsChanged")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), newer)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), state)
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(fixture.store.profiles, profiles)
        XCTAssertEqual(fixture.store.authenticationRevision, revision)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        XCTAssertNotNil(try fixture.journal.load())
        XCTAssertTrue(try fixture.selectionSwitcher.recoverInterruptedSwitch(in: fixture.store))
        XCTAssertNil(try fixture.journal.load())
        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), newer)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertNil(try fixture.journal.load())
    }
}
