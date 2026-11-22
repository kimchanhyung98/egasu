import Foundation
import XCTest
@testable import Egasu

extension AccountCredentialSwitcherTests {
    private func shellMigrationDefaults() throws -> UserDefaults {
        let suite = "egasu.tests.shellMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return defaults
    }

    @MainActor
    private func assertMigrationFails(
        defaults: UserDefaults, switcher: AccountCredentialSwitcher,
        expecting expected: ClaudeShellLoginMigrationError? = nil,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: switcher)
            XCTFail("Expected migration to fail", file: file, line: line)
        } catch {
            if let expected {
                XCTAssertEqual(error as? ClaudeShellLoginMigrationError, expected, file: file, line: line)
            }
        }
    }

    @discardableResult
    private func installOldClaudeFunction(_ fixture: Fixture) throws -> URL {
        let rc = fixture.home.appendingPathComponent(".zshrc")
        try Data(legacyClaudeZshBlock(home: fixture.home).utf8).write(to: rc)
        return rc
    }

    @MainActor
    func testShellMigrationTransfersLoginBeforeRemovingBothFunctionsAndSkipsCompletedRun() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        defaults.set(true, forKey: StorageMigration.completedKey)
        let vaultOnly = AccountIdentityReplacement(
            profileID: "inactive", previousIdentityKey: "previous", replacementIdentityKey: "replacement",
            replacesSharedAuthentication: false)
        defaults.set(try JSONEncoder().encode(vaultOnly), forKey: AccountProfilesStore.identityReplacementKey)
        let zsh = try installOldClaudeFunction(f)
        let fish = f.home.appendingPathComponent(".config/fish/config.fish")
        let fishBlock = legacyClaudeZshBlock(home: f.home)
            .replacingOccurrences(of: "unalias claude", with: "functions -e claude")
            .replacingOccurrences(of: "function claude {", with: "function claude")
            .replacingOccurrences(of: #""$@""#, with: "$argv")
            .replacingOccurrences(of: "\n}", with: "\nend")
        try FileManager.default.createDirectory(at: fish.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((fishBlock + "\n# keep").utf8).write(to: fish)
        let base = baseClaudeService()
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        try seedClaudeSharedHome(f, token: "old", account: claudeAccount("a"))
        let fallbackFile = f.home.appendingPathComponent(".claude/.credentials.json")
        let originalFallback = try Data(contentsOf: fallbackFile)
        let root = f.home.appendingPathComponent(".claude.json")
        try Data(#"{"theme":"keep"}"#.utf8).write(to: root)
        f.keychain.currentUserValues[base] = #"{"mcpOAuth":{"server":"keep"}}"#
        let original = try credentialWithExtras(token: "active", marker: "scoped-only")
        f.keychain.currentUserValues[scoped] = original

        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)

        XCTAssertEqual(try text(zsh), "")
        XCTAssertEqual(try text(fish), "# keep")
        XCTAssertTrue(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(try state(at: root)["theme"] as? String, "keep")
        XCTAssertEqual(try f.switcher.readClaudeSwitchState().identities, ["acct-a|org-a"])
        let shared = try XCTUnwrap(f.keychain.currentUserValues[base])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(shared)?.claudeAiOauth?.accessToken, "active")
        let savedFields = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(shared))
        XCTAssertEqual(savedFields["mcpOAuth"] as? [String: String], ["server": "keep"])
        XCTAssertNil(savedFields["unknownField"])
        XCTAssertEqual(f.keychain.currentUserValues[scoped], original)
        XCTAssertEqual(try Data(contentsOf: fallbackFile), originalFallback)
        let writes = f.keychain.writeCount
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(f.keychain.writeCount, writes)
    }

    @MainActor
    func testShellMigrationFreshInstallSkipsCredentialsAndAddsNoFunction() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        f.keychain.onSharedRead = { XCTFail("A fresh installation must not read Claude credentials") }
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertTrue(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".zshrc").path))
        XCTAssertEqual(f.keychain.writeCount, 0)
    }

    @MainActor
    func testShellMigrationUsesFreshShellOAuthScopeWithOrWithoutMatchingSnapshot() async throws {
        let stdout = [
            "__EGASU_ENV_BEGIN__", "CLAUDE_CODE_CUSTOM_OAUTH_URL=https://example.test",
            "__EGASU_ENV_END__"
        ].joined(separator: "\0")
        for usesSnapshot in [false, true] {
            let f = try makeFixture()
            let defaults = try shellMigrationDefaults()
            let rc = try installOldClaudeFunction(f)
            let snapshot =
                usesSnapshot
                ? ShellEnvironmentSnapshot(
                    values: ["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://example.test"], capturedAt: Date()) : nil
            let shell = LoginShellEnvironment(runner: MigrationShellRunner(stdout: stdout))
            let reader = ProcessEnvironmentReader(
                processEnvironment: [:], shellEnvironment: shell, launchSnapshot: { snapshot })
            let switcher = AccountCredentialSwitcher(
                keychain: f.keychain, environment: reader, homeDirectory: f.home, workspace: f.workspace)
            let custom = FakeEnvironment(["CLAUDE_CODE_CUSTOM_OAUTH_URL": "https://example.test"])
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: f.home.appendingPathComponent(".claude").path, environment: custom)
            f.keychain.currentUserValues[service] = claudeCredential(token: "custom")
            try switcher.mergeClaudeOAuthAccount(
                claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))

            try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: switcher)

            XCTAssertEqual(try text(rc), "")
            XCTAssertEqual(
                f.keychain.currentUserValues[ClaudeAuthStore.baseKeychainServiceName(environment: custom)],
                claudeCredential(token: "custom"))
            XCTAssertNil(f.keychain.currentUserValues[baseClaudeService()])
        }
    }

    @MainActor
    func testShellMigrationPreservesWrapperWhenCaptureFailsDespiteCompleteSnapshot() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let snapshot = ShellEnvironmentSnapshot(values: [:], capturedAt: Date())
        let reader = ProcessEnvironmentReader(
            processEnvironment: [:], shellEnvironment: LoginShellEnvironment(runner: MigrationShellRunner(stdout: "")),
            launchSnapshot: { snapshot })
        let switcher = AccountCredentialSwitcher(
            keychain: f.keychain, environment: reader, homeDirectory: f.home, workspace: f.workspace)
        f.keychain.onSharedRead = { XCTFail("An unknown OAuth scope must not read Keychain") }
        await assertMigrationFails(defaults: defaults, switcher: switcher, expecting: .shellEnvironmentUnavailable)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(f.keychain.writeCount, 0)
    }

    @MainActor
    func testShellMigrationPreservesWrapperAndBothLoginsWhenSourcedSettingsChanged() async throws {
        for setting in ["CLAUDE_CONFIG_DIR=/fixture/custom", "CLAUDE_CODE_CUSTOM_OAUTH_URL=https://changed.example"] {
            let f = try makeFixture()
            let defaults = try shellMigrationDefaults()
            let rc = try installOldClaudeFunction(f)
            let profile = "source ~/.claude-login-settings\n" + legacyClaudeZshBlock(home: f.home)
            try Data(profile.utf8).write(to: rc)
            let snapshot = ShellEnvironmentSnapshot(values: [:], capturedAt: Date())
            let stdout = ["__EGASU_ENV_BEGIN__", setting, "__EGASU_ENV_END__"].joined(separator: "\0")
            let reader = ProcessEnvironmentReader(
                processEnvironment: [:],
                shellEnvironment: LoginShellEnvironment(runner: MigrationShellRunner(stdout: stdout)),
                launchSnapshot: { snapshot })
            let switcher = AccountCredentialSwitcher(
                keychain: f.keychain, environment: reader, homeDirectory: f.home, workspace: f.workspace)
            let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
            f.keychain.currentUserValues = [
                baseClaudeService(): claudeCredential(token: "default"), scoped: claudeCredential(token: "legacy")
            ]
            let before = f.keychain.currentUserValues
            f.keychain.onSharedRead = { XCTFail("Changed shell scope must be detected before reading Keychain") }

            await assertMigrationFails(defaults: defaults, switcher: switcher, expecting: .shellEnvironmentChanged)

            XCTAssertEqual(f.keychain.currentUserValues, before)
            XCTAssertEqual(f.keychain.writeCount, 0)
            XCTAssertEqual(try text(rc), profile)
            XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        }
    }

    @MainActor
    func testShellMigrationRespectsKeychainDenialAndRetriesOnTheNextLaunch() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        f.keychain.onSharedRead = { throw KeychainError.readFailed("fixture denial") }
        await assertMigrationFails(defaults: defaults, switcher: f.switcher)
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        f.keychain.onSharedRead = nil
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
    }

    @MainActor
    func testShellMigrationConflictPreservesBothLoginsAndRetriesAfterResolution() async throws {
        let f = try makeFixture()
        let rc = try installOldClaudeFunction(f)
        let defaults = try shellMigrationDefaults()
        try seedClaudeSharedHome(f, token: "different", account: claudeAccount("b"))
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "active")
        let accountState = f.home.appendingPathComponent(".claude/.claude.json")
        try Data("{\"oauthAccount\":\(claudeAccount("a"))}".utf8).write(to: accountState)
        let saved = f.keychain.currentUserValues

        await assertMigrationFails(defaults: defaults, switcher: f.switcher, expecting: .conflict)
        XCTAssertEqual(f.keychain.currentUserValues, saved)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))

        try Data("{\"oauthAccount\":\(claudeAccount("a"))}".utf8).write(
            to: f.home.appendingPathComponent(".claude.json"))
        f.keychain.currentUserValues[baseClaudeService()] = claudeCredential(token: "active")
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(f.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "active"))
        XCTAssertEqual(try text(rc), "")
    }

    @MainActor
    func testShellMigrationKeepsDifferentTokenOwnerDespiteMatchingAccountFiles() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        try seedClaudeSharedHome(f, token: "other", account: claudeAccount("a"))
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "legacy")
        f.http.identities = ["other": "acct-b|org-b", "legacy": "acct-a|org-a"]
        let both = f.keychain.currentUserValues

        await assertMigrationFails(defaults: defaults, switcher: f.switcher, expecting: .conflict)

        XCTAssertEqual(f.keychain.currentUserValues, both)
        XCTAssertEqual(f.keychain.writeCount, 0)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
    }

    @MainActor
    func testShellMigrationPreservesProfilesWithAnExportedConfigDirectory() async throws {
        for (shell, setting) in [
            ("zsh", "export CLAUDE_CONFIG_DIR=/another"), ("fish", "set -gx CLAUDE_CONFIG_DIR /another"),
            ("environment", "")
        ] {
            let f = try makeFixture()
            let defaults = try shellMigrationDefaults()
            let rc = try installOldClaudeFunction(f)
            let switcher = AccountCredentialSwitcher(
                keychain: f.keychain,
                environment: FakeEnvironment(shell == "environment" ? ["CLAUDE_CONFIG_DIR": "/another"] : [:]),
                homeDirectory: f.home, workspace: f.workspace)
            if shell == "zsh" {
                try Data((setting + "\n" + legacyClaudeZshBlock(home: f.home)).utf8).write(to: rc)
            } else if shell == "fish" {
                let fish = f.home.appendingPathComponent(".config/fish/config.fish")
                let block = legacyClaudeZshBlock(home: f.home)
                    .replacingOccurrences(of: "unalias", with: "functions -e")
                    .replacingOccurrences(of: "claude {", with: "claude")
                    .replacingOccurrences(of: #""$@""#, with: "$argv")
                    .replacingOccurrences(of: "\n}", with: "\nend")
                try FileManager.default.createDirectory(
                    at: fish.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data((block + "\n" + setting).utf8).write(to: fish)
            }
            let previous = try Data(contentsOf: rc)
            f.keychain.onSharedRead = { XCTFail("Redirected profiles must not migrate a login") }

            await assertMigrationFails(defaults: defaults, switcher: switcher, expecting: .configDirectoryOverride)

            XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
            XCTAssertEqual(try Data(contentsOf: rc), previous)
            XCTAssertEqual(f.keychain.writeCount, 0)
        }
    }

    @MainActor
    func testShellMigrationOnlyCopiesAnIdenticalUnscopedDefaultLogin() async throws {
        for unscopedToken in ["other", "active"] {
            let f = try makeFixture()
            let defaults = try shellMigrationDefaults()
            let rc = try installOldClaudeFunction(f)
            let root = f.home.appendingPathComponent(".claude.json")
            try seedClaudeSharedHome(f, token: "stale", account: claudeAccount("a"))
            try Data(#"{"theme":"keep"}"#.utf8).write(to: root)

            let base = baseClaudeService()
            let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
            let active = claudeCredential(token: "active")
            let unscoped = claudeCredential(token: unscopedToken)
            f.keychain.currentUserValues[base] = nil
            f.keychain.currentUserValues[scoped] = active
            f.keychain.values[base] = unscoped

            if unscopedToken == "other" {
                await assertMigrationFails(defaults: defaults, switcher: f.switcher, expecting: .defaultIdentity)
                XCTAssertEqual(f.keychain.writeCount, 0)
                XCTAssertNil(f.keychain.currentUserValues[base])
                XCTAssertNil(try state(at: root)["oauthAccount"])
                XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
                XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
            } else {
                try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
                XCTAssertEqual(f.keychain.currentUserValues[base], active)
                XCTAssertEqual(try f.switcher.readClaudeSwitchState().identities, ["acct-a|org-a"])
                XCTAssertEqual(try text(rc), "")
                XCTAssertTrue(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
            }
            XCTAssertEqual(f.keychain.values[base], unscoped)
        }
    }

    @MainActor
    func testShellMigrationDefersWhileAnotherProcessOwnsTheSharedLoginLock() async throws {
        let fixture = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(fixture)
        let lock = try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: fixture.home)
        defer { withExtendedLifetime(lock) {} }

        await assertMigrationFails(defaults: defaults, switcher: fixture.switcher, expecting: .busy)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: fixture.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(fixture.keychain.writeCount, 0)
    }

    @MainActor
    func testShellMigrationPendingSwitchRetriesEvenWhenBothStoresAreLoggedOut() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let record = AccountSwitchJournal.Record(
            previousProfileID: "a", previousIdentity: "acct-a", selectedProfileID: "b", selectedIdentity: "acct-b",
            selectedCredentialFingerprint: AccountSwitchJournal.fingerprint("fixture"))
        try f.switcher.switchJournal.save(record, replacing: nil)
        await assertMigrationFails(defaults: defaults, switcher: f.switcher, expecting: .pendingSwitch)
        XCTAssertEqual(try f.switcher.switchJournal.load(), record)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        try f.switcher.switchJournal.clear(record)
        try f.switcher.mergeClaudeOAuthAccount(
            claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
        XCTAssertEqual(f.keychain.writeCount, 0)
    }

    @MainActor
    func testShellMigrationRetainsTheLaterExpiryWhenBothLoginsHaveRotated() async throws {
        for sourceIsNewer in [true, false] {
            let f = try makeFixture()
            let defaults = try shellMigrationDefaults()
            _ = try installOldClaudeFunction(f)
            try seedClaudeSharedHome(f, token: "base", account: claudeAccount("a"))
            let base = baseClaudeService()
            let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
            f.http.identities = ["new": "acct-a|org-a", "old": "acct-a|org-a"]
            let later = #"{"claudeAiOauth":{"accessToken":"new","expiresAt":4102444800000}}"#
            let earlier = #"{"claudeAiOauth":{"accessToken":"old","expiresAt":4070908800000}}"#
            f.keychain.currentUserValues[base] = sourceIsNewer ? earlier : later
            f.keychain.currentUserValues[scoped] = sourceIsNewer ? later : earlier
            try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
            XCTAssertEqual(
                ClaudeAuthStore.parseCredentials(try XCTUnwrap(f.keychain.currentUserValues[base]))?.claudeAiOauth?
                    .accessToken, "new")
            XCTAssertEqual(f.keychain.writeCount, sourceIsNewer ? 1 : 0)
            XCTAssertEqual(f.http.requests.map(\.timeout), [2, 2])
            _ = try await f.switcher.claudeProfile(for: "new")
            XCTAssertEqual(f.http.requests.last?.timeout, 10)
        }
    }

    @MainActor
    func testShellMigrationPreservesWrapperIfSourceChangesDuringWrite() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "first")
        try f.switcher.mergeClaudeOAuthAccount(
            claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))
        f.http.identities = ["first": "acct-a|org-a", "rotated": "acct-a|org-a"]
        let rotated = claudeCredential(token: "rotated")
        f.keychain.afterSharedWrite = { keychain, _ in keychain.currentUserValues[scoped] = rotated }
        await assertMigrationFails(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(f.keychain.currentUserValues[scoped], rotated)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        f.keychain.afterSharedWrite = nil
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
        XCTAssertEqual(
            try f.switcher.readClaudeSwitchState().credentials[0], try ClaudeAccountLoginCredentials.loginOnly(rotated))

    }

    @MainActor
    func testShellMigrationWriteFailureKeepsWrapperAndRetryRestoresLogin() async throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "active")
        try f.switcher.mergeClaudeOAuthAccount(
            claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))
        f.keychain.failingCurrentUserServices.insert(baseClaudeService())
        await assertMigrationFails(defaults: defaults, switcher: f.switcher)
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        f.keychain.failingCurrentUserServices.removeAll()
        try await ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
        XCTAssertEqual(try f.switcher.readClaudeSwitchState().identities, ["acct-a|org-a"])
    }
}

private struct MigrationShellRunner: ProcessRunning {
    let stdout: String

    func run(
        executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
    ) throws -> ProcessResult {
        ProcessResult(exitCode: 0, stdout: stdout, stderr: "")
    }
}
