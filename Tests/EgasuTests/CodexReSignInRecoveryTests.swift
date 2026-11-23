import Foundation
import XCTest
@testable import Egasu

@MainActor
final class CodexReSignInRecoveryTests: XCTestCase {
    func testInterruptedActiveCodexSignInKeepsAProtectedExternalLogin() async throws {
        for replacementWasSaved in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let external = fixture.credential("external-c", account: "workspace-c")
            try fixture.prepareInterruptedSignIn(replacementWasSaved: replacementWasSaved, shared: external)

            do {
                _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(
                    in: fixture.reloadedStore())
            } catch {
                // 외부 로그인 충돌은 복구를 중단해도 됨. 현재 공유 인증은 유지해야 함.
            }

            XCTAssertEqual(
                try fixture.switcher.readSharedAuthentication(family: "codex"), external,
                replacementWasSaved ? "snapshot written" : "journal only")
        }
    }

    func testStartupCodexIdentityRecoverySignalsCatalogRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: fixture.previous)
        let reloaded = fixture.reloadedStore()

        let result = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)

        XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "workspace-b")
        XCTAssertNil(try reloaded.pendingIdentityReplacement())
        XCTAssertEqual(result, .updated(profileID: fixture.profile.id))
    }

    func testManualCodexRecoveryReadsOnlyCodexEvenWhenClaudeIsRegistered() async throws {
        let keychain = ReplacementWriteKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        let claude = try fixture.store.add(family: "claude", label: "Claude", identityKey: "claude|org")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: fixture.previous)
        let selection = AccountSelectionSwitcher(switcher: fixture.switcher)
        XCTAssertTrue(try selection.hasPendingSwitch(for: fixture.profile, in: fixture.store))
        XCTAssertFalse(try selection.hasPendingSwitch(for: claude, in: fixture.store))
        let expectedService = AccountCredentialVault.service(family: "codex", profileID: fixture.profile.id)
        let read = expectation(description: "Codex snapshot read")
        keychain.onRead = { service in
            XCTAssertEqual(service, expectedService, "A Codex retry must not request access to Claude")
            read.fulfill()
        }

        let result = try await ProviderRefreshContext.$isManual.withValue(true) {
            try await fixture.importer.reconcileCodexIdentityReplacementAfterStartup(in: fixture.store)
        }

        await fulfillment(of: [read], timeout: 1)
        XCTAssertEqual(result, .updated(profileID: fixture.profile.id))
        let recovered = try XCTUnwrap(fixture.store.profile(id: fixture.profile.id))
        XCTAssertFalse(try selection.hasPendingSwitch(for: recovered, in: fixture.store))
    }

    func testRecoveryPreservesLaterCredentialsInTheSameWorkspaceAndItsJournal() async throws {
        for replacementWasSaved in [false, true] {
            for account in ["workspace-a", "workspace-b"] {
                let fixture = try Fixture()
                defer { fixture.cleanUp() }
                let external = fixture.credential("later-login", account: account)
                try fixture.prepareInterruptedSignIn(replacementWasSaved: replacementWasSaved, shared: external)
                let reloaded = fixture.reloadedStore()
                let journal = try reloaded.pendingIdentityReplacement()

                do {
                    _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)
                    XCTFail("A later shared login must stop automatic recovery")
                } catch {
                    XCTAssertEqual(error as? CodexAuthError, .credentialsChanged)
                }

                XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
                XCTAssertEqual(try reloaded.pendingIdentityReplacement(), journal)
                XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "workspace-a")
            }
        }
    }

    func testCodexRecoveryStillSignalsChangeWhenClaudeHasNoUsableAuthentication() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        _ = try fixture.store.add(family: "claude", label: "Claude", identityKey: "claude-account|org")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: fixture.previous)
        let reloaded = fixture.reloadedStore()

        let result = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)

        XCTAssertEqual(result, .updated(profileID: fixture.profile.id))
        XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "workspace-b")
    }

    func testDashboardRecoveryRejectsConflictingTokenSubjectsEvenWithTheSameUserID() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let before = try fixture.reSignInCredential(
            accessToken: "opaque-before", idToken: fixture.syntheticUserClaims("user-a"),
            account: fixture.profile.identityKey)
        let conflicting = try fixture.reSignInCredential(
            accessToken: fixture.syntheticUserClaims("user-a", subject: "different-subject"),
            idToken: fixture.syntheticUserClaims("user-a"), account: fixture.profile.identityKey)
        try fixture.switcher.saveSnapshot(before, for: fixture.profile)
        try fixture.switcher.applySharedAuthentication(before, family: "codex")
        let attempt = try fixture.workspace.prepareReauthentication(family: "codex", profileID: fixture.profile.id)
        try fixture.workspace.writePrivateFile(
            conflicting.credential, to: attempt.directory.appendingPathComponent("auth.json"))

        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(
                profileID: fixture.profile.id, in: fixture.store, isActive: true, signInAttemptID: attempt.attemptID,
                expectedIdentityKey: fixture.profile.identityKey))

        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), before)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), before)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testRecoveryPreservesADeletedOrMalformedSharedCredential() throws {
        for replacementWasSaved in [false, true] {
            for raw in [nil, "unreadable-login" as String?] {
                let fixture = try Fixture()
                defer { fixture.cleanUp() }
                try fixture.prepareInterruptedSignIn(replacementWasSaved: replacementWasSaved, shared: fixture.previous)
                let url = fixture.root.appendingPathComponent(".codex/auth.json")
                if let raw {
                    try raw.write(to: url, atomically: true, encoding: .utf8)
                } else {
                    try FileManager.default.removeItem(at: url)
                }
                let reloaded = fixture.reloadedStore()
                let journal = try reloaded.pendingIdentityReplacement()

                XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))

                XCTAssertEqual(try LocalTextFileAccessor().readTextIfPresent(url.path), raw)
                XCTAssertEqual(try reloaded.pendingIdentityReplacement(), journal)
            }
        }
    }

    func testLegacyRecoveryOnlyCompletesWhenTheSharedAuthenticationAlreadyMatchesTheSnapshot() throws {
        for sharedMatches in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let replacement = fixture.credential("replacement-b", account: "workspace-b")
            let shared = sharedMatches ? replacement : fixture.previous
            try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: shared, recordsGeneration: false)
            let reloaded = fixture.reloadedStore()
            let journal = try reloaded.pendingIdentityReplacement()

            if sharedMatches {
                XCTAssertTrue(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))
                XCTAssertNil(try reloaded.pendingIdentityReplacement())
                XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "workspace-b")
            } else {
                XCTAssertThrowsError(try fixture.importer.recoverInterruptedIdentityReplacement(in: reloaded))
                XCTAssertEqual(try reloaded.pendingIdentityReplacement(), journal)
            }
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), shared)
        }
    }

    func testJournalOnlyRecoveryKeepsThePreviousSharedLoginWhenTheSavedTokenWasOlder() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let shared = fixture.credential("current-previous-token", account: "workspace-a")
        try fixture.switcher.saveSnapshot(fixture.previous, for: fixture.profile)
        try fixture.switcher.applySharedAuthentication(shared, family: "codex")
        _ = try fixture.store.beginIdentityReplacement(
            profileID: fixture.profile.id, with: "workspace-b", replacesSharedAuthentication: true,
            codexGeneration: .init(
                sharedHome: fixture.switcher.sharedHomePath(family: "codex"), previousShared: shared,
                previousSnapshot: fixture.previous,
                replacement: fixture.credential("replacement-b", account: "workspace-b")))

        XCTAssertFalse(try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store))

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), shared)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), fixture.previous)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testSameWorkspaceRecoveryUsesTheSavedGenerationInsteadOfItsIdentity() throws {
        for replacementWasSaved in [false, true] {
            for replacementWasShared in [false, true] {
                let fixture = try Fixture()
                defer { fixture.cleanUp() }
                let replacement = fixture.credential("same-workspace-new-token", account: fixture.profile.identityKey)
                let saved = replacementWasSaved ? replacement : fixture.previous
                try fixture.switcher.saveSnapshot(saved, for: fixture.profile)
                _ = try fixture.store.beginIdentityReplacement(
                    profileID: fixture.profile.id, with: fixture.profile.identityKey,
                    replacesSharedAuthentication: true,
                    codexGeneration: .init(
                        sharedHome: fixture.switcher.sharedHomePath(family: "codex"), previousShared: fixture.previous,
                        previousSnapshot: fixture.previous, replacement: replacement))
                try fixture.switcher.applySharedAuthentication(
                    replacementWasShared ? replacement : fixture.previous, family: "codex")

                XCTAssertEqual(
                    try fixture.importer.recoverInterruptedIdentityReplacement(in: fixture.store), replacementWasSaved)

                XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), saved)
                XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), saved)
                XCTAssertNil(try fixture.store.pendingIdentityReplacement())
            }
        }
    }

    func testFailedCompletionCannotRollBackALaterExternalLogin() throws {
        let keychain = ReplacementWriteKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        let replacement = fixture.credential("new-b", account: "workspace-b")
        let external = fixture.credential("later-c", account: "workspace-c")
        try fixture.switcher.saveSnapshot(fixture.previous, for: fixture.profile)
        try fixture.switcher.applySharedAuthentication(fixture.previous, family: "codex")
        let attempt = try fixture.workspace.prepareReauthentication(family: "codex", profileID: fixture.profile.id)
        try fixture.workspace.writePrivateFile(
            replacement.credential, to: attempt.directory.appendingPathComponent("auth.json"))
        let sharedURL = fixture.root.appendingPathComponent(".codex/auth.json")
        keychain.onNextWrite = {
            try external.credential.write(to: sharedURL, atomically: true, encoding: .utf8)
        }

        XCTAssertThrowsError(
            try fixture.importer.completeReSignIn(
                profileID: fixture.profile.id, in: fixture.store, isActive: true, signInAttemptID: attempt.attemptID))

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), replacement)
        XCTAssertNotNil(try fixture.store.pendingIdentityReplacement())
    }

    func testExplicitUseCompletesThePendingSignInAndAppliesTheChosenSavedAccount() async throws {
        for replacementWasSaved in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let external = fixture.credential("later-c", account: "workspace-c")
            try fixture.prepareInterruptedSignIn(replacementWasSaved: replacementWasSaved, shared: external)
            let reloaded = fixture.reloadedStore()
            let expected =
                replacementWasSaved
                ? fixture.credential("replacement-b", account: "workspace-b") : fixture.previous

            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: fixture.profile, in: reloaded)

            XCTAssertNil(try reloaded.pendingIdentityReplacement())
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), expected)
            _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)
            XCTAssertNil(try reloaded.pendingIdentityReplacement())
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), expected)
        }
    }

    func testSwitchingAwayAfterRecoveryCannotSaveAnotherUserFromTheReplacementWorkspace() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let replacement = fixture.credential("replacement-b", account: "workspace-b")
        let external = try fixture.reSignInCredential(
            accessToken: "other-user-token", idToken: fixture.syntheticUserClaims("other-user"), account: "workspace-b")
        let target = try fixture.store.add(family: "codex", label: "D", identityKey: "workspace-d")
        let targetAuth = fixture.credential("target-d", account: "workspace-d")
        try fixture.switcher.saveSnapshot(targetAuth, for: target)
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)

        try await AccountSelectionSwitcher(switcher: fixture.switcher).switchAuthentication(
            to: target, in: fixture.store)

        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), replacement)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), targetAuth)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testRecommendationValidationCannotConsumeAnInterruptedSignIn() async throws {
        for checksTarget in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let target = try fixture.store.add(family: "codex", label: "D", identityKey: "workspace-d")
            try fixture.switcher.saveSnapshot(fixture.credential("d", account: "workspace-d"), for: target)
            try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: fixture.previous)
            let journal = try fixture.store.pendingIdentityReplacement()
            let replacement = try fixture.switcher.loadSnapshot(for: fixture.profile)
            let denyTarget: ((AccountCredentialVault.Entry) throws -> Void)? =
                checksTarget
                ? { _ in throw AccountSwitchRecommendation.NoLongerAvailable() } : nil
            let denyDeparture: ((String?) throws -> Void)? =
                checksTarget
                ? nil : { _ in throw AccountSwitchRecommendation.NoLongerAvailable() }

            do {
                try await AccountSelectionSwitcher(switcher: fixture.switcher).switchAuthentication(
                    to: target, in: fixture.store, validateTarget: denyTarget, validateDeparture: denyDeparture)
                XCTFail("A stale recommendation must not complete the pending sign-in")
            } catch {
                XCTAssertTrue(error is AccountSwitchRecommendation.NoLongerAvailable)
            }

            XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
            XCTAssertEqual(fixture.store.profile(id: fixture.profile.id)?.identityKey, "workspace-a")
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), replacement)
            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), fixture.previous)
        }
    }

    func testExplicitUseOfAnotherAccountDoesNotReplayTheInterruptedSharedWriteOnNextStartup() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let external = fixture.credential("later-c", account: "workspace-c")
        let other = try fixture.store.add(family: "codex", label: "C", identityKey: "workspace-c")
        try fixture.switcher.saveSnapshot(external, for: other)
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
        let reloaded = fixture.reloadedStore()

        try await AccountSelectionSwitcher(switcher: fixture.switcher).switchAuthentication(to: other, in: reloaded)

        XCTAssertNil(try reloaded.pendingIdentityReplacement())
        XCTAssertEqual(reloaded.preferredProfileID(family: "codex"), other.id)
        XCTAssertEqual(reloaded.profile(id: fixture.profile.id)?.identityKey, "workspace-b")
        _ = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(reloaded.preferredProfileID(family: "codex"), other.id)
    }

    func testDashboardCodexSignInRejectsConflictingUsersBeforeReplacingAuthentication() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let idToken = try fixture.syntheticUserClaims("user-a")
        let account = fixture.profile.identityKey
        let before = try fixture.reSignInCredential(
            accessToken: "previous-opaque-token", idToken: idToken, account: account)
        let matching = try fixture.reSignInCredential(
            accessToken: "renewed-opaque-token", idToken: idToken, account: account)
        let conflicting = try fixture.reSignInCredential(
            accessToken: fixture.syntheticUserClaims("user-b"), idToken: idToken, account: account)
        try fixture.switcher.saveSnapshot(before, for: fixture.profile)
        try fixture.switcher.applySharedAuthentication(before, family: "codex")
        let attempt = try fixture.workspace.prepareReauthentication(family: "codex", profileID: fixture.profile.id)
        let attemptFile = attempt.directory.appendingPathComponent("auth.json")
        func complete(_ credential: AccountCredentialVault.Entry) throws {
            try fixture.workspace.writePrivateFile(credential.credential, to: attemptFile)
            try fixture.importer.completeReSignIn(
                profileID: fixture.profile.id, in: fixture.store, isActive: true, signInAttemptID: attempt.attemptID,
                expectedIdentityKey: account)
        }

        try complete(matching)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), matching)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), matching)

        XCTAssertThrowsError(try complete(conflicting))
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), matching)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), matching)
    }

    @MainActor
    struct Fixture {
        let root: URL
        let suite: String
        let defaults: UserDefaults
        let store: AccountProfilesStore
        let profile: AccountProfile
        let workspace: AccountSignInWorkspace
        let importer: AccountCredentialImporter
        let previous = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"previous-a","account_id":"workspace-a"}}"#,
            claudeOAuthAccount: nil)

        var switcher: AccountCredentialSwitcher { importer.switcher }

        init(keychain: KeychainAccessing = ServiceKeychain(), synchronizeDefaults: (() -> Bool)? = nil) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "egasu-auth-review-\(UUID().uuidString)")
            suite = "EgasuTests.CodexReSignInRecovery.\(UUID().uuidString)"
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            store = AccountProfilesStore(defaults: defaults, synchronizeDefaults: synchronizeDefaults)
            profile = try store.add(family: "codex", label: "A", identityKey: "workspace-a")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
            importer = AccountCredentialImporter(
                keychain: keychain, environment: FakeEnvironment(), homeDirectory: root,
                workspace: workspace,
                httpClient: FakeHTTPClient(response: .init(statusCode: 500, headers: [:], body: Data())))
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }

        func reloadedStore() -> AccountProfilesStore { AccountProfilesStore(defaults: defaults) }

        func credential(_ token: String, account: String) -> AccountCredentialVault.Entry {
            .init(
                credential: #"{"tokens":{"access_token":"\#(token)","account_id":"\#(account)"}}"#,
                claudeOAuthAccount: nil)
        }

        func syntheticUserClaims(_ user: String, subject: String? = nil) throws -> String {
            let claims: [String: Any] = [
                "sub": subject ?? user, "https://api.openai.com/auth": ["chatgpt_user_id": user]
            ]
            let payload = try JSONSerialization.data(withJSONObject: claims).base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
            return "e30.\(payload).fixture"
        }

        func reSignInCredential(
            accessToken: String, idToken: String, account: String
        ) throws -> AccountCredentialVault.Entry {
            let auth = CodexAuth(tokens: .init(accessToken: accessToken, idToken: idToken, accountID: account))
            return .init(
                credential: String(decoding: try JSONEncoder().encode(auth), as: UTF8.self), claudeOAuthAccount: nil)
        }

        func prepareInterruptedSignIn(
            replacementWasSaved: Bool, shared: AccountCredentialVault.Entry, recordsGeneration: Bool = true
        ) throws {
            try switcher.saveSnapshot(previous, for: profile)
            try switcher.applySharedAuthentication(previous, family: "codex")
            let replacement = credential("replacement-b", account: "workspace-b")
            _ = try store.beginIdentityReplacement(
                profileID: profile.id, with: "workspace-b", replacesSharedAuthentication: true,
                codexGeneration: recordsGeneration
                    ? .init(
                        sharedHome: switcher.sharedHomePath(family: "codex"), previousShared: previous,
                        previousSnapshot: previous, replacement: replacement) : nil)
            if replacementWasSaved {
                try switcher.saveSnapshot(replacement, for: profile)
            }
            try switcher.applySharedAuthentication(shared, family: "codex")
        }
    }
}

final class ReplacementWriteKeychain: KeychainAccessing, @unchecked Sendable {
    private let base = ServiceKeychain()
    var onNextWrite: (@Sendable () throws -> Void)?
    var onRead: (@Sendable (String) throws -> Void)?

    func readGenericPassword(service: String) throws -> String? {
        try onRead?(service)
        return try base.readGenericPassword(service: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        try onRead?(service)
        return try base.readGenericPasswordForCurrentUser(service: service)
    }

    func writeGenericPassword(service: String, value: String) throws {
        try base.writeGenericPassword(service: service, value: value)
        let hook = onNextWrite
        onNextWrite = nil
        try hook?()
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        try base.writeGenericPasswordForCurrentUser(service: service, value: value)
        let hook = onNextWrite
        onNextWrite = nil
        try hook?()
    }

    func deleteGenericPassword(service: String) throws {
        try base.deleteGenericPassword(service: service)
    }
}
