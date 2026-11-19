import XCTest
@testable import Egasu

final class AccountReadinessInteractionTests: XCTestCase {
    @MainActor
    func testUserInitiatedSwitchAllowsKeychainApprovalForDepartureVerification() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let rotated = try fixture.rotateDefaultCredentials()
        let initialReads = fixture.keychain.noninteractiveReadServices.count

        try await fixture.selectionSwitcher.switchAuthentication(to: fixture.b, in: fixture.store)

        XCTAssertFalse(
            fixture.keychain.noninteractiveReadServices.dropFirst(initialReads).contains(fixture.baseService))
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.b.id)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.a), rotated)
        XCTAssertNil(try fixture.journal.load())
    }

    @MainActor
    func testUnchangedExternalLoginIsObservedTwiceWithRequestedPolicyWithoutWriting() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ReconciliationPolicy-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let name = "EgasuTests.ReconciliationPolicy.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profiles = AccountProfilesStore(defaults: defaults)
        let profile = try profiles.add(family: "claude", label: "Work", identityKey: "account|organization")
        profiles.setPreferred(family: "claude", profileID: profile.id)
        let account = #"{"accountUuid":"account","organizationUuid":"organization"}"#
        try Data("{\"oauthAccount\":\(account)}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let environment = FakeEnvironment([:])
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let credential = #"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#

        for allowInteraction in [false, true] {
            let keychain = PolicyRecordingKeychain(sharedService: service, sharedCredential: credential)
            try AccountCredentialVault(keychain: keychain).save(
                .init(credential: credential, claudeOAuthAccount: account), profile: profile)
            let importer = AccountCredentialImporter(
                keychain: keychain, environment: environment, homeDirectory: home,
                workspace: AccountSignInWorkspace(baseDirectory: home.appendingPathComponent("workspaces")),
                httpClient: UnexpectedReadinessNetwork())

            let initialWrites = keychain.writeCount
            let initialRegistry = defaults.data(forKey: AccountProfilesStore.storageKey)
            let result = try await ProviderRefreshContext.$isManual.withValue(allowInteraction) {
                try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: profiles)
            }

            XCTAssertEqual(result, .unchanged)
            let vault = AccountCredentialVault.service(family: "claude", profileID: profile.id)
            XCTAssertEqual(keychain.reads.map(\.service), [vault, service, service, vault, service, service])
            XCTAssertEqual(keychain.reads.map(\.forCurrentUser), [true, true, false, true, true, false])
            XCTAssertTrue(keychain.reads.allSatisfy { $0.allowInteraction == allowInteraction })
            XCTAssertEqual(keychain.legacyReads, 0)
            XCTAssertEqual(keychain.writeCount, initialWrites)
            XCTAssertEqual(defaults.data(forKey: AccountProfilesStore.storageKey), initialRegistry)
            XCTAssertNil(try profiles.pendingIdentityReplacement())
            XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("workspaces").path))
        }
    }

    func testMalformedSharedStateNeedsSignInInsteadOfKeychainApproval() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("MalformedReadiness-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        try Data("invalid-json".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let environment = FakeEnvironment([:])
        let credential = #"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#
        let keychain = PolicyRecordingKeychain(
            sharedService: ClaudeAuthStore.baseKeychainServiceName(environment: environment),
            sharedCredential: credential)
        let profile = AccountProfile(
            id: "work", family: "claude", label: "Work", identityKey: "account|organization", createdAt: .distantPast)
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: credential,
                claudeOAuthAccount: #"{"accountUuid":"account","organizationUuid":"organization"}"#),
            profile: profile)

        let state = AccountSignInProbe(environment: environment, keychain: keychain, homeDirectory: { home })
            .state(for: profile, isSelected: true)

        XCTAssertEqual(state, .needsSignIn)
    }

    func testSelectedClaudeUsesTheRequestedInteractionPolicyForEverySharedKeychainRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ReadinessInteraction-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = #"{"accountUuid":"account","organizationUuid":"organization"}"#
        try Data("{\"oauthAccount\":\(account)}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let environment = FakeEnvironment([:])
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let credential = #"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#
        let profile = AccountProfile(
            id: "work", family: "claude", label: "Work", identityKey: "account|organization", createdAt: .distantPast)

        for allowInteraction in [false, true] {
            let keychain = PolicyRecordingKeychain(sharedService: service, sharedCredential: credential)
            try AccountCredentialVault(keychain: keychain).save(
                .init(credential: credential, claudeOAuthAccount: account), profile: profile)
            let probe = AccountSignInProbe(environment: environment, keychain: keychain, homeDirectory: { home })

            XCTAssertTrue(probe.state(for: profile, isSelected: true, allowInteraction: allowInteraction).isReady)

            let sharedReads = keychain.reads.filter { $0.service == service }
            XCTAssertEqual(sharedReads.map(\.forCurrentUser), [true, false], "사용자 범위와 서비스 범위 모두 확인")
            XCTAssertTrue(sharedReads.allSatisfy { $0.allowInteraction == allowInteraction })
            XCTAssertTrue(keychain.reads.allSatisfy { $0.allowInteraction == allowInteraction }, "저장 인증도 같은 정책 사용")
            XCTAssertEqual(keychain.legacyReads, 0, "수동 승인과 자동 조회는 같은 앱의 Keychain 접근 사용")
        }
    }
}

private struct UnexpectedReadinessNetwork: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw URLError(.unsupportedURL)
    }
}

private final class PolicyRecordingKeychain: KeychainAccessing, @unchecked Sendable {
    struct Read {
        let service: String
        let forCurrentUser: Bool
        let allowInteraction: Bool
    }

    private let sharedService: String
    private let sharedCredential: String
    private var saved: [String: String] = [:]
    private(set) var reads: [Read] = []
    private(set) var legacyReads = 0
    private(set) var writeCount = 0

    init(sharedService: String, sharedCredential: String) {
        self.sharedService = sharedService
        self.sharedCredential = sharedCredential
    }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        reads.append(Read(service: service, forCurrentUser: forCurrentUser, allowInteraction: allowInteraction))
        return saved[service]
    }

    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        reads.append(Read(service: service, forCurrentUser: true, allowInteraction: allowInteraction))
        return nil
    }

    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        reads.append(Read(service: service, forCurrentUser: false, allowInteraction: allowInteraction))
        return service == sharedService ? sharedCredential : saved[service]
    }

    func readGenericPassword(service: String) throws -> String? {
        legacyReads += 1
        reads.append(Read(service: service, forCurrentUser: false, allowInteraction: true))
        return service == sharedService ? sharedCredential : saved[service]
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        legacyReads += 1
        reads.append(Read(service: service, forCurrentUser: true, allowInteraction: true))
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws {
        writeCount += 1
        saved[service] = value
    }

    func deleteGenericPassword(service: String) throws {
        writeCount += 1
        saved.removeValue(forKey: service)
    }
}
