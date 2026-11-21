import Foundation
import XCTest
@testable import Egasu

final class VaultMigrationRaceTests: XCTestCase {
    func testDeletionDuringLegacyReadDoesNotRestoreTheDeletedSignIn() throws {
        for family in ["codex", "claude"] {
            try assertLegacyReadRace(family: family, replacement: nil)
        }
    }

    func testSaveDuringLegacyReadKeepsAndReturnsTheNewSignIn() throws {
        for family in ["codex", "claude"] {
            try assertLegacyReadRace(family: family, replacement: newEntry)
        }
    }

    func testDeletionWaitsForAnInProgressMigrationWrite() throws {
        for family in ["codex", "claude"] {
            try assertMigrationWriteRace(family: family, replacement: nil)
        }
    }

    func testSaveWaitsForAnInProgressMigrationWrite() throws {
        for family in ["codex", "claude"] {
            try assertMigrationWriteRace(family: family, replacement: newEntry)
        }
    }

    func testCredentialReplacementCompletesAPendingMigration() throws {
        for family in ["codex", "claude"] {
            let fixture = try VaultMigrationRaceFixture(family: family, phase: .legacyRead)
            defer { fixture.cleanUp() }
            fixture.keychain.gate.release()

            try fixture.makeVault().replaceCredential(
                "rotated-fixture-credential", family: family, profileID: fixture.profile.id, allowInteraction: true
            )

            var expected = fixture.oldEntry
            expected.credential = "rotated-fixture-credential"
            XCTAssertEqual(try fixture.storedEntry(), expected, family)
            XCTAssertFalse(fixture.pending.contains(family: family, profileID: fixture.profile.id), family)
        }
    }

    func testMigrationWriteDoesNotBlockAnotherAccount() throws {
        for family in ["codex", "claude"] {
            let fixture = try VaultMigrationRaceFixture(family: family, phase: .migrationWrite)
            defer { fixture.cleanUp() }
            let migrationFinished = startMigration(fixture, expected: fixture.oldEntry)
            guard fixture.keychain.gate.waitUntilPaused() else {
                fixture.keychain.gate.release()
                wait(for: [migrationFinished], timeout: 5)
                throw VaultMigrationRaceError.gateNotReached
            }
            let other = AccountProfile(
                id: UUID().uuidString, family: family, label: "Other",
                identityKey: "other", createdAt: .distantPast
            )
            let otherSaved = DispatchGroup()
            let otherFinished = expectation(description: "another account saved")
            otherSaved.enter()
            DispatchQueue.global().async {
                defer { otherSaved.leave(); otherFinished.fulfill() }
                do { try fixture.makeVault().save(fixture.oldEntry, profile: other) } catch {
                    XCTFail("Another account save failed: \(error)")
                }
            }
            let completion = otherSaved.wait(timeout: .now() + 3)
            fixture.keychain.gate.release()
            wait(for: [migrationFinished, otherFinished], timeout: 5)

            XCTAssertEqual(completion, .success, family)
            XCTAssertEqual(try fixture.makeVault().load(profile: other), fixture.oldEntry, family)
        }
    }

    private var newEntry: AccountCredentialVault.Entry {
        .init(credential: "new-fixture-credential", claudeOAuthAccount: "new-fixture-account")
    }

    private func assertLegacyReadRace(family: String, replacement: AccountCredentialVault.Entry?) throws {
        let fixture = try VaultMigrationRaceFixture(family: family, phase: .legacyRead)
        defer { fixture.cleanUp() }
        let migrationFinished = startMigration(fixture, expected: replacement)
        guard fixture.keychain.gate.waitUntilPaused() else {
            fixture.keychain.gate.release()
            wait(for: [migrationFinished], timeout: 5)
            throw VaultMigrationRaceError.gateNotReached
        }
        let mutationFinished = expectation(description: "mutation during legacy read finished")
        let mutationDone = DispatchGroup()
        mutationDone.enter()
        DispatchQueue.global().async {
            defer { mutationDone.leave(); mutationFinished.fulfill() }
            do { try fixture.mutate(replacement: replacement) } catch { XCTFail("Mutation failed: \(error)") }
        }
        let completion = mutationDone.wait(timeout: .now() + 3)
        XCTAssertEqual(completion, .success, "Legacy approval must not block mutation: \(family)")
        if completion == .success {
            XCTAssertFalse(fixture.pending.contains(family: family, profileID: fixture.profile.id), family)
        }
        fixture.keychain.gate.release()
        wait(for: [migrationFinished, mutationFinished], timeout: 5)

        XCTAssertEqual(try fixture.makeVault().load(profile: fixture.profile), replacement, family)
        XCTAssertEqual(try fixture.storedEntry(), replacement, family)
        XCTAssertNotNil(try fixture.keychain.readGenericPassword(service: fixture.legacyService), family)
    }

    private func assertMigrationWriteRace(family: String, replacement: AccountCredentialVault.Entry?) throws {
        let fixture = try VaultMigrationRaceFixture(family: family, phase: .migrationWrite)
        defer { fixture.cleanUp() }
        let migrationFinished = startMigration(fixture, expected: fixture.oldEntry)
        guard fixture.keychain.gate.waitUntilPaused() else {
            fixture.keychain.gate.release()
            wait(for: [migrationFinished], timeout: 5)
            throw VaultMigrationRaceError.gateNotReached
        }
        let mutationStarted = DispatchSemaphore(value: 0)
        let mutationDone = DispatchGroup()
        let mutationFinished = expectation(description: "mutation after migration write finished")
        mutationDone.enter()
        DispatchQueue.global().async {
            defer { mutationDone.leave(); mutationFinished.fulfill() }
            mutationStarted.signal()
            do { try fixture.mutate(replacement: replacement) } catch { XCTFail("Mutation failed: \(error)") }
        }
        XCTAssertEqual(mutationStarted.wait(timeout: .now() + 3), .success, family)
        let earlyCompletion = mutationDone.wait(timeout: .now() + 0.2)
        fixture.keychain.gate.release()
        wait(for: [migrationFinished, mutationFinished], timeout: 5)

        XCTAssertEqual(earlyCompletion, .timedOut, family)
        XCTAssertEqual(try fixture.storedEntry(), replacement, family)
        XCTAssertFalse(fixture.pending.contains(family: family, profileID: fixture.profile.id), family)
    }

    private func startMigration(
        _ fixture: VaultMigrationRaceFixture, expected: AccountCredentialVault.Entry?
    ) -> XCTestExpectation {
        let finished = expectation(description: "migration finished")
        DispatchQueue.global().async {
            defer { finished.fulfill() }
            do {
                let entry = try fixture.makeVault().load(profile: fixture.profile, allowInteraction: true)
                XCTAssertEqual(entry, expected)
            } catch {
                XCTFail("Migration failed: \(error)")
            }
        }
        return finished
    }
}

private final class VaultMigrationRaceFixture: @unchecked Sendable {
    let profile: AccountProfile
    let pending: PendingKeychainMigration
    let keychain: VaultMigrationRaceKeychain
    let legacyService: String
    let currentService: String
    let oldEntry = AccountCredentialVault.Entry(
        credential: "old-fixture-credential", claudeOAuthAccount: "old-fixture-account")
    private let namespace = StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.vault-race-test")
    private let suite: String
    private let defaults: UserDefaults

    init(family: String, phase: VaultMigrationRaceGate.Phase) throws {
        suite = "EgasuTests.VaultMigrationRace.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        pending = PendingKeychainMigration(defaults: defaults)
        profile = AccountProfile(
            id: UUID().uuidString, family: family, label: "Fixture",
            identityKey: "fixture", createdAt: .distantPast
        )
        legacyService = AccountCredentialVault.legacyService(family: family, profileID: profile.id)
        currentService = AccountCredentialVault.service(family: family, profileID: profile.id, namespace: namespace)
        keychain = VaultMigrationRaceKeychain(
            legacyService: legacyService, currentService: currentService,
            oldValue: String(decoding: try JSONEncoder().encode(oldEntry), as: UTF8.self), phase: phase
        )
        pending.record(family: family, profileID: profile.id)
    }

    func makeVault() -> AccountCredentialVault {
        AccountCredentialVault(keychain: keychain, pendingMigration: pending, namespace: namespace)
    }

    func mutate(replacement: AccountCredentialVault.Entry?) throws {
        if let replacement {
            try makeVault().save(replacement, profile: profile)
        } else {
            try makeVault().delete(profile: profile)
        }
    }

    func storedEntry() throws -> AccountCredentialVault.Entry? {
        try keychain.readGenericPassword(service: currentService).map {
            try JSONDecoder().decode(AccountCredentialVault.Entry.self, from: Data($0.utf8))
        }
    }

    func cleanUp() {
        keychain.gate.release()
        defaults.removePersistentDomain(forName: suite)
    }
}

private enum VaultMigrationRaceError: Error {
    case gateNotReached
    case gateTimedOut
}

private final class VaultMigrationRaceGate: @unchecked Sendable {
    enum Phase { case legacyRead, migrationWrite }
    private let phase: Phase
    private let lock = NSLock()
    private let entered = DispatchSemaphore(value: 0)
    private let resume = DispatchSemaphore(value: 0)
    private var armed = true

    init(phase: Phase) { self.phase = phase }

    func pause(_ phase: Phase) throws {
        lock.lock()
        let shouldPause = armed && phase == self.phase
        if shouldPause { armed = false }
        lock.unlock()
        guard shouldPause else { return }
        entered.signal()
        guard resume.wait(timeout: .now() + 10) == .success else { throw VaultMigrationRaceError.gateTimedOut }
    }

    func waitUntilPaused() -> Bool { entered.wait(timeout: .now() + 3) == .success }
    func release() { resume.signal() }
}

private final class VaultMigrationRaceKeychain: KeychainAccessing, @unchecked Sendable {
    let gate: VaultMigrationRaceGate
    private let lock = NSLock()
    private let legacyService: String
    private let currentService: String
    private var values: [String: String]

    init(legacyService: String, currentService: String, oldValue: String, phase: VaultMigrationRaceGate.Phase) {
        self.legacyService = legacyService
        self.currentService = currentService
        values = [legacyService: oldValue]
        gate = VaultMigrationRaceGate(phase: phase)
    }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        let value = try readGenericPassword(service: service)
        if service == legacyService, forCurrentUser { try gate.pause(.legacyRead) }
        return value
    }

    func readGenericPassword(service: String) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[service]
    }

    func writeGenericPassword(service: String, value: String) throws {
        if service == currentService { try gate.pause(.migrationWrite) }
        lock.lock()
        defer { lock.unlock() }
        values[service] = value
    }

    func deleteGenericPassword(service: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values.removeValue(forKey: service)
    }
}
