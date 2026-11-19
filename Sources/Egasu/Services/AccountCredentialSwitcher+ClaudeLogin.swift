import Foundation

/// 계정과 함께 옮길 수 있는 Claude Code OAuth와 각 저장소에 속한 나머지 필드를 분리.
enum ClaudeAccountLoginCredentials {
    static func loginOnly(_ credential: String) throws -> String {
        try replacingLogin(in: nil, with: credential)
    }

    static func replacingLogin(in destination: String?, with credential: String?) throws -> String {
        var document: [String: Any] = [:]
        if let destination {
            guard let existing = ProviderParse.jsonObjectWithHexFallback(destination) else {
                throw AccountCredentialSwitcher.Error.incompleteClaudeAuthentication
            }
            document = existing
        }
        if let credential {
            guard let login = ProviderParse.jsonObjectWithHexFallback(credential)?["claudeAiOauth"] as? [String: Any]
            else { throw AccountCredentialSwitcher.Error.incompleteClaudeAuthentication }
            document["claudeAiOauth"] = login
        } else {
            document.removeValue(forKey: "claudeAiOauth")
        }
        return String(
            decoding: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self)
    }
}

extension AccountCredentialSwitcher {
    struct SharedClaudeLogin {
        let source: ClaudeCredentialState.Source
        let stateURL: URL
        let stateFileExisted: Bool
        let rawCredential: String?
        let storedOAuth: String?
        let allowInteraction: Bool
        let state: AccountSwitchJournal.SharedState
    }

    func sharedClaudeLogin(
        route explicitRoute: ClaudeSharedLoginRoute? = nil, allowInteraction: Bool = true,
        fallbacks: ClaudeSharedLoginRoute.CredentialFallbacks? = nil
    ) throws -> SharedClaudeLogin {
        let files = LocalTextFileAccessor()
        let route =
            try explicitRoute
            ?? ClaudeSharedLoginRoute.resolve(
                homeDirectory: homeDirectory, files: files, environment: environment)
        let service = route.service(environment: environment)
        let file = homeDirectory.appendingPathComponent(".claude/.credentials.json")
        let reading = try route.readCredential(
            keychain: keychain, files: files, filePath: file.path, environment: environment,
            allowInteraction: allowInteraction, requireCompleteOAuth: explicitRoute != nil,
            fallbacks: fallbacks ?? (explicitRoute == nil ? .legacyKeychainAndFile : .disabled)
        )
        let selected = reading.login
        let source = selected?.source ?? .keychainCurrentUser(service: service)
        let rawCredential = selected?.text ?? reading.currentUserText
        let storedOAuth: String?
        if let rawCredential, ProviderParse.jsonObjectWithHexFallback(rawCredential)?["claudeAiOauth"] is [String: Any]
        {
            storedOAuth = try ClaudeAccountLoginCredentials.loginOnly(rawCredential)
        } else {
            storedOAuth = nil
        }
        let stateURL = route.stateURL(homeDirectory: homeDirectory).resolvingSymlinksInPath()
        let account = try claudeOAuthAccount(at: stateURL)
        let login = try selected.map { try ClaudeAccountLoginCredentials.loginOnly($0.text) }
        let identityKey = login.flatMap {
            identity(of: .init(credential: $0, claudeOAuthAccount: account), family: "claude")?.identityKey
        }
        return .init(
            source: source, stateURL: stateURL, stateFileExisted: files.exists(stateURL.path),
            rawCredential: rawCredential, storedOAuth: storedOAuth, allowInteraction: allowInteraction,
            state: .init(
                credentials: [login], accounts: [account], identities: [identityKey],
                sourceID: "\(source.label):\(service)")
        )
    }

    /// 상태 파일을 먼저 갱신하고, CLI가 로그인 세대를 유지한 경우에만 해당 출처의 OAuth를 교체.
    func applySharedClaudeLogin(
        _ entry: AccountCredentialVault.Entry, expecting expected: AccountSwitchJournal.SharedState?,
        allowInteraction: Bool, route: ClaudeSharedLoginRoute? = nil
    ) throws {
        let before = try sharedClaudeLogin(route: route, allowInteraction: allowInteraction)
        guard expected == nil || expected == before.state else { throw ClaudeAuthError.credentialsChanged }
        guard let targetAccount = entry.claudeOAuthAccount,
            let identityKey = identity(of: entry, family: "claude")?.identityKey
        else { throw Error.incompleteClaudeAuthentication }
        let targetLogin = try ClaudeAccountLoginCredentials.loginOnly(entry.credential)
        let account = try JSONSerialization.jsonObject(with: Data(targetAccount.utf8))
        let canonicalAccount = String(
            decoding: try JSONSerialization.data(withJSONObject: account, options: [.sortedKeys]), as: UTF8.self)
        if before.state.credentials == [targetLogin], before.state.accounts == [canonicalAccount] { return }

        do {
            if before.state.accounts != [canonicalAccount] {
                try mergeClaudeOAuthAccount(canonicalAccount, at: before.stateURL)
            }
            let current = try sharedClaudeLogin(route: route, allowInteraction: allowInteraction)
            guard current.state.sourceID == before.state.sourceID,
                current.state.accounts == [canonicalAccount], current.storedOAuth == before.storedOAuth
            else { throw ClaudeAuthError.credentialsChanged }
            if current.state.credentials != [targetLogin] {
                try writeClaudeLogin(targetLogin, expecting: current, route: route)
            }
            let applied = try sharedClaudeLogin(route: route, allowInteraction: allowInteraction)
            guard applied.state.sourceID == before.state.sourceID,
                applied.state.accounts == [canonicalAccount], applied.state.credentials == [targetLogin],
                applied.state.identities == [identityKey]
            else { throw ClaudeAuthError.credentialsChanged }
        } catch {
            do {
                try restoreSharedClaudeLogin(
                    before, replacing: targetLogin, account: canonicalAccount, route: route)
            } catch {
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: "claude", localContext: "restore shared login")
            }
            throw error
        }
    }

    func rollbackSharedClaudeLogin(
        to before: SharedClaudeLogin, replacing applied: AccountSwitchJournal.SharedState
    ) throws {
        guard let credential = applied.credentials[0], let account = applied.accounts[0] else {
            throw ClaudeAuthError.credentialsChanged
        }
        try restoreSharedClaudeLogin(before, replacing: credential, account: account, route: nil)
        let restored = try sharedClaudeLogin(allowInteraction: before.allowInteraction)
        guard restored.state == before.state, restored.storedOAuth == before.storedOAuth else {
            throw ClaudeAuthError.credentialsChanged
        }
    }

    private func restoreSharedClaudeLogin(
        _ before: SharedClaudeLogin, replacing target: String, account: String, route: ClaudeSharedLoginRoute?
    ) throws {
        let current = try sharedClaudeLogin(route: route, allowInteraction: before.allowInteraction)
        // CLI가 변경한 출처·계정·세대에는 이전 인증이나 계정 정보를 되쓰지 않음.
        guard current.state.sourceID == before.state.sourceID, current.state.accounts == [account] else { return }
        if current.storedOAuth != before.storedOAuth {
            guard current.storedOAuth == target else { return }
            try writeClaudeLogin(before.storedOAuth, expecting: current, route: route)
        }
        guard before.state.accounts != [account] else { return }
        let restored = try sharedClaudeLogin(route: route, allowInteraction: before.allowInteraction)
        guard restored.state.sourceID == before.state.sourceID, restored.storedOAuth == before.storedOAuth,
            restored.state.accounts == [account]
        else { return }
        try mergeClaudeOAuthAccount(
            before.state.accounts[0], at: before.stateURL, removeCreatedState: !before.stateFileExisted)
    }

    private func writeClaudeLogin(
        _ credential: String?, expecting expected: SharedClaudeLogin, route: ClaudeSharedLoginRoute?
    ) throws {
        let destination = try sharedClaudeLogin(route: route, allowInteraction: expected.allowInteraction)
        guard destination.state == expected.state, destination.stateURL == expected.stateURL,
            destination.storedOAuth == expected.storedOAuth
        else { throw ClaudeAuthError.credentialsChanged }
        let merged = try ClaudeAccountLoginCredentials.replacingLogin(in: destination.rawCredential, with: credential)
        switch destination.source {
        case .file:
            try writePrivateFile(
                merged, to: homeDirectory.appendingPathComponent(".claude/.credentials.json").resolvingSymlinksInPath())
        case .keychainCurrentUser(let service):
            try keychain.writeCLISharedPassword(service: service, value: merged, forCurrentUser: true)
        case .keychainLegacy(let service):
            try keychain.writeCLISharedPassword(service: service, value: merged, forCurrentUser: false)
        default: throw ClaudeAuthError.credentialsChanged
        }
    }

    /// 프로필 API로 현재 토큰의 소유자를 확인한 복구에서 계정 정보만 교체.
    func repairSharedClaudeAccountMetadata(
        _ account: String, identity: String, expecting expected: AccountSwitchJournal.SharedState
    ) throws -> AccountSwitchJournal.SharedState {
        let current = try sharedClaudeLogin()
        guard current.state == expected else { throw ClaudeAuthError.credentialsChanged }
        if current.state.accounts != [account] {
            guard let staged = expected.accounts[0] else { throw ClaudeAuthError.credentialsChanged }
            try mergeClaudeOAuthAccount(account, at: current.stateURL, expecting: staged)
        }
        let repaired = try sharedClaudeLogin().state
        guard repaired.sourceID == expected.sourceID, repaired.credentials == expected.credentials,
            repaired.accounts == [account], repaired.identities == [identity]
        else { throw ClaudeAuthError.credentialsChanged }
        return repaired
    }
}
