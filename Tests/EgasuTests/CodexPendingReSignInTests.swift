import XCTest
@testable import Egasu

@MainActor
final class CodexPendingReSignInTests: XCTestCase {
    private typealias Fixture = CodexReSignInRecoveryTests.Fixture

    func testTheFirstUseSucceedsWhenTheSwitcherClearsOnlyStaleSharedMetadata() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try fixture.prepareInterruptedSignIn(
            replacementWasSaved: true, shared: fixture.credential("external-c", account: "workspace-c"))
        var staged = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.profile))
        staged.codexStaleSharedCredentialFingerprints = [
            CodexAuthStore.credentialFingerprint(fixture.previous.credential)
        ]
        try fixture.switcher.saveSnapshot(staged, for: fixture.profile)

        try await AccountSelectionSwitcher(switcher: fixture.switcher)
            .switchAuthentication(to: fixture.profile, in: fixture.store)

        let saved = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.profile))
        XCTAssertEqual(saved.credential, staged.credential)
        XCTAssertNil(saved.codexStaleSharedCredentialFingerprints)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testWorkspaceStagingFailureDoesNotChangeTheSharedLoginOrSelection() async throws {
        for symlink in [false, true] {
            let fixture = try Fixture()
            defer { fixture.cleanUp() }
            let target = try fixture.store.add(family: "codex", label: "D", identityKey: "workspace-d")
            try fixture.switcher.saveSnapshot(fixture.credential("d", account: "workspace-d"), for: target)
            let external = fixture.credential("external-c", account: "workspace-c")
            try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
            let journal = try fixture.store.pendingIdentityReplacement()
            let workspace = try fixture.workspace.directory(family: "codex", profileID: fixture.profile.id)
            try FileManager.default.createDirectory(
                at: workspace.deletingLastPathComponent(), withIntermediateDirectories: true)
            let obstruction: URL
            if symlink {
                let foreign = fixture.root.appendingPathComponent("foreign")
                try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: workspace, withDestinationURL: foreign)
                obstruction = workspace
            } else {
                obstruction = workspace.appendingPathComponent("auth.json")
                try FileManager.default.createDirectory(at: obstruction, withIntermediateDirectories: true)
            }

            do {
                try await AccountSelectionSwitcher(switcher: fixture.switcher)
                    .switchAuthentication(to: target, in: fixture.store)
                XCTFail("The interrupted workspace cannot be staged")
            } catch {}

            XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.profile.id)
            XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
            XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)

            try FileManager.default.removeItem(at: obstruction)
            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: target, in: fixture.store)
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        }
    }

    func testSelectionSaveFailureRestoresOnlyTheAppliedLoginAndKeepsRecoveryForRetry() async throws {
        var canSave = false
        let fixture = try Fixture(synchronizeDefaults: { canSave })
        defer { fixture.cleanUp() }
        let external = fixture.credential("external-c", account: "workspace-c")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
        let journal = try fixture.store.pendingIdentityReplacement()

        do {
            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: fixture.profile, in: fixture.store)
            XCTFail("The selected account cannot be confirmed")
        } catch {}

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
        XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
        canSave = true
        try await AccountSelectionSwitcher(switcher: fixture.switcher)
            .switchAuthentication(to: fixture.profile, in: fixture.store)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testCompletionKeychainFailureRestoresTheSharedLoginAndPreviousSelection() async throws {
        let keychain = ReplacementWriteKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        let target = try fixture.store.add(family: "codex", label: "D", identityKey: "workspace-d")
        try fixture.switcher.saveSnapshot(fixture.credential("d", account: "workspace-d"), for: target)
        let external = fixture.credential("external-c", account: "workspace-c")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
        let journal = try fixture.store.pendingIdentityReplacement()
        let service = AccountCredentialVault.service(family: "codex", profileID: fixture.profile.id)
        keychain.onRead = { observed in
            if observed == service {
                keychain.onRead = { subsequent in
                    if subsequent == service { throw KeychainError.readFailed("Fixture completion denial") }
                }
            }
        }

        do {
            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: target, in: fixture.store)
            XCTFail("The final saved-credential check is denied")
        } catch {}

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.profile.id)
        XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
    }

    func testMetadataFailureDoesNotRestoreOverANewerExternalCLILogin() async throws {
        var sharedURL: URL?
        let later = #"{"tokens":{"access_token":"later-e","account_id":"workspace-e"}}"#
        let fixture = try Fixture(synchronizeDefaults: {
            if let sharedURL {
                do { try later.write(to: sharedURL, atomically: true, encoding: .utf8) } catch {
                    XCTFail("Could not stage the later CLI login: \(error)")
                }
            }
            return false
        })
        defer { fixture.cleanUp() }
        let external = fixture.credential("external-c", account: "workspace-c")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
        let journal = try fixture.store.pendingIdentityReplacement()
        sharedURL = fixture.root.appendingPathComponent(".codex/auth.json")

        do {
            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: fixture.profile, in: fixture.store)
            XCTFail("The selection save fails after a newer CLI login")
        } catch {}

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex")?.credential, later)
        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
        XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
    }

    func testStaleMetadataCleanupFailureKeepsALaterExternalLogin() async throws {
        let keychain = ReplacementWriteKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        try fixture.prepareInterruptedSignIn(
            replacementWasSaved: true, shared: fixture.credential("external-c", account: "workspace-c"))
        var staged = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.profile))
        staged.codexStaleSharedCredentialFingerprints = [
            CodexAuthStore.credentialFingerprint(fixture.previous.credential)
        ]
        try fixture.switcher.saveSnapshot(staged, for: fixture.profile)
        let later = fixture.credential("later-e", account: "workspace-e")
        let sharedURL = fixture.root.appendingPathComponent(".codex/auth.json")
        keychain.onNextWrite = {
            try later.credential.write(to: sharedURL, atomically: true, encoding: .utf8)
            throw KeychainError.readFailed("Fixture metadata cleanup failure")
        }

        do {
            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: fixture.profile, in: fixture.store)
            XCTFail("The stale metadata cleanup fails")
        } catch {}

        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), later)
        XCTAssertNotNil(try fixture.store.pendingIdentityReplacement())
        XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
    }

    func testFailedSharedAuthenticationWriteKeepsTheRecoveryRowAndAllowsRetry() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let external = fixture.credential("external-c", account: "workspace-c")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
        let journal = try fixture.store.pendingIdentityReplacement()
        let authURL = fixture.root.appendingPathComponent(".codex/auth.json")
        try FileManager.default.removeItem(at: authURL)
        try FileManager.default.createDirectory(at: authURL, withIntermediateDirectories: false)

        do {
            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: fixture.profile, in: fixture.store)
            XCTFail("The shared authentication path is not writable")
        } catch {}

        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
        XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
        XCTAssertTrue(
            try AccountSelectionSwitcher(switcher: fixture.switcher)
                .hasPendingSwitch(for: fixture.profile, in: fixture.store))

        try FileManager.default.removeItem(at: authURL)
        try fixture.switcher.applySharedAuthentication(external, family: "codex")
        let selected = try XCTUnwrap(fixture.store.profile(id: fixture.profile.id))
        try await AccountSelectionSwitcher(switcher: fixture.switcher).switchAuthentication(
            to: selected, in: fixture.store)

        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        XCTAssertEqual(fixture.store.profile(id: selected.id)?.identityKey, "workspace-b")
        XCTAssertEqual(
            try fixture.switcher.readSharedAuthentication(family: "codex"),
            fixture.credential("replacement-b", account: "workspace-b"))
    }

    func testTargetKeychainFailureDoesNotCommitAnotherAccountsInterruptedSignIn() async throws {
        let keychain = ReplacementWriteKeychain()
        let fixture = try Fixture(keychain: keychain)
        defer { fixture.cleanUp() }
        let target = try fixture.store.add(family: "codex", label: "D", identityKey: "workspace-d")
        try fixture.switcher.saveSnapshot(fixture.credential("d", account: "workspace-d"), for: target)
        let external = fixture.credential("external-c", account: "workspace-c")
        try fixture.prepareInterruptedSignIn(replacementWasSaved: true, shared: external)
        let journal = try fixture.store.pendingIdentityReplacement()
        let deniedService = AccountCredentialVault.service(family: "codex", profileID: target.id)
        keychain.onRead = { service in
            if service == deniedService { throw KeychainError.readFailed("Fixture denial") }
        }

        do {
            try await AccountSelectionSwitcher(switcher: fixture.switcher).switchAuthentication(
                to: target, in: fixture.store)
            XCTFail("The selected account cannot be read")
        } catch {}

        XCTAssertEqual(try fixture.store.pendingIdentityReplacement(), journal)
        XCTAssertEqual(fixture.store.profile(id: fixture.profile.id), fixture.profile)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), external)
    }

    func testCorruptJournalSurvivesPresentationAndRecoveryQueries() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        for raw in [Data("invalid journal".utf8), "invalid journal"] as [Any] {
            fixture.defaults.set(raw, forKey: AccountProfilesStore.identityReplacementKey)
            let before = fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:]
            for _ in 0..<2 {
                XCTAssertThrowsError(
                    try AccountSelectionSwitcher(switcher: fixture.switcher)
                        .hasPendingSwitch(for: fixture.profile, in: fixture.store))
                XCTAssertThrowsError(try fixture.store.pendingIdentityReplacement())
                XCTAssertTrue(
                    NSDictionary(dictionary: fixture.defaults.persistentDomain(forName: fixture.suite) ?? [:])
                        .isEqual(to: before))
            }
        }
    }

    func testPendingSameWorkspaceSignInDefersRotationButKeepsUsableQuotaAndResumesAfterUse() async throws {
        for rejectsUsage in [false, true] {
            let keychain = ServiceKeychain()
            let fixture = try Fixture(keychain: keychain)
            defer { fixture.cleanUp() }
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let replacement = AccountCredentialVault.Entry(
                credential:
                    #"{"tokens":{"access_token":"usable","refresh_token":"refresh","account_id":"workspace-a"},"last_refresh":"2020-01-01T00:00:00Z"}"#,
                claudeOAuthAccount: nil)
            try fixture.switcher.saveSnapshot(replacement, for: fixture.profile)
            _ = try fixture.store.beginIdentityReplacement(
                profileID: fixture.profile.id, with: fixture.profile.identityKey, replacesSharedAuthentication: true,
                codexGeneration: .init(
                    sharedHome: fixture.switcher.sharedHomePath(family: "codex"), previousShared: fixture.previous,
                    previousSnapshot: fixture.previous, replacement: replacement))
            try fixture.switcher.applySharedAuthentication(
                fixture.credential("c", account: "workspace-c"), family: "codex")
            let http = PendingSignInHTTP(rejectsUsage: rejectsUsage)
            let provider = CodexProvider(
                authStore: CodexAuthStore(
                    environment: FakeEnvironment(), keychain: keychain,
                    scope: .accountSnapshot(profileID: fixture.profile.id),
                    now: { now }, managedSharedAuthHome: fixture.switcher.sharedHomePath(family: "codex")),
                usageClient: CodexUsageClient(http: http),
                logUsageScanner: CodexLogUsageScanner(
                    environment: FakeEnvironment(),
                    incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
                    cacheIdentityOverride: UUID().uuidString, rootsOverride: []),
                includeSharedUsage: false, now: { now }, pricing: { .empty },
                allowsCredentialRefresh: {
                    try fixture.store.pendingIdentityReplacement()?.profileID != fixture.profile.id
                }
            )

            let snapshot = await provider.refresh()
            let beforeUse = await http.rotations
            XCTAssertEqual(beforeUse, 0)
            XCTAssertEqual(snapshot.lines.contains { $0.label == "Session" }, !rejectsUsage)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.profile), replacement)

            try await AccountSelectionSwitcher(switcher: fixture.switcher)
                .switchAuthentication(to: fixture.profile, in: fixture.store)
            await http.setRejectsUsage(false)
            _ = await provider.refresh()
            let afterUse = await http.rotations
            XCTAssertEqual(afterUse, 1)
            let saved = try XCTUnwrap(fixture.switcher.loadSnapshot(for: fixture.profile))
            XCTAssertEqual(CodexAuthStore.parseAuth(saved.credential)?.tokens?.accessToken, "rotated")
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        }
    }
}

private actor PendingSignInHTTP: HTTPClient {
    private(set) var rotations = 0
    private var rejectsUsage: Bool
    init(rejectsUsage: Bool) { self.rejectsUsage = rejectsUsage }
    func setRejectsUsage(_ rejects: Bool) { rejectsUsage = rejects }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        if request.url == CodexUsageClient.usageURL, rejectsUsage {
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let body: String
        if request.url == CodexUsageClient.refreshURL {
            rotations += 1
            body = #"{"access_token":"rotated","refresh_token":"rotated-refresh"}"#
        } else if request.url == CodexUsageClient.resetCreditsURL {
            body = #"{"available_count":0,"credits":[]}"#
        } else {
            body =
                #"{"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":10,"reset_after_seconds":3600,"limit_window_seconds":18000}}}"#
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}
