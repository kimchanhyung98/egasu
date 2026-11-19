import XCTest
@testable import Egasu

@MainActor
final class AccountCredentialImporterTests: XCTestCase {
    func testClaudeFileCredentialImportsWithoutRelogin() async throws {
        let fixture = try makeFixture()
        try seedClaudeDefaultFiles(fixture, token: "token-a")

        let imported = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
        let profile = try XCTUnwrap(imported)

        XCTAssertEqual(profile.label, "default")
        XCTAssertEqual(profile.identityKey, "acct-a|org-a")
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), profile.id)
        let snapshot = try XCTUnwrap(fixture.vault.load(profile: profile))
        XCTAssertEqual(snapshot.credential, claudeCredential(token: "token-a"))
        let workspaceCredentials = try fixture.workspace
            .directory(family: "claude", profileID: profile.id)
            .appendingPathComponent(".credentials.json")
        XCTAssertEqual(posixPermissions(workspaceCredentials.path), 0o600)
        // Shared Runtime Home은 읽기만 — 쓰기 없음
        XCTAssertEqual(
            try String(
                contentsOf: fixture.home.appendingPathComponent(".claude/.credentials.json"),
                encoding: .utf8
            ),
            claudeCredential(token: "token-a")
        )
    }

    func testClaudeKeychainCredentialImportsWithoutRelogin() async throws {
        let fixture = try makeFixture()
        try seedClaudeDefaultState(fixture)
        fixture.keychain.currentUserValues[
            ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
        ] = claudeCredential(token: "token-kc")

        let imported = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
        let profile = try XCTUnwrap(imported)

        XCTAssertEqual(profile.identityKey, "acct-a|org-a")
        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: profile)).credential,
            claudeCredential(token: "token-kc")
        )
    }

    func testEmptyClaudeLoginsPermitImportFromTheNextPlainCredentialSource() async throws {
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
        for (current, legacy, expected) in [
            ("{}", claudeCredential(token: "legacy"), "legacy"),
            (#"{"claudeAiOauth":{}}"#, "{}", "file"),
            (#"{"mcpOAuth":{"fixture":{}}}"#, #"{"claudeAiOauth":{"accessToken":""}}"#, "file")
        ] {
            let fixture = try makeFixture()
            try seedClaudeDefaultFiles(fixture, token: "file")
            fixture.keychain.currentUserValues[service] = current
            fixture.keychain.values[service] = legacy

            let imported = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
            let profile = try XCTUnwrap(imported)
            let snapshot = try XCTUnwrap(fixture.vault.load(profile: profile))
            XCTAssertEqual(snapshot.credential, claudeCredential(token: expected))
            let home = fixture.home
            let probe = AccountSignInProbe(
                environment: FakeEnvironment([:]), keychain: fixture.keychain,
                homeDirectory: { home }
            )
            XCTAssertTrue(probe.state(for: profile, isSelected: true).isReady)
        }
    }

    func testMalformedClaudeKeychainStopsImportBeforeAnotherLoginIsUsed() async throws {
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())
        for (current, legacy) in [("invalid-json", claudeCredential(token: "legacy")), ("{}", "invalid-json")] {
            let fixture = try makeFixture()
            try seedClaudeDefaultFiles(fixture, token: "file")
            fixture.keychain.currentUserValues[service] = current
            fixture.keychain.values[service] = legacy

            do {
                _ = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
                XCTFail("Malformed Keychain data must stop the import.")
            } catch KeychainError.invalidData {
                XCTAssertTrue(fixture.store.profiles.isEmpty)
                XCTAssertEqual(fixture.keychain.currentUserValues[service], current)
                XCTAssertEqual(fixture.keychain.values[service], legacy)
                let credentialFile = fixture.home.appendingPathComponent(".claude/.credentials.json")
                XCTAssertEqual(try String(contentsOf: credentialFile, encoding: .utf8), claudeCredential(token: "file"))
            }
        }
    }

    func testCodexSharedHomeAuthImports() async throws {
        let fixture = try makeFixture()
        try write(codexAuth(accountID: "acct-c", token: "token-c"), to: fixture.home.appendingPathComponent(".codex/auth.json"))

        let imported = try await fixture.importer.importDefaultAccount(family: "codex", into: fixture.store)
        let profile = try XCTUnwrap(imported)

        XCTAssertEqual(profile.label, "default")
        XCTAssertEqual(profile.identityKey, "acct-c")
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), profile.id)
        let workspaceAuth = try fixture.workspace
            .directory(family: "codex", profileID: profile.id)
            .appendingPathComponent("auth.json")
        XCTAssertEqual(posixPermissions(workspaceAuth.path), 0o600)
    }

    func testCodexLegacyConfigHomeAuthImports() async throws {
        let fixture = try makeFixture()
        try write(
            codexAuth(accountID: "acct-l", token: "token-l"),
            to: fixture.home.appendingPathComponent(".config/codex/auth.json")
        )

        let imported = try await fixture.importer.importDefaultAccount(family: "codex", into: fixture.store)
        let profile = try XCTUnwrap(imported)

        XCTAssertEqual(profile.identityKey, "acct-l")
        // legacy home은 import source 전용 — 이동·삭제 없음
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: fixture.home.appendingPathComponent(".config/codex/auth.json").path
            )
        )
    }

    func testCodexImportSurfacesKeychainFailureOnlyWhenNoFileIdentifiesTheAccount() throws {
        let fixture = try makeFixture()
        let keychain = SwitchRecoveryKeychain()
        keychain.beforeRead = { _ in throw KeychainError.readFailed("PRIVATE_KEYCHAIN_REASON") }
        let importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment([:]), homeDirectory: fixture.home,
            workspace: fixture.workspace
        )

        XCTAssertThrowsError(try importer.readDefaultCredential(family: "codex")) { error in
            XCTAssertEqual(ErrorCategory.classify(error), .credentialAccess)
        }
        try write(
            codexAuth(accountID: "file-account", token: "file-token"),
            to: fixture.home.appendingPathComponent(".codex/auth.json"))
        XCTAssertEqual(try importer.readDefaultCredential(family: "codex")?.identityKey, "file-account")
    }

    func testCodexKeychainOnlyLoginImports() async throws {
        let fixture = try makeFixture()
        fixture.keychain.values[CodexAuthStore.keychainService] = codexAuth(accountID: "acct-k", token: "token-k")

        let imported = try await fixture.importer.importDefaultAccount(family: "codex", into: fixture.store)
        let profile = try XCTUnwrap(imported)

        XCTAssertEqual(profile.identityKey, "acct-k")
        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: profile)).credential,
            codexAuth(accountID: "acct-k", token: "token-k")
        )
    }

    func testNoDefaultSignInImportsNothing() async throws {
        let fixture = try makeFixture()

        let claude = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
        let codex = try await fixture.importer.importDefaultAccount(family: "codex", into: fixture.store)
        XCTAssertNil(claude)
        XCTAssertNil(codex)
        XCTAssertTrue(fixture.store.profiles.isEmpty)
    }

    func testCredentialWithoutIdentityRegistersNothing() async throws {
        let fixture = try makeFixture()
        // account를 지목하는 state 파일이 없는 credential 파일
        try write(
            claudeCredential(token: "token-x"),
            to: fixture.home.appendingPathComponent(".claude/.credentials.json")
        )

        do {
            _ = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
            XCTFail("A credential without an identity must not be registered")
        } catch {
            XCTAssertEqual(
                error as? AccountCredentialImporter.ImportError,
                .identityUnreadable(family: "claude")
            )
        }
        XCTAssertTrue(fixture.store.profiles.isEmpty)
    }

    func testDuplicateIdentityRegistersAsASeparateNamedProfile() throws {
        let fixture = try makeFixture()
        let alpha = try fixture.store.add(family: "codex", label: "alpha", identityKey: "acct-c")
        let credential = AccountCredentialImporter.ImportedCredential(
            entry: .init(credential: codexAuth(accountID: "acct-c", token: "token-c"), claudeOAuthAccount: nil),
            identityKey: "acct-c",
            label: nil
        )

        let beta = try fixture.importer.register(
            credential,
            family: "codex",
            label: "beta",
            id: "fixed-id",
            into: fixture.store
        )

        XCTAssertEqual(fixture.store.profiles(family: "codex").map(\.id), [alpha.id, beta.id])
        XCTAssertEqual(beta.label, "beta")
        XCTAssertEqual(beta.identityKey, alpha.identityKey)
        XCTAssertEqual(try fixture.vault.load(profile: beta), credential.entry)
        let workspaceAuth = try fixture.workspace
            .directory(family: "codex", profileID: beta.id)
            .appendingPathComponent("auth.json")
        XCTAssertEqual(
            try String(contentsOf: workspaceAuth, encoding: .utf8),
            credential.entry.credential
        )
    }

    func testRegistryFailureCleansUpTheStagedSnapshotAndWorkspace() throws {
        let fixture = try makeFixture()
        for index in 0..<AccountProfilesStore.maxProfilesPerFamily {
            try fixture.store.add(family: "codex", label: "Account \(index)", identityKey: "acct-\(index)")
        }
        let credential = AccountCredentialImporter.ImportedCredential(
            entry: .init(credential: codexAuth(accountID: "acct-over", token: "token"), claudeOAuthAccount: nil),
            identityKey: "acct-over",
            label: nil
        )

        XCTAssertThrowsError(
            try fixture.importer.register(credential, family: "codex", label: "Over", id: "fixed-id", into: fixture.store)
        ) { error in
            XCTAssertEqual(
                error as? AccountProfileError,
                .accountLimitReached(AccountProfilesStore.maxProfilesPerFamily)
            )
        }
        XCTAssertNil(try fixture.vault.load(family: "codex", profileID: "fixed-id"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try fixture.workspace.directory(family: "codex", profileID: "fixed-id")).path
            )
        )
    }

    func testWorkspaceCredentialReadsACompletedScopedLogin() throws {
        let fixture = try makeFixture()
        let workspaceHome = try fixture.workspace.prepare(family: "claude", profileID: "profile-w")
        // scoped `claude auth login`은 CLAUDE_CONFIG_DIR 리터럴(workspace 경로)로 해시된 keychain item에 credential 기록
        fixture.keychain.currentUserValues[
            ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: workspaceHome.path,
                environment: FakeEnvironment([:])
            )
        ] = claudeCredential(token: "token-w")
        try write(
            #"{"oauthAccount":{"accountUuid":"acct-w","emailAddress":"w@example.com","organizationUuid":"org-w"}}"#,
            to: workspaceHome.appendingPathComponent(".claude.json")
        )

        let credential = try XCTUnwrap(
            fixture.importer.readWorkspaceCredential(family: "claude", profileID: "profile-w")
        )

        XCTAssertEqual(credential.identityKey, "acct-w|org-w")
        XCTAssertEqual(credential.entry.credential, claudeCredential(token: "token-w"))
    }

    func testWorkspaceCleanupDeletesScopedKeychainBeforeRejectingASymlinkedDirectory() throws {
        let fixture = try makeFixture()
        let workspaceHome = try fixture.workspace.prepare(family: "claude", profileID: "profile-w")
        let service = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: workspaceHome.path, environment: FakeEnvironment([:])
        )
        fixture.keychain.currentUserValues[service] = claudeCredential(token: "workspace-token")
        fixture.keychain.currentUserValues["unrelated-service"] = "keep"
        let outside = fixture.home.appendingPathComponent("outside")
        let protectedFile = outside.appendingPathComponent(".credentials.json")
        try write("keep", to: protectedFile)
        try FileManager.default.removeItem(at: workspaceHome)
        try FileManager.default.createSymbolicLink(at: workspaceHome, withDestinationURL: outside)

        XCTAssertThrowsError(try fixture.importer.removeSignInWorkspace(family: "claude", profileID: "profile-w")) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }

        XCTAssertNil(fixture.keychain.currentUserValues[service])
        XCTAssertEqual(fixture.keychain.currentUserValues["unrelated-service"], "keep")
        XCTAssertEqual(try String(contentsOf: protectedFile, encoding: .utf8), "keep")
    }

    func testRemovalKeepsTheSnapshotAndProfileWhenWorkspaceDeletionFails() throws {
        let fixture = try makeFixture()
        let credential = AccountCredentialImporter.ImportedCredential(
            entry: .init(
                credential: codexAuth(accountID: "acct-r", token: "token-r"),
                claudeOAuthAccount: nil
            ),
            identityKey: "acct-r",
            label: nil
        )
        let profile = try fixture.importer.register(
            credential,
            family: "codex",
            label: "Removable",
            id: "profile-r",
            into: fixture.store
        )
        let familyDirectory = fixture.workspace.baseDirectory.appendingPathComponent("codex")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o500],
            ofItemAtPath: familyDirectory.path
        )
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: familyDirectory.path
            )
        }

        XCTAssertThrowsError(try fixture.importer.removeAccount(profile, from: fixture.store))
        XCTAssertNotNil(try fixture.vault.load(profile: profile))
        XCTAssertNotNil(fixture.store.profile(id: profile.id))
    }

    // MARK: - Fixtures

    private struct Fixture {
        let home: URL
        let keychain: ServiceKeychain
        let workspace: AccountSignInWorkspace
        let importer: AccountCredentialImporter
        let store: AccountProfilesStore
        let vault: AccountCredentialVault
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgasuTests.AccountCredentialImporter.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.resolvingSymlinksInPath().standardizedFileURL
        let suiteName = "EgasuTests.AccountCredentialImporter.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: suiteName) }
        let keychain = ServiceKeychain()
        let workspace = AccountSignInWorkspace(
            baseDirectory: home.appendingPathComponent("AppSupport/egasu/AccountSignIn")
        )
        let http = ClaudeReconciliationHTTPClient()
        http.identities = [
            "token-a": "acct-a|org-a", "token-kc": "acct-a|org-a",
            "legacy": "acct-a|org-a", "file": "acct-a|org-a"
        ]
        let importer = AccountCredentialImporter(
            keychain: keychain,
            environment: FakeEnvironment([:]),
            homeDirectory: home,
            workspace: workspace,
            httpClient: http
        )
        return Fixture(
            home: home,
            keychain: keychain,
            workspace: workspace,
            importer: importer,
            store: AccountProfilesStore(defaults: defaults),
            vault: AccountCredentialVault(keychain: keychain)
        )
    }

    private func claudeCredential(token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh"}}"#
    }

    private func codexAuth(accountID: String, token: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }

    private func seedClaudeDefaultFiles(_ fixture: Fixture, token: String) throws {
        try write(
            claudeCredential(token: token),
            to: fixture.home.appendingPathComponent(".claude/.credentials.json")
        )
        try seedClaudeDefaultState(fixture)
    }

    private func seedClaudeDefaultState(_ fixture: Fixture) throws {
        try write(
            #"{"hasCompletedOnboarding":true,"oauthAccount":{"accountUuid":"acct-a","emailAddress":"a@example.com","organizationName":"Org A","organizationUuid":"org-a"}}"#,
            to: fixture.home.appendingPathComponent(".claude.json")
        )
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
    }

    private func posixPermissions(_ path: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
    }
}
