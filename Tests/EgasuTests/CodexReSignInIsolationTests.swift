import Foundation
import XCTest
@testable import Egasu

@MainActor
final class CodexReSignInIsolationTests: XCTestCase {
    private var root: URL!
    private var workspace: AccountSignInWorkspace!
    private var switcher: AccountCredentialSwitcher!
    private var importer: AccountCredentialImporter!
    private var defaults: UserDefaults!
    private var suite: String!
    private var store: AccountProfilesStore!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        let keychain = ServiceKeychain()
        switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        suite = "CodexReSignInIsolationTests.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        store = AccountProfilesStore(defaults: defaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: root)
    }

    func testSwitchingAwayCannotReplaceACompletedLoginWithThePreviousAccount() async throws {
        let previous = entry(token: "previous-company", account: "company-account")
        let personal = try addProfile(label: "personal", entry: previous)
        let company = try addProfile(label: "company", entry: entry(token: "other-company", account: "company-account"))
        try switcher.applySharedAuthentication(previous, family: "codex")
        let signIn = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)
        let fresh = entry(token: "fresh-personal", account: "personal-account")

        let code = try await runLogin(home: signIn.directory, script: """
        printf '%s' '\(fresh.credential)' > "$CODEX_HOME/auth.json"
        """)
        XCTAssertEqual(code, 0)

        // 로그인 프로세스 종료와 UI의 결과 저장 사이에 다른 화면의 전환 완료.
        try switcher.switchAuthentication(to: company, from: personal)
        store.setPreferred(family: "codex", profileID: company.id)
        let restored = try importer.completeReSignIn(
            profileID: personal.id, in: store, isActive: false, signInAttemptID: signIn.attemptID
        )

        XCTAssertEqual(restored.identityKey, "personal-account")
        XCTAssertEqual(try switcher.loadSnapshot(for: restored), fresh)
        XCTAssertEqual(store.preferredProfileID(family: "codex"), company.id)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), try switcher.loadSnapshot(for: company))
        try workspace.remove(family: "codex", profileID: personal.id, attemptID: signIn.attemptID)
        XCTAssertEqual(try switcher.loadSnapshot(for: restored), fresh)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: restored.id)?.entry, fresh)
    }

    func testFailedLoginCannotRevokeAnExistingSnapshotThroughItsWorkspaceCopy() async throws {
        let original = entry(token: "saved-personal", account: "personal-account")
        let personal = try addProfile(label: "personal", entry: original)
        try switcher.applySharedAuthentication(original, family: "codex")
        let signIn = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)

        // Codex 0.166의 로그인 시작 시 기존 인증 폐기를 재현하는 로컬 CLI.
        let code = try await runLogin(home: signIn.directory, script: """
        if [ -f "$CODEX_HOME/auth.json" ]; then
            printf revoked > "$CODEX_HOME/revoked"
            rm "$CODEX_HOME/auth.json"
        fi
        exit 1
        """)

        XCTAssertEqual(code, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: signIn.directory.appendingPathComponent("revoked").path))
        XCTAssertEqual(try switcher.loadSnapshot(for: personal), original)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), original)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: personal.id)?.entry, original)
        try workspace.remove(family: "codex", profileID: personal.id, attemptID: signIn.attemptID)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: personal.id)?.entry, original)
    }

    func testASecondLoginCannotReadThePreviousAttemptsCredential() async throws {
        let original = entry(token: "saved-personal", account: "personal-account")
        let personal = try addProfile(label: "personal", entry: original)
        let first = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)
        let second = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)
        let stale = entry(token: "late-company", account: "company-account")
        try workspace.writePrivateFile(stale.credential, to: first.directory.appendingPathComponent("auth.json"))

        XCTAssertNil(
            try importer.readWorkspaceCredential(
                family: "codex", profileID: personal.id, attemptID: second.attemptID
            ))
        XCTAssertEqual(try switcher.loadSnapshot(for: personal), original)
    }

    func testDashboardRecoveryChecksIdentityBeforeSavingAndLeavesTheActiveLoginAlone() throws {
        let yAuth = entry(token: "active", account: "y", user: "user-y")
        let y = try addProfile(label: "y", entry: yAuth)
        let cAuth = entry(token: "expired", account: "c", user: "user-c", email: "c@example.com")
        let c = try addProfile(label: "c", entry: cAuth)
        store.setPreferred(family: "codex", profileID: y.id)
        try switcher.applySharedAuthentication(yAuth, family: "codex")
        let revision = store.authenticationRevision
        let attempt = try workspace.prepareReauthentication(family: "codex", profileID: c.id)
        let authFile = attempt.directory.appendingPathComponent("auth.json")
        func recover(expected: String) throws {
            try importer.completeReSignIn(
                profileID: c.id, in: store, isActive: false, signInAttemptID: attempt.attemptID,
                expectedIdentityKey: expected)
        }
        let differentUser = entry(token: "wrong", account: "c", user: "user-y", email: "c@example.com")
        let unverifiableUser = entry(token: "unknown", account: "c")
        for (replacement, expected, expectedError) in [
            (yAuth, c.identityKey, AccountCredentialImporter.ImportError.differentAccount),
            (yAuth, y.identityKey, .differentAccount),
            (differentUser, c.identityKey, .differentAccount),
            (unverifiableUser, c.identityKey, .reSignInIdentityUnavailable)
        ] {
            try workspace.writePrivateFile(replacement.credential, to: authFile)
            XCTAssertThrowsError(try recover(expected: expected)) { error in
                XCTAssertEqual(error as? AccountCredentialImporter.ImportError, expectedError)
            }
            XCTAssertEqual(store.authenticationRevision, revision)
            XCTAssertNil(try store.pendingIdentityReplacement())
            XCTAssertEqual(try switcher.loadSnapshot(for: c), cAuth)
            XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: c.id)?.entry, cAuth)
            XCTAssertEqual(try switcher.loadSnapshot(for: y), yAuth)
            XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), yAuth)
            XCTAssertEqual(store.preferredProfileID(family: "codex"), y.id)
        }
        let fresh = entry(token: "fresh", account: "c", user: "user-c", email: "renamed-c@example.com")
        try workspace.writePrivateFile(fresh.credential, to: authFile)
        try recover(expected: c.identityKey)

        XCTAssertEqual(try switcher.loadSnapshot(for: c), fresh)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: c.id)?.entry, fresh)
        XCTAssertEqual(try switcher.loadSnapshot(for: y), yAuth)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), yAuth)
        XCTAssertEqual(store.preferredProfileID(family: "codex"), y.id)
    }

    func testDashboardRecoveryAcceptsOlderClaimsWithTheSameSubjectOrEmail() throws {
        for (workspaceID, subject, email) in [
            ("subject", "legacy-user" as String?, nil),
            ("email", nil, "Legacy@Example.com")
        ] {
            let saved = entry(token: "expired", account: workspaceID, subject: subject, email: email)
            let current = entry(
                token: "fresh", account: workspaceID, user: "modern-user", subject: subject, email: email?.lowercased())
            let profile = try addProfile(label: workspaceID, entry: saved)
            let attempt = try workspace.prepareReauthentication(family: "codex", profileID: profile.id)
            try workspace.writePrivateFile(
                current.credential, to: attempt.directory.appendingPathComponent("auth.json"))

            try importer.completeReSignIn(
                profileID: profile.id, in: store, isActive: false, signInAttemptID: attempt.attemptID,
                expectedIdentityKey: profile.identityKey)

            XCTAssertEqual(try switcher.loadSnapshot(for: profile), current)
        }
    }

    func testRemovingAnAccountAlsoRemovesItsAbandonedLoginAttempt() throws {
        let personal = try addProfile(
            label: "personal", entry: entry(token: "saved-personal", account: "personal-account")
        )
        let otherCredential = entry(token: "saved-company", account: "company-account")
        let company = try addProfile(label: "company", entry: otherCredential)
        store.setPreferred(family: "codex", profileID: company.id)
        try switcher.applySharedAuthentication(otherCredential, family: "codex")
        let abandoned = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)
        let otherAttempt = try workspace.prepareReauthentication(family: "codex", profileID: company.id)
        try workspace.writePrivateFile(
            entry(token: "abandoned-personal", account: "personal-account").credential,
            to: abandoned.directory.appendingPathComponent("auth.json")
        )

        try importer.removeAccount(personal, from: store)

        XCTAssertFalse(FileManager.default.fileExists(atPath: abandoned.directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherAttempt.directory.path))
        XCTAssertEqual(try switcher.loadSnapshot(for: company), otherCredential)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), otherCredential)
    }

    func testAttemptPathsRejectTraversalAndSymlinks() throws {
        let original = entry(token: "saved-personal", account: "personal-account")
        let personal = try addProfile(label: "personal", entry: original)
        try switcher.applySharedAuthentication(original, family: "codex")
        XCTAssertThrowsError(try workspace.prepare(family: "codex", profileID: personal.id, attemptID: "../outside"))
        let signIn = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)
        let attemptID = try XCTUnwrap(signIn.attemptID)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let protectedFile = outside.appendingPathComponent("auth.json")
        let outsideCredential = entry(token: "outside-token", account: "outside-account")
        try Data(outsideCredential.credential.utf8).write(to: protectedFile)
        try FileManager.default.removeItem(at: signIn.directory)
        try FileManager.default.createSymbolicLink(at: signIn.directory, withDestinationURL: outside)

        XCTAssertThrowsError(try workspace.prepare(family: "codex", profileID: personal.id, attemptID: attemptID))
        XCTAssertThrowsError(try workspace.remove(family: "codex", profileID: personal.id, attemptID: attemptID))
        XCTAssertThrowsError(try importer.readWorkspaceCredential(
            family: "codex", profileID: personal.id, attemptID: attemptID
        )) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }
        XCTAssertThrowsError(try importer.completeReSignIn(
            profileID: personal.id, in: store, isActive: true, signInAttemptID: attemptID
        )) { error in
            guard case AccountSignInWorkspace.WorkspaceError.symlinkedComponent = error else {
                return XCTFail("expected symlinkedComponent, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOf: protectedFile, encoding: .utf8), outsideCredential.credential)
        XCTAssertEqual(store.profile(id: personal.id)?.identityKey, personal.identityKey)
        XCTAssertEqual(try switcher.loadSnapshot(for: personal), original)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), original)
        XCTAssertEqual(try importer.readWorkspaceCredential(family: "codex", profileID: personal.id)?.entry, original)
    }

    func testAttemptCredentialFileCannotLinkToAnotherAccountsAuthentication() throws {
        let original = entry(token: "saved-personal", account: "personal-account")
        let personal = try addProfile(label: "personal", entry: original)
        try switcher.applySharedAuthentication(original, family: "codex")
        let signIn = try workspace.prepareReauthentication(family: "codex", profileID: personal.id)
        let outside = root.appendingPathComponent("outside-auth.json")
        let outsideCredential = entry(token: "outside-token", account: "outside-account")
        try Data(outsideCredential.credential.utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: signIn.directory.appendingPathComponent("auth.json"), withDestinationURL: outside
        )

        XCTAssertThrowsError(try importer.completeReSignIn(
            profileID: personal.id, in: store, isActive: true, signInAttemptID: signIn.attemptID
        )) { error in
            XCTAssertEqual(
                error as? AccountCredentialImporter.ImportError,
                .verificationFailed(family: "codex")
            )
        }

        XCTAssertEqual(store.profile(id: personal.id)?.identityKey, personal.identityKey)
        XCTAssertEqual(try switcher.loadSnapshot(for: personal), original)
        XCTAssertEqual(try switcher.readSharedAuthentication(family: "codex"), original)
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), outsideCredential.credential)
    }

    private func addProfile(label: String, entry: AccountCredentialVault.Entry) throws -> AccountProfile {
        let identity = try XCTUnwrap(switcher.identity(of: entry, family: "codex")?.identityKey)
        let profile = try store.add(family: "codex", label: label, identityKey: identity)
        try switcher.saveSnapshot(entry, for: profile)
        try switcher.writeWorkspaceAuthentication(entry, for: profile)
        return profile
    }

    private func entry(
        token: String, account: String, user: String? = nil, subject: String? = nil, email: String? = nil
    ) -> AccountCredentialVault.Entry {
        var payload: [String: Any] = [:]
        if let user { payload["https://api.openai.com/auth"] = ["chatgpt_user_id": user] }
        payload["sub"] = subject
        payload["email"] = email
        let idToken: String?
        if let data = try? JSONSerialization.data(withJSONObject: payload), !payload.isEmpty {
            let base64URL = data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            idToken = "e30.\(base64URL).sig"
        } else {
            idToken = nil
        }
        let auth = CodexAuth(
            tokens: .init(
                accessToken: token, refreshToken: "refresh-\(token)", idToken: idToken, accountID: account),
            lastRefresh: nil, apiKey: nil)
        return .init(
            credential: String(decoding: try! JSONEncoder().encode(auth), as: UTF8.self),
            claudeOAuthAccount: nil
        )
    }

    private func runLogin(home: URL, script: String) async throws -> Int32 {
        let bin = root.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let cli = bin.appendingPathComponent("codex")
        try Data("#!/bin/sh\n\(script)\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        return try await AccountSignInLauncher().runLogin(
            family: "codex", home: home.path, baseEnvironment: ["PATH": "\(bin.path):/usr/bin:/bin"],
            usesLoginShellPATH: false
        )
    }
}
