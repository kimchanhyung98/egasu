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
        let rawCredential: String?
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
        let selected = try route.readCredential(
            keychain: keychain, files: files, filePath: file.path, environment: environment,
            allowInteraction: allowInteraction, requireCompleteOAuth: explicitRoute != nil,
            fallbacks: fallbacks ?? (explicitRoute == nil ? .legacyKeychainAndFile : .disabled)
        )
        let source = selected?.source ?? .keychainCurrentUser(service: service)
        let stateURL = route.stateURL(homeDirectory: homeDirectory).resolvingSymlinksInPath()
        let account = try claudeOAuthAccount(at: stateURL)
        let login = try selected.map { try ClaudeAccountLoginCredentials.loginOnly($0.text) }
        let identityKey = login.flatMap {
            identity(of: .init(credential: $0, claudeOAuthAccount: account), family: "claude")?.identityKey
        }
        return .init(
            source: source, stateURL: stateURL, rawCredential: selected?.text, allowInteraction: allowInteraction,
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

        let stateFileExisted = LocalTextFileAccessor().exists(before.stateURL.path)
        do {
            if before.state.accounts != [canonicalAccount] {
                try mergeClaudeOAuthAccount(canonicalAccount, at: before.stateURL)
            }
            let current = try sharedClaudeLogin(route: route, allowInteraction: allowInteraction)
            guard current.state.sourceID == before.state.sourceID,
                current.state.accounts == [canonicalAccount], current.state.credentials == before.state.credentials
            else { throw ClaudeAuthError.credentialsChanged }
            if current.state.credentials != [targetLogin] {
                try writeClaudeLogin(targetLogin, to: current)
            }
            let applied = try sharedClaudeLogin(route: route, allowInteraction: allowInteraction)
            guard applied.state.sourceID == before.state.sourceID,
                applied.state.accounts == [canonicalAccount], applied.state.credentials == [targetLogin],
                applied.state.identities == [identityKey]
            else { throw ClaudeAuthError.credentialsChanged }
        } catch {
            do {
                try restoreSharedClaudeLogin(
                    before, replacing: targetLogin, account: canonicalAccount, createdState: !stateFileExisted,
                    route: route)
            } catch {
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: "claude", localContext: "restore shared login")
            }
            throw error
        }
    }

    private func restoreSharedClaudeLogin(
        _ before: SharedClaudeLogin, replacing target: String, account: String, createdState: Bool,
        route: ClaudeSharedLoginRoute?
    ) throws {
        let current = try sharedClaudeLogin(route: route, allowInteraction: before.allowInteraction)
        // CLI가 변경한 출처·계정·세대에는 이전 인증이나 계정 정보를 되쓰지 않음.
        guard current.state.sourceID == before.state.sourceID, current.state.accounts == [account] else { return }
        if current.state.credentials != before.state.credentials {
            guard current.state.credentials == [target] else { return }
            try writeClaudeLogin(before.state.credentials[0], to: current)
        }
        guard before.state.accounts != [account] else { return }
        let restored = try sharedClaudeLogin(route: route, allowInteraction: before.allowInteraction)
        guard restored.state.sourceID == before.state.sourceID, restored.state.credentials == before.state.credentials,
            restored.state.accounts == [account]
        else { return }
        try mergeClaudeOAuthAccount(before.state.accounts[0], at: before.stateURL, removeCreatedState: createdState)
    }

    private func writeClaudeLogin(_ credential: String?, to destination: SharedClaudeLogin) throws {
        let existing: String?
        if let raw = destination.rawCredential {
            existing = raw
        } else if case .keychainCurrentUser(let service) = destination.source {
            // 로그아웃된 Keychain에도 MCP 등이 있을 수 있음.
            existing = try keychain.readGenericPasswordForCurrentUser(
                service: service, allowInteraction: destination.allowInteraction)
            if let existing, ClaudeAuthStore.parseCredentials(existing)?.claudeAiOauth?.accessToken?.nilIfEmpty != nil {
                throw ClaudeAuthError.credentialsChanged
            }
        } else {
            throw ClaudeAuthError.credentialsChanged
        }
        let merged = try ClaudeAccountLoginCredentials.replacingLogin(in: existing, with: credential)
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
}
