import XCTest
@testable import Egasu

@MainActor
final class AccountFirstImportVerificationTests: XCTestCase {
    func testFirstImportRejectsMixedTokenAndMetadataWithoutCreatingArtifacts() async throws {
        for identity in ["acct-c|org-c", "acct-a|other-org"] {
            let fixture = try makeFixture()
            fixture.http.identities["token-a"] = identity
            let original = try fixture.switcher.readClaudeSwitchState()

            do {
                _ = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
                XCTFail("A foreign token must not be registered using the local account metadata")
            } catch {
                XCTAssertEqual(
                    error as? AccountCredentialImporter.ImportError, .verificationFailed(family: "claude")
                )
            }

            try assertNoRegistration(fixture)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), original)
            XCTAssertEqual(fixture.http.requests.count, 1)
        }
    }

    func testFirstImportStoresTheVerifiedCredentialWithoutChangingCLIAuthentication() async throws {
        let fixture = try makeFixture()
        let original = try fixture.switcher.readClaudeSwitchState()
        let expected = try fixture.switcher.readSharedAuthentication(family: "claude")

        let imported = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
        let profile = try XCTUnwrap(imported)

        XCTAssertEqual(profile.identityKey, "acct-a|org-a")
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), profile.id)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: profile), expected)
        let home = try fixture.workspace.directory(family: "claude", profileID: profile.id).path
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "claude", home: home), expected)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), original)
        XCTAssertEqual(fixture.http.requests.count, 1)
    }

    func testFirstImportCompletesAccountOnlyMetadataWithoutChangingSharedLogin() async throws {
        let fixture = try makeFixture()
        let rootState = fixture.root.appendingPathComponent(".claude.json")
        try Data(#"{"oauthAccount":{"accountUuid":"acct-a","unknown":"preserve"}}"#.utf8).write(to: rootState)
        let original = try fixture.switcher.readClaudeSwitchState()
        let rootData = try Data(contentsOf: rootState)
        let imported = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
        let profile = try XCTUnwrap(imported)
        XCTAssertEqual(profile.identityKey, "acct-a|org-a")
        let snapshot = try XCTUnwrap(fixture.switcher.loadSnapshot(for: profile))
        XCTAssertEqual(fixture.switcher.identity(of: snapshot, family: "claude")?.identityKey, profile.identityKey)
        let raw = try XCTUnwrap(snapshot.claudeOAuthAccount)
        let account = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(account["unknown"] as? String, "preserve")
        XCTAssertEqual(try Data(contentsOf: rootState), rootData)
        XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), original)
    }

    func testProfileAndNetworkFailuresLeaveTheRegistryAndStorageEmpty() async throws {
        for failure in ["401", "429", "500", "malformed", "network"] {
            let fixture = try makeFixture()
            if failure == "network" {
                fixture.http.beforeResponse = { throw URLError(.timedOut) }
            } else {
                fixture.http.response = HTTPResponse(
                    statusCode: Int(failure) ?? 200, headers: [:], body: Data()
                )
            }
            let original = try fixture.switcher.readClaudeSwitchState()

            await assertSwitchFails {
                _ = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
            }

            try assertNoRegistration(fixture)
            XCTAssertEqual(try fixture.switcher.readClaudeSwitchState(), original)
            XCTAssertEqual(fixture.http.requests.count, 1)
        }
    }

    func testSharedLoginChangeDuringVerificationLeavesNewLoginAndStorageUntouched() async throws {
        for mutation in ["token", "metadata"] {
            let fixture = try makeFixture()
            let external = AccountSwitchRecoveryFixture.entry("c")
            fixture.http.beforeResponse = {
                [keychain = fixture.keychain, base = fixture.baseService, root = fixture.root] in
                if mutation == "token" {
                    keychain.currentUserValues[base] = external.credential
                } else {
                    try Data(#"{"oauthAccount":\#(external.claudeOAuthAccount!)}"#.utf8)
                        .write(to: root.appendingPathComponent(".claude.json"))
                }
            }

            await assertSwitchFails {
                _ = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
            }

            try assertNoRegistration(fixture)
            if mutation == "token" {
                XCTAssertEqual(fixture.keychain.currentUserValues[fixture.baseService], external.credential)
            } else {
                let shared = try XCTUnwrap(fixture.switcher.readSharedAuthentication(family: "claude"))
                XCTAssertEqual(fixture.switcher.identity(of: shared, family: "claude")?.identityKey, "acct-c|org-c")
            }
        }
    }

    func testFirstImportRejectsSameTokenMovedToAnotherStoreDuringVerification() async throws {
        let fixture = try makeFixture()
        let source = try XCTUnwrap(fixture.keychain.currentUserValues[fixture.baseService])
        let directory = fixture.root.appendingPathComponent(".claude")
        let keychain = fixture.keychain
        let service = fixture.baseService
        fixture.http.beforeResponse = {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(source.utf8).write(to: directory.appendingPathComponent(".credentials.json"))
            keychain.currentUserValues.removeValue(forKey: service)
        }
        do {
            _ = try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
            XCTFail("Expected the source change to stop the import")
        } catch {
            XCTAssertEqual(error as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertTrue(fixture.store.profiles.isEmpty)
        XCTAssertTrue(keychain.currentUserValues.isEmpty)
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent(".credentials.json"), encoding: .utf8), source)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.workspace.baseDirectory.path))
    }

    func testRegistryChangesAndCancellationDuringVerificationPreventRegistration() async throws {
        for mutation in ["registry", "revision", "cancellation"] {
            let fixture = try makeFixture()
            let other =
                mutation == "revision"
                ? try fixture.store.add(family: "codex", label: "Other", identityKey: "other") : nil
            let started = expectation(description: "First import profile request: \(mutation)")
            let gate = SwitchRecoveryReadGate(started: started)
            fixture.http.beforeResponse = { try gate.pauseOnce() }
            defer { gate.release() }
            let task = Task {
                try await fixture.importer.importDefaultAccount(family: "claude", into: fixture.store)
            }
            await fulfillment(of: [started], timeout: 3)
            switch mutation {
            case "registry":
                _ = try fixture.store.add(family: "claude", label: "Other", identityKey: "other")
            case "revision":
                let other = try XCTUnwrap(other)
                let replacement = try fixture.store.beginIdentityReplacement(
                    profileID: other.id, with: other.identityKey, replacesSharedAuthentication: false
                )
                _ = try fixture.store.commitIdentityReplacement(replacement)
            default:
                task.cancel()
            }
            let registry = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)
            let preferred = fixture.store.preferredProfileID(family: "claude")
            gate.release()
            do {
                _ = try await task.value
                XCTFail("Changed or cancelled first imports must fail")
            } catch {
                if mutation == "cancellation" {
                    XCTAssertTrue(error is CancellationError)
                } else {
                    XCTAssertEqual(
                        error as? AccountCredentialImporter.ImportError, .verificationFailed(family: "claude"))
                }
            }

            XCTAssertEqual(fixture.defaults.data(forKey: AccountProfilesStore.storageKey), registry)
            XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), preferred)
            try assertNoCredentialArtifacts(fixture)
        }
    }

    func testLocalDetectionDoesNotRequestProfile() throws {
        let fixture = try makeFixture()

        let observed = try fixture.importer.readDefaultCredential(family: "claude")

        XCTAssertEqual(observed?.identityKey, "acct-a|org-a")
        XCTAssertTrue(fixture.http.requests.isEmpty)
        try assertNoRegistration(fixture)
    }

    private struct Fixture {
        let root: URL
        let defaults: UserDefaults
        let store: AccountProfilesStore
        let keychain: ServiceKeychain
        let workspace: AccountSignInWorkspace
        let switcher: AccountCredentialSwitcher
        let importer: AccountCredentialImporter
        let http: ClaudeReconciliationHTTPClient

        var baseService: String { ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment()) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AccountFirstImportTests-\(UUID().uuidString)")
            .resolvingSymlinksInPath().standardizedFileURL
        let suite = "AccountFirstImportTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let keychain = ServiceKeychain()
        let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("AccountSignIn"))
        let http = ClaudeReconciliationHTTPClient()
        http.identities = ["token-a": "acct-a|org-a"]
        let switcher = AccountCredentialSwitcher(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root,
            workspace: workspace, httpClient: http
        )
        try switcher.applySharedAuthentication(AccountSwitchRecoveryFixture.entry("a"), family: "claude")
        let importer = AccountCredentialImporter(
            keychain: keychain, environment: FakeEnvironment(), homeDirectory: root,
            workspace: workspace, httpClient: http
        )
        addTeardownBlock {
            UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        return Fixture(
            root: root, defaults: defaults, store: AccountProfilesStore(defaults: defaults), keychain: keychain,
            workspace: workspace, switcher: switcher, importer: importer, http: http
        )
    }

    private func assertNoRegistration(
        _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(fixture.store.profiles.isEmpty, file: file, line: line)
        XCTAssertNil(fixture.defaults.data(forKey: AccountProfilesStore.storageKey), file: file, line: line)
        XCTAssertNil(fixture.store.preferredProfileID(family: "claude"), file: file, line: line)
        try assertNoCredentialArtifacts(fixture, file: file, line: line)
    }

    private func assertNoCredentialArtifacts(
        _ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertTrue(fixture.keychain.values.isEmpty, file: file, line: line)
        XCTAssertEqual(
            Set(fixture.keychain.currentUserValues.keys), Set([fixture.baseService]),
            file: file, line: line
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.workspace.baseDirectory.path), file: file, line: line)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement(), file: file, line: line)
    }
}
