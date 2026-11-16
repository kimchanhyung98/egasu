import XCTest
@testable import Egasu

@MainActor
final class AccountExternalLoginPreservationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var keychain: ServiceKeychain!
    private var workspace: AccountSignInWorkspace!
    private var switcher: AccountCredentialSwitcher!
    private var importer: AccountCredentialImporter!
    private var store: AccountProfilesStore!
    private var profile: AccountProfile!
    private var http: ClaudeReconciliationHTTPClient!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountExternalLoginPreservationTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AccountExternalLoginPreservationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { [root, defaults] in
            defaults?.removePersistentDomain(forName: suite)
            if let root { try? FileManager.default.removeItem(at: root) }
        }
        keychain = ServiceKeychain()
        workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace
        )
        http = ClaudeReconciliationHTTPClient()
        http.identities = ["rotated-b": "acct-b|org-b", "base-b": "acct-b|org-b", "external-c": "acct-c|org-c"]
        importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root, workspace: workspace,
            httpClient: http
        )
        store = AccountProfilesStore(defaults: defaults)
        profile = try store.add(
            family: "claude", label: "Work", identityKey: "acct-b|org-b", id: "profile-b"
        )
        let saved = entry(token: "saved-b", account: "b")
        try switcher.saveSnapshot(saved, for: profile)
        try switcher.writeWorkspaceAuthentication(saved, for: profile)
    }

    func testRefreshTokenRotationDoesNotRequireNewAccountStateGeneration() async throws {
        let rotated = entry(token: "rotated-b", account: "b", refreshToken: "rotated-refresh-b")
        try seedShared(base: rotated, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: rootState.path
        )
        let before = try captureArtifacts()

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), rotated)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
        try assertCLIUnchanged(before)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(http.requests.first?.method, "GET")
        XCTAssertEqual(http.requests.first?.url.path, "/api/oauth/profile")
    }

    func testConflictingScopedLoginDoesNotBlockDefaultLoginOrRewriteCLIAuthentication() async throws {
        for scopedTime in [50.0, 100.0, 200.0] {
            let base = entry(token: "base-b", account: "b")
            try seedShared(
                base: base, baseTime: 100, scoped: entry(token: "scoped-c", account: "c"), scopedTime: scopedTime)
            let before = try captureArtifacts()

            _ = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

            XCTAssertEqual(try switcher.loadSnapshot(for: profile), base)
            try assertCLIUnchanged(before)
        }
    }

    func testMissingModificationDatesDoNotBlockVerifiedRotation() async throws {
        let rotated = entry(token: "rotated-b", account: "b", refreshToken: "new-refresh")
        try seedShared(base: rotated, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        keychain.currentUserModificationDates.removeAll()
        let before = try captureArtifacts()

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        try assertCLIUnchanged(before)
    }

    func testUnchangedAuthenticationDoesNotRequestProfileOrWriteAnything() async throws {
        let saved = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        try seedShared(base: saved, baseTime: 100, scoped: entry(token: "scoped-c", account: "c"), scopedTime: 200)
        let before = try captureArtifacts()

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .unchanged)
        XCTAssertTrue(http.requests.isEmpty)
        try assertPreserved(before)
    }

    func testDefaultLogoutDoesNotRestoreStaleScopedAuthentication() async throws {
        try seedShared(
            base: entry(token: "rotated-b", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        keychain.currentUserValues.removeValue(forKey: baseService)
        try FileManager.default.removeItem(at: sharedHome.appendingPathComponent(".credentials.json"))
        let before = try captureArtifacts()

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .noUsableAuthentication)
        XCTAssertNil(try switcher.readSharedClaudeAuthenticationForReadiness())
        XCTAssertTrue(http.requests.isEmpty)
        try assertPreserved(before)
    }

    func testProfileFailurePreservesSavedAccountsAndCLIAuthentication() async throws {
        let rotated = entry(token: "rotated-b", account: "b", refreshToken: "new-refresh")
        try seedShared(base: rotated, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let before = try captureArtifacts()
        for status in [401, 429, 500] {
            http.response = HTTPResponse(statusCode: status, headers: [:], body: Data())
            let result = await claudeReconciliationResult(importer, in: store)
            XCTAssertThrowsError(try result.get())
            try assertPreserved(before)
        }
    }

    func testTokenForAnotherAccountCannotReplaceSnapshotUsingOldLocalMetadata() async throws {
        try seedShared(
            base: entry(token: "external-c", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let before = try captureArtifacts()

        let result = await claudeReconciliationResult(importer, in: store)

        XCTAssertThrowsError(try result.get())
        try assertPreserved(before)
    }

    func testTokenForAnotherOrganizationCannotReplaceSnapshot() async throws {
        try seedShared(
            base: entry(token: "rotated-b", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        http.identities["rotated-b"] = "acct-b|other-org"
        let before = try captureArtifacts()

        let result = await claudeReconciliationResult(importer, in: store)

        XCTAssertThrowsError(try result.get())
        try assertPreserved(before)
    }

    func testLoginChangedDuringProfileRequestIsPreservedForNextObservation() async throws {
        try seedShared(
            base: entry(token: "rotated-b", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let before = try captureArtifacts()
        let external = entry(token: "external-c", account: "c")
        http.beforeResponse = { [keychain = keychain!, baseService, rootState] in
            keychain.currentUserValues[baseService] = external.credential
            try Data(#"{"oauthAccount":\#(external.claudeOAuthAccount!)}"#.utf8).write(to: rootState)
        }

        let result = await claudeReconciliationResult(importer, in: store)

        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(
            try switcher.loadSnapshot(for: profile)?.credential, entry(token: "saved-b", account: "b").credential)
        XCTAssertEqual(keychain.currentUserValues[baseService], external.credential)
        XCTAssertEqual(keychain.currentUserValues[scopedService], before.currentUserValues[scopedService])
        XCTAssertEqual(try switcher.readSharedClaudeAuthenticationForReadiness(), external)
        XCTAssertEqual(store.profile(id: profile.id), profile)
    }

    func testKnownExternalAccountMovesSelectionAndPreservesPreviousSnapshot() async throws {
        let other = try store.add(family: "claude", label: "Other", identityKey: "acct-c|org-c", id: "profile-c")
        let previousOther = entry(token: "saved-c", account: "c")
        try switcher.saveSnapshot(previousOther, for: other)
        try switcher.writeWorkspaceAuthentication(previousOther, for: other)
        let previous = try switcher.loadSnapshot(for: profile)
        let external = entry(token: "external-c", account: "c")
        try seedShared(base: external, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let before = try captureArtifacts()

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .updated(profileID: other.id))
        XCTAssertEqual(store.preferredProfileID(family: "claude"), other.id)
        XCTAssertEqual(AccountProfilesStore(defaults: defaults).preferredProfileID(family: "claude"), other.id)
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), previous)
        XCTAssertEqual(try switcher.loadSnapshot(for: other), external)
        XCTAssertEqual(store.profile(id: profile.id), profile)
        XCTAssertEqual(store.profile(id: other.id), other)
        try assertCLIUnchanged(before)
    }

    func testExistingExternalSnapshotPersistsSelectionWithoutChangingAuthentication() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        try fixture.switcher.applySharedAuthentication(fixture.entryB, family: "claude")
        let before = try fixture.switcher.readClaudeSwitchState()

        let result = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(
            in: fixture.store)

        XCTAssertEqual(result, .updated(profileID: fixture.b.id))
        XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        try fixture.assertSavedAccountsUnchanged()
    }

    func testSelectionPersistenceFailurePreservesAuthenticationAndCanRetry() async throws {
        for snapshotMatches in [true, false] {
            let fixture = try AccountSwitchRecoveryFixture(test: self, synchronize: { false })
            let external = snapshotMatches ? fixture.entryB : AccountSwitchRecoveryFixture.entry("b", token: "new-b")
            fixture.keychain.currentUserValues[fixture.baseService] = external.credential
            try Data(#"{"oauthAccount":\#(external.claudeOAuthAccount!)}"#.utf8)
                .write(to: fixture.root.appendingPathComponent(".claude.json"))
            let before = try fixture.switcher.readClaudeSwitchState()
            let registry = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)
            let http = ClaudeReconciliationHTTPClient()
            http.identities[external == fixture.entryB ? "token-b" : "new-b"] = "acct-b|org-b"
            let importer = AccountCredentialImporter(
                keychain: fixture.keychain, environment: FakeEnvironment(),
                homeDirectory: fixture.root, workspace: fixture.workspace, httpClient: http
            )

            let result = await claudeReconciliationResult(importer, in: fixture.store)

            XCTAssertThrowsError(try result.get()) {
                XCTAssertEqual($0 as? AccountCredentialSwitcher.Error, .selectionSaveFailed)
            }
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
            try fixture.assertSavedAccountsUnchanged()
            XCTAssertNil(try fixture.store.pendingIdentityReplacement())
            XCTAssertEqual(fixture.store.authenticationRevision, 0)

            fixture.defaults.set(registry, forKey: AccountProfilesStore.storageKey)
            let reloaded = try fixture.freshStore()
            let retried = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: reloaded)

            XCTAssertEqual(retried, .updated(profileID: fixture.b.id))
            XCTAssertEqual(try fixture.freshStore().preferredProfileID(family: "claude"), fixture.b.id)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), fixture.entryA)
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), external)
            for (profile, entry) in [(fixture.a, fixture.entryA), (fixture.b, external)] {
                let home = try fixture.workspace.directory(family: "claude", profileID: profile.id).path
                XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), entry)
            }
            XCTAssertNil(try reloaded.pendingIdentityReplacement())
        }
    }

    func testCurrentAccountWinsWhenMultipleRecordsHaveTheSameIdentity() async throws {
        _ = try store.add(family: "claude", label: "Duplicate", identityKey: profile.identityKey, id: "duplicate")
        try seedShared(
            base: entry(token: "rotated-b", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
    }

    func testLegacyAccountWithoutOrganizationAcceptsVerifiedAccountRotation() async throws {
        let rotated = AccountCredentialVault.Entry(
            credential: entry(token: "rotated-b", account: "b").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-b"}"#
        )
        try seedShared(base: rotated, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        let saved = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        XCTAssertEqual(saved.credential, rotated.credential)
        XCTAssertEqual(switcher.identity(of: saved, family: "claude")?.identityKey, "acct-b|org-b")
    }

    func testAccountOnlyMetadataShouldSelectVerifiedExistingAccountWithoutRebindingSelectedAccount() async throws {
        let other = try store.add(family: "claude", label: "Other", identityKey: "acct-a|org-a", id: "profile-a")
        let savedA = entry(token: "saved-a", account: "a")
        try switcher.saveSnapshot(savedA, for: other)
        try switcher.writeWorkspaceAuthentication(savedA, for: other)
        store.setPreferred(family: "claude", profileID: other.id)
        let bare = AccountCredentialVault.Entry(
            credential: entry(token: "rotated-b", account: "b").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-b"}"#)
        try seedShared(base: bare, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let rootBefore = try Data(contentsOf: rootState)
        let credentialBefore = keychain.currentUserValues[baseService]

        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)

        XCTAssertEqual(result, .updated(profileID: profile.id))
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id)
        XCTAssertEqual(store.profile(id: other.id)?.identityKey, "acct-a|org-a")
        XCTAssertEqual(try switcher.loadSnapshot(for: other), savedA)
        let target = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        XCTAssertEqual(switcher.identity(of: target, family: "claude")?.identityKey, "acct-b|org-b")
        XCTAssertEqual(try Data(contentsOf: rootState), rootBefore)
        XCTAssertEqual(keychain.currentUserValues[baseService], credentialBefore)
    }

    func testUnchangedAccountOnlySnapshotStillRequiresOrganizationVerification() async throws {
        let bare = AccountCredentialVault.Entry(
            credential: entry(token: "rotated-b", account: "b").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-b"}"#)
        try switcher.saveSnapshot(bare, for: profile)
        try switcher.writeWorkspaceAuthentication(bare, for: profile)
        try seedShared(base: bare, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let before = try captureArtifacts()
        let result = try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store)
        XCTAssertEqual(result, .updated(profileID: profile.id))
        let snapshot = try XCTUnwrap(switcher.loadSnapshot(for: profile))
        XCTAssertEqual(switcher.identity(of: snapshot, family: "claude")?.identityKey, "acct-b|org-b")
        XCTAssertEqual(http.requests.count, 1)
        try assertCLIUnchanged(before)
    }

    func testAccountOnlyMetadataChangingDuringVerificationPreservesSnapshots() async throws {
        let bare = AccountCredentialVault.Entry(
            credential: entry(token: "rotated-b", account: "b").credential,
            claudeOAuthAccount: #"{"accountUuid":"acct-b"}"#)
        try seedShared(base: bare, baseTime: 300, scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let previous = try switcher.loadSnapshot(for: profile)
        let newer = entry(token: "external-c", account: "c")
        http.beforeResponse = { [keychain = keychain!, baseService, rootState] in
            keychain.currentUserValues[baseService] = newer.credential
            try Data(#"{"oauthAccount":\#(newer.claudeOAuthAccount!)}"#.utf8).write(to: rootState)
        }
        let result = await claudeReconciliationResult(importer, in: store)
        XCTAssertThrowsError(try result.get())
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), previous)
        XCTAssertEqual(try switcher.readSharedClaudeAuthenticationForReadiness(), newer)
        XCTAssertEqual(store.profile(id: profile.id), profile)
    }

    func testSelectionChangedDuringProfileRequestDiscardsTheObservation() async throws {
        let other = try store.add(family: "claude", label: "Other", identityKey: "acct-c|org-c", id: "profile-c")
        try seedShared(
            base: entry(token: "rotated-b", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let previous = try switcher.loadSnapshot(for: profile)
        let started = expectation(description: "profile request started")
        let gate = SwitchRecoveryReadGate(started: started)
        http.beforeResponse = { try gate.pauseOnce() }
        defer { gate.release() }
        let task = Task { try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store) }
        await fulfillment(of: [started], timeout: 3)
        store.setPreferred(family: "claude", profileID: other.id)
        gate.release()

        let result = try await task.value

        XCTAssertEqual(result, .unchanged)
        XCTAssertEqual(try switcher.loadSnapshot(for: profile), previous)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), other.id)
    }

    func testSnapshotWriteFailurePreservesCLIAuthenticationAndBothAccounts() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let external = AccountSwitchRecoveryFixture.entry("b", token: "new-b")
        fixture.keychain.currentUserValues[fixture.baseService] = external.credential
        let stateURL = fixture.root.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":\#(external.claudeOAuthAccount!)}"#.utf8).write(to: stateURL)
        let before = try fixture.switcher.readClaudeSwitchState()
        let targetService = AccountCredentialVault.service(family: "claude", profileID: fixture.b.id)
        var failOnce = true
        fixture.keychain.beforeWrite = { service, _ in
            if service == targetService, failOnce {
                failOnce = false
                throw SwitchRecoveryKeychain.Failure.injected
            }
        }
        let http = ClaudeReconciliationHTTPClient()
        http.identities["new-b"] = "acct-b|org-b"
        let importer = AccountCredentialImporter(
            keychain: fixture.keychain, environment: FakeEnvironment(),
            homeDirectory: fixture.root, workspace: fixture.workspace, httpClient: http
        )

        let result = await claudeReconciliationResult(importer, in: fixture.store)

        XCTAssertThrowsError(try result.get())
        XCTAssertFalse(failOnce)
        try fixture.assertSavedAccountsUnchanged()
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), before)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
    }

    func testMalformedProfileAndNetworkFailurePreserveAuthentication() async throws {
        try seedShared(
            base: entry(token: "rotated-b", account: "b"), baseTime: 300,
            scoped: entry(token: "scoped-b", account: "b"), scopedTime: 100)
        let before = try captureArtifacts()
        http.response = HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"account":{}}"#.utf8))
        let malformed = await claudeReconciliationResult(importer, in: store)
        XCTAssertThrowsError(try malformed.get())
        try assertPreserved(before)
        http.beforeResponse = { throw URLError(.timedOut) }
        let network = await claudeReconciliationResult(importer, in: store)
        XCTAssertThrowsError(try network.get())
        try assertPreserved(before)
    }

    private func assertCLIUnchanged(_ before: Artifacts, file: StaticString = #filePath, line: UInt = #line) throws {
        for service in [baseService, scopedService] {
            XCTAssertEqual(
                keychain.currentUserValues[service], before.currentUserValues[service], file: file, line: line)
            XCTAssertEqual(
                keychain.currentUserModificationDates[service], before.currentUserModificationDates[service],
                file: file, line: line)
        }
        for url in [rootState, localState, sharedHome.appendingPathComponent(".credentials.json")] {
            XCTAssertEqual(try Data(contentsOf: url), before.files[url.path], file: file, line: line)
        }
    }

    private var sharedHome: URL { root.appendingPathComponent(".claude") }
    private var rootState: URL { root.appendingPathComponent(".claude.json") }
    private var localState: URL { sharedHome.appendingPathComponent(".claude.json") }
    private var baseService: String { ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment()) }
    private var scopedService: String {
        ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: sharedHome.path, environment: FakeEnvironment()
        )
    }

    private func entry(token: String, account: String, refreshToken: String? = nil) -> AccountCredentialVault.Entry {
        AccountCredentialVault.Entry(
            credential:
                #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"\#(refreshToken ?? "refresh-" + account)"}}"#,
            claudeOAuthAccount: #"{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}"#
        )
    }

    private func seedShared(
        base: AccountCredentialVault.Entry, baseTime: TimeInterval,
        scoped: AccountCredentialVault.Entry, scopedTime: TimeInterval
    ) throws {
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        keychain.currentUserValues[scopedService] = scoped.credential
        keychain.currentUserValues[baseService] = base.credential
        keychain.currentUserModificationDates[scopedService] = Date(timeIntervalSince1970: scopedTime)
        keychain.currentUserModificationDates[baseService] = Date(timeIntervalSince1970: baseTime)
        try writeState(scoped, at: localState, time: scopedTime, marker: "local")
        try writeState(base, at: rootState, time: baseTime, marker: "root")
        let credentialFile = sharedHome.appendingPathComponent(".credentials.json")
        try Data(scoped.credential.utf8).write(to: credentialFile)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: scopedTime)], ofItemAtPath: credentialFile.path
        )
    }

    private func writeState(
        _ credential: AccountCredentialVault.Entry, at url: URL, time: TimeInterval, marker: String
    ) throws {
        let account = try XCTUnwrap(credential.claudeOAuthAccount)
        try Data(#"{"keep":"\#(marker)","oauthAccount":\#(account)}"#.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: time)], ofItemAtPath: url.path
        )
    }

    private struct Artifacts {
        var values: [String: String]
        var currentUserValues: [String: String]
        var modificationDates: [String: Date]
        var currentUserModificationDates: [String: Date]
        var files: [String: Data]
        var registry: Data?
    }

    private func captureArtifacts() throws -> Artifacts {
        let workspaceHome = try workspace.directory(family: "claude", profileID: profile.id)
        let urls = [
            rootState, localState, sharedHome.appendingPathComponent(".credentials.json"),
            workspaceHome.appendingPathComponent(".claude.json"),
            workspaceHome.appendingPathComponent(".credentials.json")
        ]
        var files: [String: Data] = [:]
        for url in urls where FileManager.default.fileExists(atPath: url.path) {
            files[url.path] = try Data(contentsOf: url)
        }
        return Artifacts(
            values: keychain.values, currentUserValues: keychain.currentUserValues,
            modificationDates: keychain.modificationDates,
            currentUserModificationDates: keychain.currentUserModificationDates,
            files: files, registry: defaults.data(forKey: AccountProfilesStore.storageKey)
        )
    }

    private func assertPreserved(_ before: Artifacts, file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try captureArtifacts()
        XCTAssertEqual(after.values, before.values, file: file, line: line)
        XCTAssertEqual(after.currentUserValues, before.currentUserValues, file: file, line: line)
        XCTAssertEqual(after.modificationDates, before.modificationDates, file: file, line: line)
        XCTAssertEqual(after.currentUserModificationDates, before.currentUserModificationDates, file: file, line: line)
        XCTAssertEqual(after.files, before.files, file: file, line: line)
        XCTAssertEqual(after.registry, before.registry, file: file, line: line)
        XCTAssertEqual(store.profile(id: profile.id), profile, file: file, line: line)
        XCTAssertEqual(store.preferredProfileID(family: "claude"), profile.id, file: file, line: line)
        XCTAssertEqual(store.authenticationRevision, 0, file: file, line: line)
        XCTAssertNil(try store.pendingIdentityReplacement(), file: file, line: line)
    }
}
