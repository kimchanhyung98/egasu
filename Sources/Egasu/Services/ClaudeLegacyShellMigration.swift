import Foundation

enum ClaudeShellLoginMigrationError: String, Error, UserPresentableError {
    case conflict, incompleteOAuth, sourceIdentity, defaultIdentity, missingAccount, missingOrganization, verification
    case pendingSwitch, busy, shellEnvironmentUnavailable, shellEnvironmentChanged, configDirectoryOverride,
        concurrentProfileEdit

    var presentationMessage: LocalizedMessage {
        switch self {
        case .conflict:
            .init(
                "The old shell and default Claude CLI use different accounts. Sign in to the same account in both, then restart egasu."
            )
        case .incompleteOAuth, .sourceIdentity, .defaultIdentity, .missingAccount, .missingOrganization, .verification:
            .init(
                "Claude sign-in is incomplete. Finish signing in to Claude, then restart egasu to finish migrating the old shell setup."
            )
        case .pendingSwitch:
            .init("Finish the pending Claude account switch in Accounts, then restart egasu.")
        case .concurrentProfileEdit:
            .init(
                "Your shell settings changed during migration. Check your changes and any .egasu-recovery file next to your shell settings, then restart egasu."
            )
        case .configDirectoryOverride:
            .init(
                "Your shell sets CLAUDE_CONFIG_DIR outside the old Claude function. Check which login you want to use before removing the function."
            )
        case .shellEnvironmentChanged:
            .init(
                "Claude login settings differ between egasu and your current login shell. Check your shell settings, then restart egasu."
            )
        case .shellEnvironmentUnavailable:
            .init(
                "egasu could not read your login shell environment. Check that your login shell starts, then restart egasu."
            )
        case .busy:
            .init("Another egasu process is updating the shared Claude login. Wait for it to finish, then try again.")
        }
    }
}

/// 기본 CLI 로그인 검증 뒤에만 설치기가 작성한 셸 블록 제거. 부분 완료는 다음 실행에서 이어서 처리.
enum ClaudeLegacyShellMigration {
    static let completedKey = "egasu.claudeShellMigration.v1"

    /// 개발·운영 앱의 로그인 전환과 셸 이전을 같은 파일 잠금으로 직렬화.
    static func acquireSharedLoginLock(home: URL) throws -> SingleInstanceLock.Token {
        let lockURL = home.appendingPathComponent("Library/Application Support/OpenUsage/claude-shell-migration.lock")
        switch SingleInstanceLock.acquire(at: lockURL) {
        case .alreadyRunning: throw ClaudeShellLoginMigrationError.busy
        case .failed: throw CocoaError(.fileWriteUnknown)
        case .acquired(let token): return token
        }
    }

    static func message(for error: Error) -> LocalizedMessage {
        if case KeychainError.readFailed = error {
            return .init("Unlock your Keychain and restart egasu. Allow access to the Claude login if macOS asks.")
        }
        return (error as? UserPresentableError)?.presentationMessage
            ?? .init("Check access to your shell settings and Claude login files, then restart egasu.")
    }

    @MainActor
    static func runIfNeeded(
        defaults: UserDefaults = .standard, switcher: AccountCredentialSwitcher = .init()
    ) async throws {
        guard !defaults.bool(forKey: completedKey) else { return }
        let home = switcher.homeDirectory
        guard !(try ClaudeLegacyShellProfile.find(in: home)).isEmpty else {
            defaults.set(true, forKey: completedKey)
            return
        }
        if let reader = switcher.environment as? ProcessEnvironmentReader {
            guard await loadOffMainActor({ reader.shellEnvironment.ensureCaptured() }) else {
                throw ClaudeShellLoginMigrationError.shellEnvironmentUnavailable
            }
            // 이전은 새 터미널의 설정과 이번 앱이 실제로 쓸 Keychain·프로필 서버 설정이 일치할 때만 진행.
            let scopeKeys = [
                "CLAUDE_CONFIG_DIR", "USER_TYPE", "USE_LOCAL_OAUTH", "USE_STAGING_OAUTH",
                "CLAUDE_LOCAL_OAUTH_API_BASE", "CLAUDE_CODE_CUSTOM_OAUTH_URL"
            ]
            guard scopeKeys.allSatisfy({ reader.value(for: $0) == reader.shellEnvironment.value(for: $0) }) else {
                throw ClaudeShellLoginMigrationError.shellEnvironmentChanged
            }
        }
        let token = try acquireSharedLoginLock(home: home)
        defer { withExtendedLifetime(token) {} }
        let profiles = try ClaudeLegacyShellProfile.find(in: home)
        if let profile = profiles.first {
            try checkPendingSwitch(defaults: defaults, switcher: switcher)
            guard switcher.environment.value(for: "CLAUDE_CONFIG_DIR")?.nilIfEmpty == nil,
                !profiles.contains(where: \.hasConfigDirectorySetting)
            else { throw ClaudeShellLoginMigrationError.configDirectoryOverride }
            let route = ClaudeSharedLoginRoute.legacy(configDir: profile.configDirectory)
            let source = try switcher.sharedClaudeLogin(route: route, allowInteraction: true).state
            let expectedLogin = try await switcher.preparePlainClaudeLogin(from: source, route: route)
            for profile in profiles {
                try checkPendingSwitch(defaults: defaults, switcher: switcher)
                guard try switcher.sharedClaudeLogin(route: route, allowInteraction: true).state == source
                else { throw ClaudeAuthError.credentialsChanged }
                try switcher.verifyPlainClaudeLogin(from: source, expecting: expectedLogin)
                try profile.remove()
            }
            AppLog.info(.config, "migrated legacy Claude shell setup")
        }
        defaults.set(true, forKey: completedKey)
    }

    private static func checkPendingSwitch(defaults: UserDefaults, switcher: AccountCredentialSwitcher) throws {
        try checkPendingSharedLoginChanges(
            home: switcher.homeDirectory, defaults: defaults, ownJournal: switcher.switchJournal)
    }

    static func checkPendingSharedLoginChanges(
        home: URL, defaults: UserDefaults = .standard, ownJournal: AccountSwitchJournal? = nil,
        checkingPeersOnly: Bool = false
    ) throws {
        if !checkingPeersOnly {
            guard try ownJournal?.load() == nil else { throw ClaudeShellLoginMigrationError.pendingSwitch }
            try checkIdentityReplacement(
                defaults.object(forKey: AccountProfilesStore.identityReplacementKey),
                profiles: defaults.data(forKey: AccountProfilesStore.storageKey))
        }
        // 공유 인증의 위치나 세대가 바뀌면 다른 번들의 복구 기록도 무효화됨.
        let support = home.appendingPathComponent("Library/Application Support")
        let production = StorageNamespace.productionBundleIdentifier
        let ownIdentifier = AppBundleLocator.current.bundleIdentifier
        let identifiers = Set([production, production + ".dev", ownIdentifier])
        for identifier in identifiers.sorted() {
            let directory = StorageNamespace(bundleIdentifier: identifier).name
            let journal = support.appendingPathComponent(directory + "/AccountSignIn/claude-switch.json")
            if journal.path != ownJournal?.path, try AccountSwitchJournal(path: journal.path).load() != nil {
                throw ClaudeShellLoginMigrationError.pendingSwitch
            }
            if defaults === UserDefaults.standard, !checkingPeersOnly || identifier != ownIdentifier,
                let domain = defaults.persistentDomain(forName: identifier)
            {
                try checkIdentityReplacement(
                    domain[AccountProfilesStore.identityReplacementKey],
                    profiles: domain[AccountProfilesStore.storageKey] as? Data)
            }
        }
    }

    private static func checkIdentityReplacement(_ value: Any?, profiles: @autoclosure () -> Data?) throws {
        guard let value else { return }
        guard let data = value as? Data else { throw AccountIdentityReplacementError.invalidTransaction }
        let transaction = try JSONDecoder().decode(AccountIdentityReplacement.self, from: data)
        // 비활성 계정의 재로그인은 egasu 보관함만 변경하므로 CLI 인증 위치 이전과 독립.
        guard transaction.replacesSharedAuthentication else { return }
        if transaction.claudeGeneration == nil, let data = profiles() {
            let registry = try JSONDecoder().decode(AccountProfilesStore.Blob.self, from: data)
            if registry.profiles.first(where: { $0.id == transaction.profileID })?.family == "codex" { return }
        }
        throw ClaudeShellLoginMigrationError.pendingSwitch
    }
}

extension AccountCredentialSwitcher {
    /// 다른 기본 계정은 보존. 같은 계정의 OAuth가 둘이면 더 늦은 만료 시각을 우선.
    @MainActor
    fileprivate func preparePlainClaudeLogin(
        from source: AccountSwitchJournal.SharedState, route: ClaudeSharedLoginRoute
    ) async throws -> String? {
        // macOS CLI의 기본 Keychain에 복사. 파일에 남은 토큰만으로 이전 완료를 판정하지 않음.
        let destination = try sharedClaudeLogin(
            route: .plain, allowInteraction: true,
            fallbacks: source.credentials[0] == nil ? .legacyKeychainAndFile : .disabled
        ).state
        guard let login = source.credentials[0] else {
            try verifyLoggedOut(destination)
            return nil
        }
        guard let account = source.accounts[0], let identity = source.identities[0] else {
            throw ClaudeShellLoginMigrationError.sourceIdentity
        }
        if let existing = destination.accounts[0] {
            guard
                let existingID = self.identity(
                    of: .init(credential: login, claudeOAuthAccount: existing), family: "claude")
            else {
                throw ClaudeShellLoginMigrationError.defaultIdentity
            }
            guard existingID.identityKey == identity else { throw ClaudeShellLoginMigrationError.conflict }
        }
        if let existing = destination.credentials[0] {
            // 같은 OAuth만 있는 중간 상태에서는 계정 정보만 복구 가능.
            if destination.accounts[0] == nil {
                guard existing == login else { throw ClaudeShellLoginMigrationError.missingAccount }
            } else if existing == login {
                return login
            } else {
                guard identity.contains("|") else { throw ClaudeShellLoginMigrationError.missingOrganization }
                for candidate in [existing, login] {
                    guard let token = ClaudeAuthStore.parseCredentials(candidate)?.claudeAiOauth?.accessToken else {
                        throw ClaudeShellLoginMigrationError.incompleteOAuth
                    }
                    let profile = try await claudeProfile(for: token, timeout: 2)
                    guard try profile.accountIdentityKey() == identity else {
                        throw ClaudeShellLoginMigrationError.conflict
                    }
                }
                guard try sharedClaudeLogin(route: route, allowInteraction: true).state == source else {
                    throw ClaudeAuthError.credentialsChanged
                }
                let sourceExpiry = ClaudeAuthStore.parseCredentials(login)?.claudeAiOauth?.expiresAt
                let existingExpiry = ClaudeAuthStore.parseCredentials(existing)?.claudeAiOauth?.expiresAt
                if destination.identities[0] == identity, let sourceExpiry, let existingExpiry,
                    existingExpiry >= sourceExpiry
                {
                    return existing
                }
            }
        }
        if destination.credentials[0] == nil {
            // 이전 앱이 남긴 파일 사본과 달리 기본 Keychain의 계정 미지정 항목은 별도 로그인일 수 있음.
            let fallback = try sharedClaudeLogin(route: .plain, allowInteraction: true, fallbacks: .legacyKeychain)
                .state
            if let existing = fallback.credentials[0], existing != login {
                throw ClaudeShellLoginMigrationError.defaultIdentity
            }
        }
        try applySharedClaudeLogin(
            .init(credential: login, claudeOAuthAccount: destination.accounts[0] ?? account), expecting: destination,
            allowInteraction: true, route: .plain)
        return login
    }

    fileprivate func verifyPlainClaudeLogin(from source: AccountSwitchJournal.SharedState, expecting login: String?)
        throws
    {
        let destination = try sharedClaudeLogin(
            route: .plain, allowInteraction: true,
            fallbacks: source.credentials[0] == nil ? .legacyKeychainAndFile : .disabled
        ).state
        if source.credentials[0] == nil {
            try verifyLoggedOut(destination)
        } else {
            guard let identity = source.identities[0], destination.identities[0] == identity,
                destination.credentials == [login]
            else { throw ClaudeShellLoginMigrationError.verification }
        }
    }

    private func verifyLoggedOut(_ destination: AccountSwitchJournal.SharedState) throws {
        // 양쪽에 OAuth가 없으면 상태 파일에 남은 계정 정보만으로 로그인을 복원하지 않음.
        guard destination.credentials[0] == nil else { throw ClaudeShellLoginMigrationError.conflict }
    }
}
