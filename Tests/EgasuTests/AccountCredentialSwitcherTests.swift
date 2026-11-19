import XCTest
@testable import Egasu

final class AccountCredentialSwitcherTests: XCTestCase {
    // MARK: - Claude

    func testMalformedWorkspaceCredentialDoesNotChangeKeychainOrAccount() throws {
        let fixture = try makeFixture()
        let account = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let directory = try fixture.workspace.prepare(family: "claude", profileID: account.id)
        let credentialFile = directory.appendingPathComponent(".credentials.json")
        let accountFile = directory.appendingPathComponent(".claude.json")
        try Data("{".utf8).write(to: credentialFile)
        try Data(#"{"oauthAccount":{"accountUuid":"old"}}"#.utf8).write(to: accountFile)
        let service = scopedClaudeService(home: directory.path)
        let previous = claudeCredential(token: "token-old")
        fixture.keychain.currentUserValues[service] = previous

        XCTAssertThrowsError(
            try fixture.switcher.writeWorkspaceAuthentication(
                .init(credential: claudeCredential(token: "token-a"), claudeOAuthAccount: claudeAccount("a")),
                for: account))

        XCTAssertEqual(fixture.keychain.currentUserValues[service], previous)
        XCTAssertEqual(try text(credentialFile), "{")
        XCTAssertEqual(try text(accountFile), #"{"oauthAccount":{"accountUuid":"old"}}"#)
    }

    func testSharedClaudeStateAcceptsANullAccountAndRejectsMalformedAccounts() throws {
        let fixture = try makeFixture()
        let url = fixture.home.appendingPathComponent(".claude.json")
        for contents in ["{}", #"{"oauthAccount":null}"#] {
            try Data(contents.utf8).write(to: url)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState().accounts, [nil])
        }
        for contents in [#"{"oauthAccount":"invalid"}"#, #"{"oauthAccount":[]}"#] {
            try Data(contents.utf8).write(to: url)
            XCTAssertThrowsError(try fixture.switcher.readClaudeSwitchState()) { error in
                XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .invalidClaudeState(url))
            }
        }
    }

    func testClaudeSwitchReplacesAuthenticationAndPreservesSharedState() async throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        let sharedHome = fixture.home.appendingPathComponent(".claude")
        let sessionFile = sharedHome.appendingPathComponent("projects/session.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("session-data".utf8).write(to: sessionFile)
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(
            comparedTo: fixture.switcher.loadSnapshot(for: personal), allowInteraction: true
        )
        try fixture.switcher.switchAuthentication(to: work, from: personal, verifiedClaudeDeparture: verified)

        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent(".credentials.json")),
            claudeCredential(token: "token-a")
        )
        XCTAssertEqual(
            fixture.keychain.currentUserValues[baseClaudeService()],
            claudeCredential(token: "token-b")
        )
        XCTAssertNil(fixture.keychain.currentUserValues[scopedClaudeService(home: sharedHome.path)])
        let defaultState = try state(at: fixture.home.appendingPathComponent(".claude.json"))
        XCTAssertEqual(defaultState["memory"] as? String, "keep")
        XCTAssertEqual(defaultState["hasCompletedOnboarding"] as? Bool, true)
        XCTAssertEqual((defaultState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-b")
        let localState = try state(at: sharedHome.appendingPathComponent(".claude.json"))
        XCTAssertEqual((localState["projects"] as? [String: Any])?.count, 1)
        XCTAssertEqual((localState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-a")
        XCTAssertEqual(try text(sessionFile), "session-data")

        // 떠나는 account의 live credential이 snapshot·workspace에 보존
        let preserved = try XCTUnwrap(fixture.vault.load(profile: personal))
        XCTAssertEqual(preserved.credential, claudeCredential(token: "token-a"))
        let personalWorkspace = try fixture.workspace.directory(family: "claude", profileID: personal.id)
        XCTAssertEqual(
            try text(personalWorkspace.appendingPathComponent(".credentials.json")),
            claudeCredential(token: "token-a")
        )
    }

    func testClaudeRoundTripRestoresTheFirstAccountWithoutRelogin() async throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(
            comparedTo: fixture.switcher.loadSnapshot(for: personal), allowInteraction: true
        )
        try fixture.switcher.switchAuthentication(to: work, from: personal, verifiedClaudeDeparture: verified)
        try fixture.switcher.switchAuthentication(to: personal, from: work)

        XCTAssertEqual(fixture.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "token-a"))
        let defaultState = try state(at: fixture.home.appendingPathComponent(".claude.json"))
        XCTAssertEqual((defaultState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-a")
        // 중간에 활성이던 account의 credential 생존
        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: work)).credential,
            claudeCredential(token: "token-b")
        )
    }

    func testClaudeSwitchPreservesRotatedCredentialForTheActiveAccount() async throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        // snapshot은 stale, shared home은 동일 account의 더 새 token으로 rotate된 상태
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-a-old"), claudeOAuthAccount: claudeAccount("a")),
            profile: personal
        )
        try seedClaudeSharedHome(fixture, token: "token-a-new", account: claudeAccount("a"))
        fixture.keychain.currentUserValues[
            scopedClaudeService(home: fixture.home.appendingPathComponent(".claude").path)] =
            claudeCredential(token: "token-a-old")
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(
            comparedTo: fixture.switcher.loadSnapshot(for: personal), allowInteraction: true
        )
        try fixture.switcher.switchAuthentication(to: work, from: personal, verifiedClaudeDeparture: verified)

        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: personal)).credential,
            claudeCredential(token: "token-a-new")
        )
        let workspaceCredentials = try fixture.workspace
            .directory(family: "claude", profileID: personal.id)
            .appendingPathComponent(".credentials.json")
        XCTAssertEqual(try text(workspaceCredentials), claudeCredential(token: "token-a-new"))

        try fixture.switcher.switchAuthentication(to: personal, from: work)
        XCTAssertEqual(fixture.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "token-a-new"))
        XCTAssertEqual(
            fixture.keychain.currentUserValues[
                scopedClaudeService(home: fixture.home.appendingPathComponent(".claude").path)],
            claudeCredential(token: "token-a-old")
        )
    }

    func testSharedIdentityMismatchSkipsPreservationAndKeepsTheProfileSnapshot() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-a-old"), claudeOAuthAccount: claudeAccount("a")),
            profile: personal
        )
        // egasu 외부에서 shared home이 제3의 account로 로그인된 상태
        try seedClaudeSharedHome(fixture, token: "token-c", account: claudeAccount("c"))
        fixture.keychain.currentUserValues[
            scopedClaudeService(home: fixture.home.appendingPathComponent(".claude").path)] =
            claudeCredential(token: "token-a-old")
        try Data("{\"oauthAccount\":\(claudeAccount("a"))}".utf8)
            .write(to: fixture.home.appendingPathComponent(".claude/.claude.json"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        // 외부 credential이 떠나는 profile의 snapshot에 유입 금지
        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: personal)).credential,
            claudeCredential(token: "token-a-old")
        )
        XCTAssertEqual(fixture.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "token-b"))
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-c")
        )
    }

    func testMissingSnapshotFailsWithoutTouchingTheSharedHome() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: personal)) { error in
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .missingSnapshot("Work"))
        }
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a")
        )
    }

    func testCorruptSnapshotRequestsSignInWithoutTouchingTheSharedHome() throws {
        let fixture = try makeFixture()
        let work = profile(id: "corrupt", family: "codex", label: "Work", identityKey: "work")
        let service = AccountCredentialVault.service(family: work.family, profileID: work.id)
        fixture.keychain.currentUserValues[service] = "invalid-json"

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: nil)) { error in
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .missingSnapshot("Work"))
        }
        XCTAssertEqual(fixture.keychain.writeCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".codex").path))
    }

    func testSnapshotIdentityMismatchFailsWithoutTouchingTheSharedHome() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        // snapshot 부패: 다른 account의 credential 보유
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-c"), claudeOAuthAccount: claudeAccount("c")),
            profile: work
        )

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: personal)) { error in
            XCTAssertEqual(error as? AccountCredentialSwitcher.Error, .snapshotIdentityMismatch("Work"))
        }
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a")
        )
    }

    func testReselectingTheActiveProfileMakesNoWrites() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        let credentialsBefore = try text(fixture.home.appendingPathComponent(".claude/.credentials.json"))
        fixture.keychain.writeCount = 0

        try fixture.switcher.switchAuthentication(to: personal, from: personal)

        XCTAssertEqual(fixture.keychain.writeCount, 0)
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            credentialsBefore
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: (try fixture.workspace.directory(family: "claude", profileID: personal.id)).path
            )
        )
    }

    func testKeychainWriteFailurePreservesInactiveCredentialsAndAccountState() async throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "profile-b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-a"), claudeOAuthAccount: claudeAccount("a")),
            profile: personal
        )
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work
        )
        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(
            comparedTo: fixture.switcher.loadSnapshot(for: personal), allowInteraction: true
        )
        fixture.keychain.failingCurrentUserServices = [baseClaudeService()]

        XCTAssertThrowsError(
            try fixture.switcher.switchAuthentication(
                to: work, from: personal, verifiedClaudeDeparture: verified)
        ) { error in
            XCTAssertTrue(error is SwitcherTestKeychain.WriteFailure)
        }

        XCTAssertNil(
            fixture.keychain.currentUserValues[
                scopedClaudeService(home: fixture.home.appendingPathComponent(".claude").path)])
        XCTAssertEqual(fixture.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "token-a"))
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".claude/.credentials.json")),
            claudeCredential(token: "token-a")
        )
        let defaultState = try state(at: fixture.home.appendingPathComponent(".claude.json"))
        XCTAssertEqual((defaultState["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-a")
    }

    func testFailedFirstSwitchRollsBackNewStateAndKeepsConcurrentSettings() throws {
        for addsSettings in [false, true] {
            let fixture = try makeFixture()
            let stateURL = fixture.home.appendingPathComponent(".claude.json")
            let target = profile(id: "b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
            try fixture.vault.save(
                .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
                profile: target)
            fixture.keychain.failingCurrentUserServices = [baseClaudeService()]
            fixture.keychain.onRejectedWrite = {
                var state = try self.state(at: stateURL)
                XCTAssertEqual((state["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-b")
                if addsSettings {
                    state["theme"] = "dark"
                    try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
                }
            }

            XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: target, from: nil)) { error in
                XCTAssertTrue(error is SwitcherTestKeychain.WriteFailure)
            }

            XCTAssertNil(fixture.keychain.currentUserValues[baseClaudeService()])
            if addsSettings {
                let state = try state(at: stateURL)
                XCTAssertEqual(state["theme"] as? String, "dark")
                XCTAssertNil(state["oauthAccount"])
            } else {
                XCTAssertFalse(FileManager.default.fileExists(atPath: stateURL.path))
            }
        }
    }

    func testLegacyWrapperKeepsRotatedScopedLoginAcrossRoundTrip() async throws {
        let fixture = try makeFixture()
        let personal = profile(id: "a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        let sharedHome = fixture.home.appendingPathComponent(".claude")
        let service = scopedClaudeService(home: sharedHome.path)
        try Data(legacyClaudeZshBlock(home: fixture.home).utf8).write(to: fixture.home.appendingPathComponent(".zshrc"))
        try seedClaudeSharedHome(fixture, token: "token-a-old", account: claudeAccount("a"))
        let rootState = fixture.home.appendingPathComponent(".claude.json")
        try Data("{\"oauthAccount\":\(claudeAccount("c"))}".utf8).write(to: rootState)
        fixture.keychain.currentUserValues[service] = claudeCredential(token: "token-a-new")
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-a-old"), claudeOAuthAccount: claudeAccount("a")),
            profile: personal)
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work)

        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(
            comparedTo: fixture.switcher.loadSnapshot(for: personal), allowInteraction: true)
        try fixture.switcher.switchAuthentication(to: work, from: personal, verifiedClaudeDeparture: verified)
        XCTAssertEqual(fixture.keychain.currentUserValues[service], claudeCredential(token: "token-b"))
        let nested = try state(at: sharedHome.appendingPathComponent(".claude.json"))
        XCTAssertEqual((nested["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-b")
        XCTAssertEqual(try fixture.vault.load(profile: personal)?.credential, claudeCredential(token: "token-a-new"))
        try fixture.switcher.switchAuthentication(to: personal, from: work)

        XCTAssertEqual(fixture.keychain.currentUserValues[service], claudeCredential(token: "token-a-new"))
        XCTAssertEqual(fixture.keychain.currentUserValues[baseClaudeService()], claudeCredential(token: "token-a-old"))
        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent(".credentials.json")), claudeCredential(token: "token-a-old"))
        XCTAssertEqual(
            (try state(at: rootState)["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-c")
    }

    func testFileOnlyLoginSwitchKeepsKeychainEmptyAndNestedStateUnchanged() throws {
        let fixture = try makeFixture()
        let work = profile(id: "b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        fixture.keychain.currentUserValues.removeValue(forKey: baseClaudeService())
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work)

        try fixture.switcher.switchAuthentication(to: work, from: nil)

        let sharedHome = fixture.home.appendingPathComponent(".claude")
        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent(".credentials.json")), claudeCredential(token: "token-b"))
        XCTAssertNil(fixture.keychain.currentUserValues[baseClaudeService()])
        XCTAssertNil(fixture.keychain.currentUserValues[scopedClaudeService(home: sharedHome.path)])
        let nested = try state(at: sharedHome.appendingPathComponent(".claude.json"))
        XCTAssertEqual((nested["oauthAccount"] as? [String: Any])?["accountUuid"] as? String, "acct-a")
    }

    func testSwitchKeepsMCPAndOtherCredentialFieldsWithTheirSource() async throws {
        let fixture = try makeFixture()
        let personal = profile(id: "a", family: "claude", label: "Personal", identityKey: "acct-a|org-a")
        let work = profile(id: "b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        let service = baseClaudeService()
        fixture.keychain.currentUserValues[service] = try credentialWithExtras(token: "token-a", marker: "shared")
        try fixture.vault.save(
            .init(
                credential: try credentialWithExtras(token: "token-b", marker: "target"),
                claudeOAuthAccount: claudeAccount("b")),
            profile: work)

        let verified = try await fixture.switcher.readSharedClaudeExternalAuthentication(
            comparedTo: nil, allowInteraction: true)
        try fixture.switcher.switchAuthentication(to: work, from: personal, verifiedClaudeDeparture: verified)

        let shared = try XCTUnwrap(fixture.keychain.currentUserValues[service])
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(shared.utf8)) as? [String: Any])
        XCTAssertEqual((fields["mcpOAuth"] as? [String: String])?["server"], "shared")
        XCTAssertEqual(fields["unknownField"] as? String, "shared")
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(shared)?.claudeAiOauth?.accessToken, "token-b")
        XCTAssertEqual(try fixture.vault.load(profile: personal)?.credential, claudeCredential(token: "token-a"))
        let directory = try fixture.workspace.directory(family: "claude", profileID: personal.id)
        XCTAssertEqual(
            try text(directory.appendingPathComponent(".credentials.json")), claudeCredential(token: "token-a"))
        XCTAssertEqual(
            fixture.keychain.currentUserValues[scopedClaudeService(home: directory.path)],
            claudeCredential(token: "token-a"))
    }

    func testFailedSwitchDoesNotRollBackACredentialRotatedByTheCLI() throws {
        let fixture = try makeFixture()
        let work = profile(id: "b", family: "claude", label: "Work", identityKey: "acct-b|org-b")
        try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
        try fixture.vault.save(
            .init(credential: claudeCredential(token: "token-b"), claudeOAuthAccount: claudeAccount("b")),
            profile: work)
        let service = baseClaudeService()
        let rotated = claudeCredential(token: "token-a-new")
        fixture.keychain.afterSharedWrite = { keychain, destination in
            guard destination == service else { return }
            keychain.afterSharedWrite = nil
            keychain.currentUserValues[destination] = rotated
            throw SwitcherTestKeychain.WriteFailure()
        }

        XCTAssertThrowsError(try fixture.switcher.switchAuthentication(to: work, from: nil))
        XCTAssertEqual(fixture.keychain.currentUserValues[service], rotated)
        let sharedHome = fixture.home.appendingPathComponent(".claude")
        XCTAssertNil(fixture.keychain.currentUserValues[scopedClaudeService(home: sharedHome.path)])
        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent(".credentials.json")), claudeCredential(token: "token-a"))
    }

    // MARK: - Codex

    func testCodexSwitchReplacesOnlyAuthJSONAndPreservesSharedConfig() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "codex", label: "Personal", identityKey: "acct-a")
        let work = profile(id: "profile-b", family: "codex", label: "Work", identityKey: "acct-b")
        let sharedHome = fixture.home.appendingPathComponent(".codex")
        try seedCodexSharedHome(fixture, accountID: "acct-a", token: "token-a")
        try Data("model = \"o3\"".utf8).write(to: sharedHome.appendingPathComponent("config.toml"))
        let sessionFile = sharedHome.appendingPathComponent("sessions/rollout.jsonl")
        try FileManager.default.createDirectory(
            at: sessionFile.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data("rollout-data".utf8).write(to: sessionFile)
        try fixture.vault.save(
            .init(credential: codexAuth(accountID: "acct-b", token: "token-b"), claudeOAuthAccount: nil),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        XCTAssertEqual(
            try text(sharedHome.appendingPathComponent("auth.json")),
            codexAuth(accountID: "acct-b", token: "token-b")
        )
        XCTAssertEqual(try text(sharedHome.appendingPathComponent("config.toml")), "model = \"o3\"")
        XCTAssertEqual(try text(sessionFile), "rollout-data")

        let preserved = try XCTUnwrap(fixture.vault.load(profile: personal))
        XCTAssertEqual(preserved.credential, codexAuth(accountID: "acct-a", token: "token-a"))
        let workspaceAuth = try fixture.workspace
            .directory(family: "codex", profileID: personal.id)
            .appendingPathComponent("auth.json")
        XCTAssertEqual(try text(workspaceAuth), codexAuth(accountID: "acct-a", token: "token-a"))
    }

    func testCodexIdentityMismatchNeverOverwritesTheLeavingSnapshot() throws {
        let fixture = try makeFixture()
        let personal = profile(id: "profile-a", family: "codex", label: "Personal", identityKey: "acct-a")
        let work = profile(id: "profile-b", family: "codex", label: "Work", identityKey: "acct-b")
        try fixture.vault.save(
            .init(credential: codexAuth(accountID: "acct-a", token: "token-a-old"), claudeOAuthAccount: nil),
            profile: personal
        )
        try seedCodexSharedHome(fixture, accountID: "acct-c", token: "token-c")
        try fixture.vault.save(
            .init(credential: codexAuth(accountID: "acct-b", token: "token-b"), claudeOAuthAccount: nil),
            profile: work
        )

        try fixture.switcher.switchAuthentication(to: work, from: personal)

        XCTAssertEqual(
            try XCTUnwrap(fixture.vault.load(profile: personal)).credential,
            codexAuth(accountID: "acct-a", token: "token-a-old")
        )
        XCTAssertEqual(
            try text(fixture.home.appendingPathComponent(".codex/auth.json")),
            codexAuth(accountID: "acct-b", token: "token-b")
        )
    }

    @MainActor
    func testAccountSelectionSwitchPreservesShellFilesAndDanglingLinksWithoutCreatingMissingFiles() async throws {
        for family in ["claude", "codex"] {
            for shellState in ["existing", "missing", "dangling"] {
                let fixture = try makeFixture()
                let suite = "EgasuTests.ShellFilePreservation.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
                let store = AccountProfilesStore(defaults: defaults)
                let previousIdentity = family == "claude" ? "acct-a|org-a" : "acct-a"
                let selectedIdentity = family == "claude" ? "acct-b|org-b" : "acct-b"
                _ = try store.add(family: family, label: "Personal", identityKey: previousIdentity, id: "profile-a")
                let selected = try store.add(
                    family: family, label: "Work", identityKey: selectedIdentity, id: "profile-b")
                let credential: String
                if family == "claude" {
                    try seedClaudeSharedHome(fixture, token: "token-a", account: claudeAccount("a"))
                    credential = claudeCredential(token: "token-b")
                } else {
                    try seedCodexSharedHome(fixture, accountID: "acct-a", token: "token-a")
                    credential = codexAuth(accountID: "acct-b", token: "token-b")
                }
                try fixture.vault.save(
                    .init(
                        credential: credential,
                        claudeOAuthAccount: family == "claude" ? claudeAccount("b") : nil), profile: selected)
                let shellFiles = [".zshrc", ".config/fish/config.fish"].map { fixture.home.appendingPathComponent($0) }
                let contents = Data("# Existing shell settings\r\nalias ll='ls -l'\n".utf8)
                for (index, file) in shellFiles.enumerated() where shellState != "missing" {
                    try FileManager.default.createDirectory(
                        at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if shellState == "existing" {
                        try contents.write(to: file)
                    } else {
                        try FileManager.default.createSymbolicLink(
                            at: file, withDestinationURL: fixture.home.appendingPathComponent("missing-target-\(index)")
                        )
                    }
                }

                try await AccountSelectionSwitcher(switcher: fixture.switcher).switchAuthentication(
                    to: selected, in: store)

                XCTAssertEqual(store.preferredProfileID(family: family), selected.id)
                XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: family)?.credential, credential)
                for (index, file) in shellFiles.enumerated() {
                    if shellState == "existing" {
                        XCTAssertEqual(try Data(contentsOf: file), contents)
                    } else if shellState == "dangling" {
                        let destination = fixture.home.appendingPathComponent("missing-target-\(index)").path
                        XCTAssertEqual(
                            try FileManager.default.destinationOfSymbolicLink(atPath: file.path), destination)
                        XCTAssertFalse(FileManager.default.fileExists(atPath: destination))
                    } else {
                        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
                        XCTAssertThrowsError(try FileManager.default.destinationOfSymbolicLink(atPath: file.path))
                    }
                }
                if shellState == "missing" {
                    XCTAssertFalse(
                        FileManager.default.fileExists(atPath: fixture.home.appendingPathComponent(".config").path))
                }
            }
        }
    }
}
