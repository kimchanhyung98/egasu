import XCTest
@testable import Egasu

@MainActor
final class AccountClaudeReSignInRecoveryTests: XCTestCase {
    func testReSignInAndRollbackFailuresRemainDistinctAndPrivate() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        try fixture.switcher.writeWorkspaceAuthentication(AccountSwitchRecoveryFixture.entry("c"), for: fixture.a)
        let vault = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        var attempts = 0
        fixture.keychain.beforeWrite = { service, _ in
            guard service == vault else { return }
            attempts += 1
            throw KeychainError.writeFailed(attempts == 1 ? "PRIVATE_SAVE_ERROR" : "PRIVATE_ROLLBACK_ERROR")
        }
        let previousSink = AppLog.sink
        defer { AppLog.sink = previousSink }
        AppLog.sink = LogFile(directory: fixture.root, fileName: "rollback.log")
        AppLog.sink.open()
        let diagnostic = DiagnosticEventRecorder()

        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(profileID: fixture.a.id, in: fixture.store, isActive: true)
        ) { error in
            guard case .writeFailed("PRIVATE_SAVE_ERROR") = error as? KeychainError else {
                return XCTFail("Expected the original save failure")
            }
        }

        XCTAssertEqual(attempts, 2)
        XCTAssertEqual(
            diagnostic.events,
            [
                DiagnosticEvent(.accountRollback, result: .failure, category: .credentialAccess, providerID: "claude")
            ])
        XCTAssertFalse(DiagnosticOperation.accountRollback.tracksRecovery)
        let log = try String(contentsOf: fixture.root.appendingPathComponent("rollback.log"), encoding: .utf8)
        let failures = log.components(separatedBy: .newlines).filter { $0.contains("operation=account_rollback") }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(try XCTUnwrap(failures.first).contains("restore saved login"))
        XCTAssertFalse(log.contains("PRIVATE_"))
        let saved = try XCTUnwrap(fixture.store.pendingIdentityReplacement())
        XCTAssertEqual(saved.profileID, fixture.a.id)
    }

    func testActiveReSignInRestoresLoggedOutCLIWhenCommitFails() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let file = fixture.root.appendingPathComponent(".claude.json")
        let preferences = #"{"theme":"dark"}"#
        let externalCredentials = #"{"mcpOAuth":{"provider":"keep-me"}}"#
        try Data(preferences.utf8).write(to: file)
        fixture.keychain.currentUserValues[fixture.baseService] = externalCredentials
        try fixture.switcher.writeWorkspaceAuthentication(AccountSwitchRecoveryFixture.entry("c"), for: fixture.a)

        let keychain = fixture.keychain
        let defaults = fixture.defaults
        let base = fixture.baseService
        keychain.beforeWrite = { service, _ in
            guard service == base else { return }
            keychain.beforeWrite = nil
            defaults.removeObject(forKey: AccountProfilesStore.identityReplacementKey)
        }

        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(profileID: fixture.a.id, in: fixture.store, isActive: true)
        ) { XCTAssertEqual($0 as? AccountIdentityReplacementError, .invalidTransaction) }
        XCTAssertNil(try fixture.switcher.readSharedAuthentication(family: "claude"))
        XCTAssertEqual(keychain.currentUserValues[base], externalCredentials)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), preferences)
        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.store.profile(id: fixture.a.id)?.identityKey, fixture.a.identityKey)
    }

    func testWhitespaceAccessTokenDoesNotBlockApplyingSharedLogin() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        fixture.keychain.currentUserValues[fixture.baseService] =
            #"{"claudeAiOauth":{"accessToken":"   "},"mcpOAuth":{"provider":"keep-me"}}"#
        XCTAssertNil(try fixture.switcher.readSharedAuthentication(family: "claude"))

        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        let raw = try XCTUnwrap(fixture.keychain.currentUserValues[fixture.baseService])
        let document = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(raw))
        XCTAssertEqual(document["mcpOAuth"] as? [String: String], ["provider": "keep-me"])
    }

    func testReSignInPreservesNewCLIGenerationWhenVaultWriteTriggersRotation() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let replacement = AccountSwitchRecoveryFixture.entry("c")
        let rotated = AccountSwitchRecoveryFixture.entry("a", token: "rotated-by-cli")
        let alternate = AccountSwitchRecoveryFixture.entry("a", token: "untouched-scoped")
        try fixture.switcher.writeWorkspaceAuthentication(replacement, for: fixture.a)
        let keychain = fixture.keychain
        let vault = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        let base = fixture.baseService
        keychain.currentUserValues[fixture.scopedService] = alternate.credential
        keychain.beforeWrite = { service, _ in
            guard service == vault else { return }
            keychain.beforeWrite = nil
            keychain.currentUserValues[base] = rotated.credential
        }
        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(profileID: fixture.a.id, in: fixture.store, isActive: true)
        ) {
            XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
        XCTAssertEqual(keychain.currentUserValues[fixture.scopedService], alternate.credential)
        XCTAssertEqual(fixture.store.profile(id: fixture.a.id)?.identityKey, fixture.a.identityKey)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), replacement)
        XCTAssertNotNil(try fixture.store.pendingIdentityReplacement())
    }

    func testActiveReSignInPreservesPeerBundlesPendingSwitch() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let record = try fixture.stageIntent()
        try fixture.journal.clear(record)
        let production = StorageNamespace.productionBundleIdentifier
        let development = production + ".dev"
        let peer = AppBundleLocator.current.bundleIdentifier == development ? production : development
        let namespace = StorageNamespace(bundleIdentifier: peer)
        let journal = AccountSwitchJournal(
            path: fixture.root.appendingPathComponent(
                "Library/Application Support/\(namespace.name)/AccountSignIn/claude-switch.json"
            ).path)
        try journal.save(record, replacing: nil)
        try fixture.switcher.writeWorkspaceAuthentication(AccountSwitchRecoveryFixture.entry("c"), for: fixture.a)
        let writes = fixture.keychain.writeCount

        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(profileID: fixture.a.id, in: fixture.store, isActive: true)
        ) {
            XCTAssertEqual($0 as? ClaudeShellLoginMigrationError, .pendingSwitch)
        }
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
        XCTAssertEqual(try journal.load(), record)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testActiveRotationDefersReSignInBeforeCreatingRecoveryOrWritingCredentials() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        try fixture.switcher.writeWorkspaceAuthentication(AccountSwitchRecoveryFixture.entry("c"), for: fixture.a)
        let writes = fixture.keychain.writeCount
        try AccountCredentialMutationLock.beginClaudeRotation {}
        defer { AccountCredentialMutationLock.endClaudeRotation() }
        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(profileID: fixture.a.id, in: fixture.store, isActive: true)
        ) {
            XCTAssertEqual($0 as? ClaudeAuthError, .rotationInProgress)
        }
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testActiveRotationAllowsUnchangedObservationButDefersNewCredentials() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let writes = fixture.keychain.writeCount
        try AccountCredentialMutationLock.beginClaudeRotation {}
        defer { AccountCredentialMutationLock.endClaudeRotation() }
        let unchanged = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(
            in: fixture.store)
        XCTAssertEqual(unchanged, .unchanged)
        let rotated = AccountSwitchRecoveryFixture.entry("a", token: "rotated-access-a")
        fixture.keychain.currentUserValues[fixture.baseService] = rotated.credential
        do {
            _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
            XCTFail("Expected the pending rotation to defer saving the new login")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .rotationInProgress)
        }
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), fixture.entryA)
    }

    func testReconciliationPreservesSavedAccountUpdatedDuringProfileVerification() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let observed = AccountSwitchRecoveryFixture.entry("a", token: "rotated-by-cli")
        let newer = AccountSwitchRecoveryFixture.entry("a", token: "newer-vault-login")
        fixture.keychain.currentUserValues[fixture.baseService] = observed.credential
        fixture.http.identities["rotated-by-cli"] = fixture.a.identityKey
        let switcher = fixture.switcher
        let profile = fixture.a
        fixture.http.beforeResponse = { try switcher.saveSnapshot(newer, for: profile) }
        let importer = AccountCredentialImporter(
            keychain: fixture.keychain, environment: FakeEnvironment(), homeDirectory: fixture.root,
            workspace: fixture.workspace, httpClient: fixture.http
        )
        do {
            _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
            XCTFail("Expected the updated vault generation to stop reconciliation")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertEqual(try switcher.loadSnapshot(for: fixture.a), newer)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "claude"), observed)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testStartupRecoveryDefersWhenVaultChangesDuringApprovedRead() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let replacement = AccountSwitchRecoveryFixture.entry("c")
        let rotated = AccountSwitchRecoveryFixture.entry("c", token: "rotated")
        _ = try fixture.store.beginIdentityReplacement(
            profileID: fixture.a.id, with: "acct-c|org-c", replacesSharedAuthentication: false)
        try fixture.switcher.saveSnapshot(replacement, for: fixture.a)
        let service = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        let keychain = fixture.keychain
        let switcher = fixture.switcher
        let profile = fixture.a
        keychain.beforeRead = { read in
            guard read == service else { return }
            keychain.beforeRead = nil
            XCTAssertFalse(Thread.isMainThread)
            try switcher.saveSnapshot(rotated, for: profile)
        }
        let result = try await ProviderRefreshContext.$isManual.withValue(true) {
            try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: fixture.store)
        }
        XCTAssertEqual(result, .unchanged)
        XCTAssertNotNil(try fixture.store.pendingIdentityReplacement())
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), rotated)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
    }

    func testCrashRecoveryFinishesOnlyTheRecordedSameAccountCredential() throws {
        for savedReplacement in [true, false] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let replacement = AccountSwitchRecoveryFixture.entry("a", token: "reauthenticated")
            _ = try beginReplacement(in: fixture, replacement: replacement, identity: fixture.a.identityKey)
            if savedReplacement {
                try fixture.switcher.saveSnapshot(replacement, for: fixture.a)
            }
            XCTAssertEqual(
                try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store), savedReplacement)
            XCTAssertEqual(
                try fixture.switcher.readSharedAuthentication(family: "claude"),
                savedReplacement ? replacement : fixture.entryA)
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        }
    }

    func testExternalRenewalRecoveryDiscardsIntentWhenReplacementWasNeverSaved() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = try fixture.rotateDefaultCredentials()
        let generation = try AccountIdentityReplacement.ExternalClaudeGeneration(
            state: fixture.switcher.readClaudeSwitchState(), previous: fixture.entryA, replacement: rotated)
        _ = try fixture.store.beginIdentityReplacement(
            profileID: fixture.a.id, with: fixture.a.identityKey, replacesSharedAuthentication: false,
            externalClaudeGeneration: generation)
        let writes = fixture.keychain.writeCount

        XCTAssertFalse(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store))
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), rotated)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        try fixture.assertSavedAccountsUnchanged()
    }

    func testVerifiedExternalReplacementRecoversBeforeObservingNewerCLILogin() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let replacement = AccountSwitchRecoveryFixture.entry("c")
        try fixture.switcher.applySharedAuthentication(replacement, family: "claude")
        let generation = try AccountIdentityReplacement.ExternalClaudeGeneration(
            state: fixture.switcher.readClaudeSwitchState(), previous: fixture.entryA, replacement: replacement)
        _ = try fixture.store.beginIdentityReplacement(
            profileID: fixture.a.id, with: "acct-c|org-c", replacesSharedAuthentication: false,
            externalClaudeGeneration: generation)
        try fixture.switcher.saveSnapshot(replacement, for: fixture.a)
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")

        let result = await claudeReconciliationResult(fixture.importer, in: fixture.store)

        XCTAssertEqual(try result.get(), .updated(profileID: fixture.b.id))
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(fixture.store.profile(id: fixture.a.id)?.identityKey, "acct-c|org-c")
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), replacement)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryB)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testActiveRecoveryKeepsRecordWhenCLIChangesAtIdentityCommit() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let replacement = AccountSwitchRecoveryFixture.entry("c")
        let record = try beginReplacement(in: fixture, replacement: replacement, identity: "acct-c|org-c")
        try fixture.switcher.saveSnapshot(replacement, for: fixture.a)
        let keychain = fixture.keychain
        let base = fixture.baseService
        let external = fixture.entryB
        let account = try XCTUnwrap(external.claudeOAuthAccount)
        let state = fixture.root.appendingPathComponent(".claude.json")
        keychain.beforeRead = { service in
            guard service == base, Thread.isMainThread else { return }
            keychain.beforeRead = nil
            keychain.currentUserValues[base] = external.credential
            try Data(#"{"oauthAccount":\#(account)}"#.utf8).write(to: state)
        }

        let result = await claudeReconciliationResult(fixture.importer, in: fixture.store)

        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged) }
        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), record)
        XCTAssertEqual(fixture.store.profile(id: fixture.a.id)?.identityKey, fixture.a.identityKey)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), external)
    }

    func testCrashBetweenAccountAndTokenWritesCompletesThePendingSignIn() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let replacement = AccountSwitchRecoveryFixture.entry("c")
        _ = try beginReplacement(in: fixture, replacement: replacement, identity: "acct-c|org-c")
        try fixture.switcher.saveSnapshot(replacement, for: fixture.a)
        let account = try XCTUnwrap(replacement.claudeOAuthAccount)
        try Data(#"{"oauthAccount":\#(account)}"#.utf8).write(to: fixture.root.appendingPathComponent(".claude.json"))
        XCTAssertTrue(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store))
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), replacement)
        XCTAssertEqual(fixture.store.profile(id: fixture.a.id)?.identityKey, "acct-c|org-c")
    }

    func testCrashRecoveryPreservesExternallyRotatedCredentialsAndSourceChanges() throws {
        for movedToFile in [false, true] {
            let fixture = try AccountSwitchRecoveryFixture(test: self)
            let replacement = AccountSwitchRecoveryFixture.entry("c")
            let journal = try beginReplacement(in: fixture, replacement: replacement, identity: "acct-c|org-c")
            try fixture.switcher.saveSnapshot(replacement, for: fixture.a)

            if movedToFile {
                let directory = fixture.root.appendingPathComponent(".claude")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data(fixture.entryA.credential.utf8).write(
                    to: directory.appendingPathComponent(".credentials.json"))
                fixture.keychain.currentUserValues.removeValue(forKey: fixture.baseService)
            } else {
                fixture.keychain.currentUserValues[fixture.baseService] =
                    AccountSwitchRecoveryFixture.entry("a", token: "rotated-by-cli").credential
            }
            let updated = try fixture.switcher.readClaudeSwitchState()
            let writes = fixture.keychain.writeCount
            XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store)) {
                XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged)
            }
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), updated)
            XCTAssertEqual(fixture.keychain.writeCount, writes)
            XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
        }
    }

    func testOlderJournalNeverRewritesAnUnidentifiedCLIGeneration() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let replacement = AccountSwitchRecoveryFixture.entry("c")
        let journal = try fixture.store.beginIdentityReplacement(
            profileID: fixture.a.id, with: "acct-c|org-c", replacesSharedAuthentication: true)
        try fixture.switcher.saveSnapshot(replacement, for: fixture.a)
        let writes = fixture.keychain.writeCount
        XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store)) {
            XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertEqual(fixture.keychain.writeCount, writes)
        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
        try fixture.switcher.applySharedAuthentication(replacement, family: "claude")
        XCTAssertTrue(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store))
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    private func beginReplacement(
        in fixture: AccountSwitchRecoveryFixture, replacement: AccountCredentialVault.Entry, identity: String
    ) throws -> AccountIdentityReplacement {
        let change = try AccountIdentityReplacement.ClaudeGeneration(
            state: fixture.switcher.readClaudeSwitchState(), previousSnapshot: fixture.entryA, replacement: replacement
        )
        return try fixture.store.beginIdentityReplacement(
            profileID: fixture.a.id, with: identity, replacesSharedAuthentication: true, claudeGeneration: change
        )
    }
}
