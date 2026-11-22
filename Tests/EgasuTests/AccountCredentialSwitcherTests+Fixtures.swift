import XCTest
@testable import Egasu

extension AccountCredentialSwitcherTests {
    struct Fixture {
        let home: URL
        let keychain: SwitcherTestKeychain
        let workspace: AccountSignInWorkspace
        let http: ClaudeReconciliationHTTPClient
        let switcher: AccountCredentialSwitcher
        let vault: AccountCredentialVault
    }

    func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EgasuTests.AccountCredentialSwitcher.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let home = root.resolvingSymlinksInPath().standardizedFileURL
        let keychain = SwitcherTestKeychain()
        let workspace = AccountSignInWorkspace(
            baseDirectory: home.appendingPathComponent("AppSupport/egasu/AccountSignIn")
        )
        let http = ClaudeReconciliationHTTPClient()
        http.identities = ["token-a": "acct-a|org-a", "token-a-new": "acct-a|org-a"]
        let switcher = AccountCredentialSwitcher(
            keychain: keychain,
            environment: FakeEnvironment(["SHELL": "/bin/zsh"]),
            homeDirectory: home,
            workspace: workspace,
            httpClient: http
        )
        return Fixture(
            home: home,
            keychain: keychain,
            workspace: workspace,
            http: http,
            switcher: switcher,
            vault: AccountCredentialVault(keychain: keychain)
        )
    }

    func credentialWithExtras(token: String, marker: String) throws -> String {
        var fields = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(claudeCredential(token: token).utf8)) as? [String: Any])
        fields["mcpOAuth"] = ["server": marker]
        fields["unknownField"] = marker
        return String(
            decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self)
    }

    func profile(id: String, family: String, label: String, identityKey: String) -> AccountProfile {
        AccountProfile(id: id, family: family, label: label, identityKey: identityKey, createdAt: .distantPast)
    }

    func claudeCredential(token: String) -> String {
        #"{"claudeAiOauth":{"accessToken":"\#(token)","refreshToken":"refresh-\#(token)"}}"#
    }

    func claudeAccount(_ suffix: String) -> String {
        #"{"accountUuid":"acct-\#(suffix)","emailAddress":"\#(suffix)@example.com","organizationName":"Org","organizationUuid":"org-\#(suffix)"}"#
    }

    func codexAuth(accountID: String, token: String) -> String {
        #"{"tokens":{"access_token":"\#(token)","account_id":"\#(accountID)"}}"#
    }

    /// 로그인된 shared Claude home — 보존 관측용으로 추가 키 포함
    func seedClaudeSharedHome(_ fixture: Fixture, token: String, account: String) throws {
        let sharedHome = fixture.home.appendingPathComponent(".claude")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        try Data(claudeCredential(token: token).utf8)
            .write(to: sharedHome.appendingPathComponent(".credentials.json"))
        fixture.keychain.currentUserValues[baseClaudeService()] = claudeCredential(token: token)
        let accountObject = try JSONSerialization.jsonObject(with: Data(account.utf8))
        let defaultState: [String: Any] = [
            "memory": "keep",
            "hasCompletedOnboarding": true,
            "oauthAccount": accountObject
        ]
        try JSONSerialization.data(withJSONObject: defaultState, options: [.sortedKeys])
            .write(to: fixture.home.appendingPathComponent(".claude.json"))
        let localState: [String: Any] = [
            "projects": ["/tmp/project": ["allowedTools": [String]()]],
            "oauthAccount": accountObject
        ]
        try JSONSerialization.data(withJSONObject: localState, options: [.sortedKeys])
            .write(to: sharedHome.appendingPathComponent(".claude.json"))
    }

    func seedCodexSharedHome(_ fixture: Fixture, accountID: String, token: String) throws {
        let sharedHome = fixture.home.appendingPathComponent(".codex")
        try FileManager.default.createDirectory(at: sharedHome, withIntermediateDirectories: true)
        try Data(codexAuth(accountID: accountID, token: token).utf8)
            .write(to: sharedHome.appendingPathComponent("auth.json"))
    }

    func baseClaudeService() -> String {
        ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment([:]))
    }

    func scopedClaudeService(home: String) -> String {
        ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: home, environment: FakeEnvironment([:]))
    }

    func text(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    func state(at url: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: url)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

/// service 단위 keychain double — switcher가 service 주소 기반이라 service를 모르는 `FakeKeychain`으로 대체 불가
final class SwitcherTestKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String] = [:]
    var currentUserValues: [String: String] = [:]
    var writeCount = 0
    var failingCurrentUserServices: Set<String> = []
    var onRejectedWrite: (() throws -> Void)?
    var afterSharedWrite: ((SwitcherTestKeychain, String) throws -> Void)?
    var onSharedRead: (() throws -> Void)?

    struct WriteFailure: Error {}

    func readGenericPassword(service: String) throws -> String? { values[service] }

    func writeGenericPassword(service: String, value: String) throws {
        writeCount += 1
        values[service] = value
    }

    func writeCLISharedPassword(service: String, value: String, forCurrentUser: Bool) throws {
        if forCurrentUser {
            try writeGenericPasswordForCurrentUser(service: service, value: value)
        } else {
            try writeGenericPassword(service: service, value: value)
        }
        try afterSharedWrite?(self, service)
    }

    func deleteGenericPassword(service: String) throws {
        values.removeValue(forKey: service)
        currentUserValues.removeValue(forKey: service)
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? { currentUserValues[service] }

    func readCLISharedPassword(service: String, forCurrentUser: Bool) throws -> String? {
        try onSharedRead?()
        return forCurrentUser ? currentUserValues[service] : values[service]
    }

    func writeGenericPasswordForCurrentUser(service: String, value: String) throws {
        if failingCurrentUserServices.contains(service) {
            try onRejectedWrite?()
            throw WriteFailure()
        }
        writeCount += 1
        currentUserValues[service] = value
    }
}
