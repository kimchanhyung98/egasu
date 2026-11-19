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

    @discardableResult
    private func installOldClaudeFunction(_ fixture: Fixture) throws -> URL {
        let rc = fixture.home.appendingPathComponent(".zshrc")
        try Data(legacyClaudeZshBlock(home: fixture.home).utf8).write(to: rc)
        return rc
    }

    @MainActor
    func testShellMigrationTransfersLoginBeforeRemovingBothFunctionsAndSkipsCompletedRun() throws {
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

        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)

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
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(f.keychain.writeCount, writes)
    }

    @MainActor
    func testShellMigrationFreshInstallSkipsCredentialsAndAddsNoFunction() throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        f.keychain.onSharedRead = { _ in XCTFail("A fresh installation must not read Claude credentials") }
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertTrue(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.home.appendingPathComponent(".zshrc").path))
        XCTAssertEqual(f.keychain.writeCount, 0)
    }

    @MainActor
    func testShellMigrationRespectsKeychainDenialAndRetriesOnTheNextLaunch() throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        f.keychain.onSharedRead = { allowsPrompt in
            XCTAssertTrue(allowsPrompt)
            throw KeychainError.readFailed("fixture denial")
        }
        XCTAssertThrowsError(try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        f.keychain.onSharedRead = nil
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
    }

    @MainActor
    func testShellMigrationConflictPreservesBothLoginsAndRetriesAfterResolution() throws {
        let f = try makeFixture()
        let rc = try installOldClaudeFunction(f)
        let defaults = try shellMigrationDefaults()
        try seedClaudeSharedHome(f, token: "different", account: claudeAccount("b"))
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "active")
        let accountState = f.home.appendingPathComponent(".claude/.claude.json")
        try Data("{\"oauthAccount\":\(claudeAccount("a"))}".utf8).write(to: accountState)
        let saved = f.keychain.currentUserValues

        XCTAssertThrowsError(try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)) {
            XCTAssertEqual($0 as? ClaudeShellLoginMigrationError, .conflict)
        }
        XCTAssertEqual(f.keychain.currentUserValues, saved)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))

        try Data("{\"oauthAccount\":\(claudeAccount("a"))}".utf8).write(
            to: f.home.appendingPathComponent(".claude.json"))
        f.keychain.currentUserValues[baseClaudeService()] = claudeCredential(token: "active")
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(f.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "active"))
        XCTAssertEqual(try text(rc), "")
    }

    @MainActor
    func testShellMigrationOnlyCopiesAnIdenticalUnscopedDefaultLogin() throws {
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
                XCTAssertThrowsError(
                    try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
                ) {
                    XCTAssertEqual($0 as? ClaudeShellLoginMigrationError, .defaultIdentity)
                }
                XCTAssertEqual(f.keychain.writeCount, 0)
                XCTAssertNil(f.keychain.currentUserValues[base])
                XCTAssertNil(try state(at: root)["oauthAccount"])
                XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
                XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
            } else {
                try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
                XCTAssertEqual(f.keychain.currentUserValues[base], active)
                XCTAssertEqual(try f.switcher.readClaudeSwitchState().identities, ["acct-a|org-a"])
                XCTAssertEqual(try text(rc), "")
                XCTAssertTrue(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
            }
            XCTAssertEqual(f.keychain.values[base], unscoped)
        }
    }

    @MainActor
    func testShellMigrationPendingSwitchRetriesEvenWhenBothStoresAreLoggedOut() throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let record = AccountSwitchJournal.Record(
            previousProfileID: "a", previousIdentity: "acct-a", selectedProfileID: "b", selectedIdentity: "acct-b",
            selectedCredentialFingerprint: AccountSwitchJournal.fingerprint("fixture"))
        try f.switcher.switchJournal.save(record, replacing: nil)
        XCTAssertThrowsError(try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)) {
            XCTAssertEqual($0 as? ClaudeShellLoginMigrationError, .pendingSwitch)
        }
        XCTAssertEqual(try f.switcher.switchJournal.load(), record)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        try f.switcher.switchJournal.clear(record)
        try f.switcher.mergeClaudeOAuthAccount(
            claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
        XCTAssertEqual(f.keychain.writeCount, 0)
    }

    @MainActor
    func testShellMigrationRetainsTheLaterExpiryWhenBothLoginsHaveRotated() throws {
        for sourceIsNewer in [true, false] {
            let f = try makeFixture()
            let defaults = try shellMigrationDefaults()
            _ = try installOldClaudeFunction(f)
            try seedClaudeSharedHome(f, token: "base", account: claudeAccount("a"))
            let base = baseClaudeService()
            let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
            let later = #"{"claudeAiOauth":{"accessToken":"new","expiresAt":4102444800000}}"#
            let earlier = #"{"claudeAiOauth":{"accessToken":"old","expiresAt":4070908800000}}"#
            f.keychain.currentUserValues[base] = sourceIsNewer ? earlier : later
            f.keychain.currentUserValues[scoped] = sourceIsNewer ? later : earlier
            try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
            XCTAssertEqual(
                ClaudeAuthStore.parseCredentials(try XCTUnwrap(f.keychain.currentUserValues[base]))?.claudeAiOauth?
                    .accessToken, "new")
            XCTAssertEqual(f.keychain.writeCount, sourceIsNewer ? 1 : 0)
        }
    }

    @MainActor
    func testShellMigrationPreservesWrapperIfSourceChangesDuringWrite() throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "first")
        try f.switcher.mergeClaudeOAuthAccount(
            claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))
        let rotated = claudeCredential(token: "rotated")
        f.keychain.afterSharedWrite = { keychain, _ in keychain.currentUserValues[scoped] = rotated }
        XCTAssertThrowsError(try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher))
        XCTAssertEqual(f.keychain.currentUserValues[scoped], rotated)
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        f.keychain.afterSharedWrite = nil
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
        XCTAssertEqual(
            try f.switcher.readClaudeSwitchState().credentials[0], try ClaudeAccountLoginCredentials.loginOnly(rotated))

    }

    @MainActor
    func testShellMigrationWriteFailureKeepsWrapperAndRetryRestoresLogin() throws {
        let f = try makeFixture()
        let defaults = try shellMigrationDefaults()
        let rc = try installOldClaudeFunction(f)
        let scoped = scopedClaudeService(home: f.home.appendingPathComponent(".claude").path)
        f.keychain.currentUserValues[scoped] = claudeCredential(token: "active")
        try f.switcher.mergeClaudeOAuthAccount(
            claudeAccount("a"), at: f.home.appendingPathComponent(".claude/.claude.json"))
        f.keychain.failingCurrentUserServices.insert(baseClaudeService())
        XCTAssertThrowsError(try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher))
        XCTAssertFalse(defaults.bool(forKey: ClaudeLegacyShellMigration.completedKey))
        XCTAssertEqual(try text(rc), legacyClaudeZshBlock(home: f.home))
        f.keychain.failingCurrentUserServices.removeAll()
        try ClaudeLegacyShellMigration.runIfNeeded(defaults: defaults, switcher: f.switcher)
        XCTAssertEqual(try text(rc), "")
        XCTAssertEqual(try f.switcher.readClaudeSwitchState().identities, ["acct-a|org-a"])
    }
}
