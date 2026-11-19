import Foundation

/// 계정 전환의 유일한 credential 이동 경로 — 한 profile의 인증만 family의 Shared Runtime Home(`~/.claude`, `~/.codex`)에 적용.
/// configuration·MCP·memory·plugin·세션 history 불변. reader는 첫 import·re-login·registry migration이 재사용 — 제2의 credential parser 금지.
/// 내부 `FileManager` delegate 미사용 — background credential read와 main-actor transaction에서 공유 가능.
struct AccountCredentialSwitcher: @unchecked Sendable {
    enum Error: LocalizedError, Equatable {
        case unsupportedFamily(String)
        case missingSnapshot(String)
        case snapshotIdentityMismatch(String)
        case invalidClaudeState(URL)
        case incompleteClaudeAuthentication
        case conflictingClaudeAuthentication
        case switchVerificationFailed(String)
        case switchRecoveryRequired
        case selectionSaveFailed

        var errorDescription: String? {
            switch self {
            case .unsupportedFamily(let family):
                "Account switching is not supported for \(family)."
            case .missingSnapshot(let label):
                "No saved sign-in was found for \(label). Sign in again and retry."
            case .snapshotIdentityMismatch(let label):
                "The saved sign-in for \(label) no longer matches its account. Sign in again and retry."
            case .invalidClaudeState(let url):
                "Claude account state is invalid: \(url.path)"
            case .incompleteClaudeAuthentication:
                "Claude sign-in has not finished updating its account state. Finish signing in and try again."
            case .conflictingClaudeAuthentication:
                "Claude sign-ins in different locations conflict. Open Accounts, open the Claude account, then choose Sign In Again."
            case .switchVerificationFailed(let label):
                "Switching to \(label) could not be verified. Check the selected account and try again."
            case .switchRecoveryRequired:
                "Claude account switch recovery is required. Open Accounts, open the Claude account you want to use, then choose Use Claude."
            case .selectionSaveFailed:
                "egasu couldn't save the selected account. The recovery record was kept. Try again."
            }
        }
    }

    let keychain: KeychainAccessing
    private let fileManager: FileManager
    let environment: EnvironmentReading
    let homeDirectory: URL
    private let workspace: AccountSignInWorkspace
    private let claudeUsageClient: ClaudeUsageClient

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        fileManager: FileManager = .default,
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        workspace: AccountSignInWorkspace = AccountSignInWorkspace(),
        httpClient: HTTPClient = URLSessionHTTPClient()
    ) {
        self.keychain = keychain
        self.fileManager = fileManager
        self.environment = environment
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.workspace = workspace
        self.claudeUsageClient = ClaudeUsageClient(httpClient: httpClient)
    }

    // MARK: - Shared Runtime Home

    /// family의 터미널 세션이 공유하는 유일한 home — 전환 모델이 고정, 사용자 편집 불가 경로.
    func sharedHomePath(family: String) -> String {
        homeDirectory.appendingPathComponent(".\(family)").path
    }

    /// Shared Runtime Home의 현재 인증 — 사용 가능한 로그인 없으면 `nil`.
    func readSharedAuthentication(family: String) throws -> AccountCredentialVault.Entry? {
        try readAuthentication(family: family, home: sharedHomePath(family: family))
    }

    var switchJournal: AccountSwitchJournal {
        AccountSwitchJournal(path: workspace.baseDirectory.appendingPathComponent("claude-switch.json").path)
    }

    /// 이전 전환 기록은 세 곳의 원문 지문, 새 기록은 실제 CLI 로그인 출처의 OAuth 지문으로 비교.
    func readClaudeSwitchState(legacyRecord: Bool = false, allowInteraction: Bool = true) throws
        -> AccountSwitchJournal.SharedState
    {
        if !legacyRecord { return try sharedClaudeLogin(allowInteraction: allowInteraction).state }
        let home = sharedHomePath(family: "claude")
        let services = [
            ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: home, environment: environment),
            ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        ]
        var credentials = try services.map { service in
            try keychain.readGenericPasswordForCurrentUser(service: service, allowInteraction: allowInteraction)
                ?? keychain.readGenericPassword(service: service, allowInteraction: allowInteraction)
        }
        credentials.append(try readTextIfPresent(URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")))
        let stateURLs = [
            homeDirectory.appendingPathComponent(".claude.json"),
            URL(fileURLWithPath: home).appendingPathComponent(".claude.json")
        ]
        let accounts = try stateURLs.map { try claudeOAuthAccount(at: $0) }
        let credential = credentials.compactMap { $0 }.first(where: isUsableClaudeCredential) ?? ""
        let identities = accounts.map {
            identity(of: .init(credential: credential, claudeOAuthAccount: $0), family: "claude")?.identityKey
        }
        return .init(credentials: credentials, accounts: accounts, identities: identities)
    }

    /// 선택된 Claude의 터미널 준비 상태용 기본 인증과 루트 계정 정보.
    /// 프로필 API 호출 없이 현재 CLI가 사용할 로그인만 확인 — 영구 저장본 교체와 구분.
    func readSharedClaudeAuthenticationForReadiness(allowInteraction: Bool = false) throws -> AccountCredentialVault.Entry? {
        try sharedClaudeAuthentication(allowInteraction: allowInteraction)
    }

    struct VerifiedClaudeExternalAuthentication: Sendable {
        let observed: AccountCredentialVault.Entry
        let baseline: AccountCredentialVault.Entry?
        let snapshot: AccountCredentialVault.Entry
        let identityKey: String
        let sourceID: String
    }

    func claudeProfile(
        for accessToken: String, timeout: TimeInterval = ClaudeUsageClient.profileTimeout
    ) async throws -> ClaudeProfileResponse {
        let config = try ClaudeAuthStore(environment: environment).oauthConfig()
        let response = try await claudeUsageClient.fetchProfile(
            accessToken: accessToken, config: config, timeout: timeout)
        try ProviderAuthRetry.requireSuccess(
            response, authExpired: ClaudeAuthError.tokenExpired, requestFailed: ClaudeUsageError.requestFailed
        )
        return try JSONDecoder().decode(ClaudeProfileResponse.self, from: response.body)
    }

    /// CLI 인증은 그대로 두고 변경된 토큰의 계정·조직을 확인한 뒤 egasu 저장본에 반영.
    func readSharedClaudeExternalAuthentication(
        comparedTo previousSnapshot: AccountCredentialVault.Entry?, allowInteraction: Bool
    ) async throws -> VerifiedClaudeExternalAuthentication? {
        let state = try readClaudeSwitchState(allowInteraction: allowInteraction)
        guard let login = state.credentials[0], isUsableClaudeCredential(login),
            let expectedIdentity = state.identities[0], let sourceID = state.sourceID
        else { return nil }
        let observed = AccountCredentialVault.Entry(credential: login, claudeOAuthAccount: state.accounts[0])
        if observed == previousSnapshot, expectedIdentity.contains("|") {
            return .init(
                observed: observed, baseline: previousSnapshot, snapshot: observed, identityKey: expectedIdentity,
                sourceID: sourceID
            )
        }
        guard let token = ClaudeAuthStore.parseCredentials(observed.credential)?.claudeAiOauth?.accessToken?.nilIfEmpty
        else { return nil }
        let profile = try await claudeProfile(for: token)
        let verifiedIdentity = try profile.accountIdentityKey()
        let comparableIdentity =
            expectedIdentity.contains("|")
            ? verifiedIdentity : String(verifiedIdentity.prefix { $0 != "|" })
        guard comparableIdentity == expectedIdentity else {
            throw AccountCredentialImporter.ImportError.verificationFailed(family: "claude")
        }
        try Task.checkCancellation()
        var snapshot = observed
        if !expectedIdentity.contains("|") {
            guard let account = observed.claudeOAuthAccount,
                var fields = try JSONSerialization.jsonObject(with: Data(account.utf8)) as? [String: Any]
            else { throw AccountCredentialImporter.ImportError.verificationFailed(family: "claude") }
            fields["organizationUuid"] = profile.organization.uuid.trimmingCharacters(in: .whitespacesAndNewlines)
            snapshot.claudeOAuthAccount = String(
                decoding: try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]), as: UTF8.self
            )
        }
        guard try readClaudeSwitchState(allowInteraction: allowInteraction) == state else {
            throw ClaudeAuthError.credentialsChanged
        }
        return .init(
            observed: observed, baseline: previousSnapshot, snapshot: snapshot, identityKey: verifiedIdentity,
            sourceID: sourceID)
    }

    private func sharedClaudeAuthentication(allowInteraction: Bool = true) throws -> AccountCredentialVault.Entry? {
        try sharedClaudeAuthentication(in: readClaudeSwitchState(allowInteraction: allowInteraction))
    }

    func sharedClaudeAuthentication(in state: AccountSwitchJournal.SharedState) -> AccountCredentialVault.Entry? {
        guard let credential = state.credentials[0], isUsableClaudeCredential(credential) else { return nil }
        return .init(credential: credential, claudeOAuthAccount: state.accounts[0])
    }

    /// 공유 홈·로그인 작업 공간·구형 프로필 홈의 인증 읽기.
    /// Claude 공유 홈은 CLI의 인증 출처와 짝이 맞는 계정 정보, 작업 공간은 홈별 인증 사용. Codex는 auth.json만 사용.
    func readAuthentication(family: String, home: String) throws -> AccountCredentialVault.Entry? {
        switch family {
        case "claude":
            if canonicalPath(home) == canonicalPath(sharedHomePath(family: "claude")) {
                return try sharedClaudeAuthentication()
            }
            guard let credential = readClaudeCredential(home: home) else { return nil }
            let oauthAccount = try claudeOAuthAccount(
                at: URL(fileURLWithPath: home).appendingPathComponent(".claude.json"))
            return .init(
                credential: try ClaudeAccountLoginCredentials.loginOnly(credential), claudeOAuthAccount: oauthAccount)
        case "codex":
            let url = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            guard let text = try readTextIfPresent(url),
                  CodexAuthStore.parseAuth(text)?.tokens?.accessToken?.nilIfEmpty != nil else {
                return nil
            }
            return AccountCredentialVault.Entry(credential: text, claudeOAuthAccount: nil)
        default:
            throw Error.unsupportedFamily(family)
        }
    }

    /// entry의 인증만 Shared Runtime Home에 적용 — 그 외 일체 불변.
    func applySharedAuthentication(
        _ entry: AccountCredentialVault.Entry, family: String,
        expectedClaudeState: AccountSwitchJournal.SharedState? = nil, allowInteraction: Bool = true
    ) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        let home = sharedHomePath(family: family)
        switch family {
        case "claude":
            try AccountCredentialMutationLock.requireIdleClaudeRotation()
            try applySharedClaudeLogin(entry, expecting: expectedClaudeState, allowInteraction: allowInteraction)
        case "codex":
            try writePrivateFile(
                entry.credential,
                to: URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            )
        default:
            throw Error.unsupportedFamily(family)
        }
    }

    // MARK: - Snapshot and workspace

    func loadSnapshot(for profile: AccountProfile, allowInteraction: Bool = false) throws -> AccountCredentialVault.Entry? {
        guard
            var entry = try AccountCredentialVault(keychain: keychain).load(
                profile: profile, allowInteraction: allowInteraction)
        else {
            return nil
        }
        if profile.family == "claude" {
            entry.credential = try ClaudeAccountLoginCredentials.loginOnly(entry.credential)
        }
        return entry
    }

    func saveSnapshot(_ entry: AccountCredentialVault.Entry, for profile: AccountProfile) throws {
        var snapshot = entry
        if profile.family == "claude" {
            snapshot.credential = try ClaudeAccountLoginCredentials.loginOnly(entry.credential)
        }
        try AccountCredentialVault(keychain: keychain).save(snapshot, profile: profile)
    }

    /// entry를 profile의 Sign-In Workspace에 미러링 — 이후 공식 re-login이 최신 credential에서 시작. 일반 세션 home 사용 금지.
    func writeWorkspaceAuthentication(
        _ entry: AccountCredentialVault.Entry, for profile: AccountProfile, allowInteraction: Bool = true
    ) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        let directory = try workspace.prepare(family: profile.family, profileID: profile.id)
        switch profile.family {
        case "claude":
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: directory.path, environment: environment)
            let existing = try keychain.readGenericPasswordForCurrentUser(
                service: service, allowInteraction: allowInteraction)
            let keychainCredential = try ClaudeAccountLoginCredentials.replacingLogin(
                in: existing, with: entry.credential)
            let url = directory.appendingPathComponent(".credentials.json")
            let fileCredential = try ClaudeAccountLoginCredentials.replacingLogin(
                in: readTextIfPresent(url), with: entry.credential)
            try keychain.writeCLISharedPassword(
                service: service,
                value: keychainCredential,
                forCurrentUser: true
            )
            try writePrivateFile(fileCredential, to: url)
            if let oauthAccount = entry.claudeOAuthAccount {
                try mergeClaudeOAuthAccount(oauthAccount, at: directory.appendingPathComponent(".claude.json"))
            }
        case "codex":
            try writePrivateFile(entry.credential, to: directory.appendingPathComponent("auth.json"))
        default:
            throw Error.unsupportedFamily(profile.family)
        }
    }

    // MARK: - Identity

    /// entry가 담은 provider 증명 identity — credential이 계정을 특정 못 하면 `nil`, copy·switch·rotation 보존 모두 `nil`에서 중단.
    func identity(of entry: AccountCredentialVault.Entry, family: String) -> (identityKey: String, label: String?)? {
        switch family {
        case "claude":
            guard isUsableClaudeCredential(entry.credential),
                let account = entry.claudeOAuthAccount,
                let decoded = try? JSONDecoder().decode(
                    DefaultAccountObserver.ClaudeStateFile.OAuthAccount.self,
                    from: Data(account.utf8)
                ),
                let key = DefaultAccountObserver.claudeIdentityKey(decoded)
            else { return nil }
            return (key, DefaultAccountObserver.claudeIdentityLabel(decoded))
        case "codex":
            return DefaultAccountObserver.codexFileIdentity(authText: entry.credential)
        default:
            return nil
        }
    }

    // MARK: - Claude plumbing

    private func readClaudeCredential(home: String) -> String? {
        let scopedService = ClaudeAuthStore.scopedKeychainServiceName(
            forConfigDirLiteral: home,
            environment: environment
        )
        if let value = try? keychain.readGenericPasswordForCurrentUser(service: scopedService),
            isUsableClaudeCredential(value)
        {
            return value
        }
        if let value = try? keychain.readGenericPassword(service: scopedService),
            isUsableClaudeCredential(value)
        {
            return value
        }
        let fileURL = URL(fileURLWithPath: home).appendingPathComponent(".credentials.json")
        if let value = try? readTextIfPresent(fileURL), isUsableClaudeCredential(value) {
            return value
        }
        return nil
    }

    func claudeOAuthAccount(at url: URL) throws -> String? {
        guard let text = try readTextIfPresent(url) else { return nil }
        guard let state = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw Error.invalidClaudeState(url)
        }
        guard let value = state["oauthAccount"], !(value is NSNull) else { return nil }
        guard let account = value as? [String: Any] else { throw Error.invalidClaudeState(url) }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys]), as: UTF8.self)
    }

    /// workspace sign-in이 만든 provider-scoped 로그인 credential 삭제.
    /// Claude Code는 `CLAUDE_CONFIG_DIR` literal 스코프의 Keychain item에 로그인 저장 — 미삭제 시 제거된 계정의 token이 profile보다 오래 생존. Codex workspace는 파일 전용.
    func removeWorkspaceCredentialArtifacts(family: String, profileID: String) throws {
        guard family == "claude" else { return }
        let home = try workspace.directory(family: family, profileID: profileID).path
        try keychain.deleteGenericPassword(
            service: ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: home,
                environment: environment
            )
        )
    }

    /// Claude state 파일에 `oauthAccount` 키만 merge, 다른 키 전부 보존 — 파일 부재 시 onboarding-complete 최소 state 생성으로 first-run 재생 방지.
    func mergeClaudeOAuthAccount(_ account: String?, at url: URL, removeCreatedState: Bool = false) throws {
        let oauthAccount = try account.map { try JSONSerialization.jsonObject(with: Data($0.utf8)) }
        var state: [String: Any] = [:]
        if let text = try readTextIfPresent(url) {
            guard let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Error.invalidClaudeState(url)
            }
            state = parsed
        } else {
            guard account != nil else { return }
            state["hasCompletedOnboarding"] = true
        }
        state["oauthAccount"] = oauthAccount
        if removeCreatedState, account == nil, state.count == 1, state["hasCompletedOnboarding"] as? Bool == true {
            try fileManager.removeItem(at: url)
            return
        }
        let data = try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys])
        try writePrivateData(data, to: url)
    }

    // MARK: - Files

    private func readTextIfPresent(_ url: URL) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try String(contentsOf: url, encoding: .utf8)
    }

    func writePrivateFile(_ text: String, to url: URL) throws {
        try writePrivateData(Data(text.utf8), to: url)
    }

    private func writePrivateData(_ data: Data, to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try data.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func isUsableClaudeCredential(_ value: String) -> Bool {
        guard let oauth = ClaudeAuthStore.parseCredentials(value)?.claudeAiOauth,
              oauth.accessToken?.nilIfEmpty != nil
        else {
            return false
        }
        guard let expiresAt = oauth.expiresAt,
              expiresAt <= Date().timeIntervalSince1970 * 1_000
        else {
            return true
        }
        return oauth.refreshToken?.nilIfEmpty != nil
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
