import Foundation

/// 기존 로그인의 계정을 확인한 뒤 인증 사본을 저장하고 프로필 등록.
@MainActor
struct AccountCredentialImporter {
    struct ImportedCredential: Sendable {
        var entry: AccountCredentialVault.Entry
        var identityKey: String
        var label: String?
    }

    enum ImportError: LocalizedError, Equatable {
        case noSignIn(family: String)
        case identityUnreadable(family: String)
        case verificationFailed(family: String)

        var errorDescription: String? {
            switch self {
            case .noSignIn(let family):
                "No \(family) sign-in was found to import."
            case .identityUnreadable(let family):
                "The current \(family) sign-in doesn't name its account, so it can't be imported."
            case .verificationFailed(let family):
                "The imported \(family) sign-in could not be verified, so nothing was registered."
            }
        }
    }

    let switcher: AccountCredentialSwitcher
    let keychain: KeychainAccessing
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let workspace: AccountSignInWorkspace

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
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.workspace = workspace
        self.switcher = AccountCredentialSwitcher(
            keychain: keychain,
            fileManager: fileManager,
            environment: environment,
            homeDirectory: homeDirectory,
            workspace: workspace,
            httpClient: httpClient
        )
    }

    // MARK: - Reading

    /// 공유 홈, 구형 Codex 홈, Keychain 순서로 계정을 식별할 수 있는 첫 로그인 반환.
    func readDefaultCredential(family: String) throws -> ImportedCredential? {
        var foundCredential = false
        func identified(_ entry: AccountCredentialVault.Entry?) -> ImportedCredential? {
            guard let entry else { return nil }
            foundCredential = true
            guard let (identityKey, label) = switcher.identity(of: entry, family: family) else { return nil }
            return ImportedCredential(entry: entry, identityKey: identityKey, label: label)
        }

        if let shared = identified(try switcher.readSharedAuthentication(family: family)) { return shared }
        if family == "codex" {
            let legacyHome = homeDirectory.appendingPathComponent(".config/codex").path
            if let legacy = identified(try switcher.readAuthentication(family: family, home: legacyHome)) {
                return legacy
            }
            // 파일에서 계정을 확인하지 못한 경우에만 Keychain 접근. 조회 실패는 호출자에게 전달.
            if let value = try keychain.readGenericPassword(service: CodexAuthStore.keychainService),
                CodexAuthStore.parseAuth(value)?.tokens?.accessToken?.nilIfEmpty != nil,
                let stored = identified(.init(credential: value, claudeOAuthAccount: nil))
            {
                return stored
            }
        }
        if foundCredential { throw ImportError.identityUnreadable(family: family) }
        return nil
    }

    /// profile의 Sign-In Workspace에서 완료된 공식 로그인 — 사용 가능한 credential 없으면 `nil`.
    func readWorkspaceCredential(family: String, profileID: String, attemptID: String? = nil) throws -> ImportedCredential? {
        let home = try workspace.directory(family: family, profileID: profileID, attemptID: attemptID).path
        try workspace.assertNoSymlinkComponents(family: family, profileID: profileID, attemptID: attemptID)
        if family == "codex" {
            let authURL = URL(fileURLWithPath: home).appendingPathComponent("auth.json")
            do {
                let attributes = try fileManager.attributesOfItem(atPath: authURL.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular else {
                    throw ImportError.verificationFailed(family: family)
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                return nil
            }
        }
        guard let entry = try switcher.readAuthentication(family: family, home: home) else {
            return nil
        }
        guard let (identityKey, label) = switcher.identity(of: entry, family: family) else {
            throw ImportError.identityUnreadable(family: family)
        }
        return ImportedCredential(entry: entry, identityKey: identityKey, label: label)
    }

    // MARK: - Registration

    /// 작업 공간과 Keychain에 저장한 인증을 다시 확인한 뒤 계정 등록. 실패 시 임시 인증 정리.
    @discardableResult
    func register(
        _ credential: ImportedCredential,
        family: String,
        label: String,
        id: String? = nil,
        into store: AccountProfilesStore
    ) throws -> AccountProfile {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        // 새 작업 공간은 등록 계정의 회전 대상과 분리. 기존 ID의 인증에는 접근하지 않음.
        if let id {
            guard !store.profiles.contains(where: { $0.id == id }) else {
                throw AccountProfileError.profileNotFound(id)
            }
        } else if family == "claude" {
            try AccountCredentialMutationLock.requireIdleClaudeRotation()
        }
        let staged = AccountProfile(
            id: id ?? UUID().uuidString,
            family: family,
            label: label,
            identityKey: credential.identityKey,
            createdAt: Date()
        )
        do {
            try switcher.writeWorkspaceAuthentication(credential.entry, for: staged)
            try switcher.saveSnapshot(credential.entry, for: staged)
            guard let reloaded = try switcher.loadSnapshot(for: staged),
                  switcher.identity(of: reloaded, family: family)?.identityKey == credential.identityKey else {
                throw ImportError.verificationFailed(family: family)
            }
            return try store.add(
                family: family,
                label: uniqueLabel(label, family: family, store: store),
                identityKey: credential.identityKey,
                id: staged.id
            )
        } catch {
            // 한 저장소의 복구가 실패해도 남은 인증 사본 정리 계속.
            cleanup(family: family, context: "remove staged snapshot") {
                try AccountCredentialVault(keychain: keychain).delete(profile: staged)
            }
            cleanup(family: family, context: "remove staged credential") {
                try switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: staged.id)
            }
            cleanup(family: family, context: "remove staged workspace") {
                try workspace.remove(family: family, profileID: staged.id)
            }
            throw error
        }
    }

    /// 최초 실패를 호출자에게 돌려주고, 복구 중의 추가 실패는 별도로 기록.
    func cleanup(family: String, context: String, perform: () throws -> Void) {
        do {
            try perform()
        } catch {
            AppDiagnostics.failure(.accountRollback, error: error, providerID: family, localContext: context)
        }
    }

    /// profile sign-in workspace에 staged된 전부 삭제 — provider-scoped 로그인 credential 먼저, 다음 workspace 디렉터리 (삭제 순서 계약).
    /// Shared Runtime Home·legacy 디렉터리는 범위 밖.
    nonisolated func removeSignInWorkspace(family: String, profileID: String) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        if family == "claude" { try AccountCredentialMutationLock.requireIdleClaudeRotation() }
        try removeSignInWorkspaceContents(family: family, profileID: profileID)
    }

    /// 등록된 계정의 갱신과 무관한 임시 로그인만 정리.
    func discardUnregisteredSignInWorkspace(family: String, profileID: String, in store: AccountProfilesStore) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        guard !store.profiles.contains(where: { $0.id == profileID }) else { return }
        try removeSignInWorkspaceContents(family: family, profileID: profileID)
    }

    private nonisolated func removeSignInWorkspaceContents(family: String, profileID: String) throws {
        try switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: profileID)
        try workspace.remove(family: family, profileID: profileID)
    }

    nonisolated func codexWorkspaceAuthPath(profileID: String) throws -> String {
        try workspace.assertNoSymlinkComponents(family: "codex", profileID: profileID)
        return try workspace.directory(family: "codex", profileID: profileID).appendingPathComponent("auth.json").path
    }

    /// 현재 시도만 제거. 같은 프로필의 다른 로그인 시도와 이전 인증 파일은 보존.
    nonisolated func restoreCodexWorkspace(
        profileID: String, attemptID: String, previousAuthentication: String?
    ) throws {
        let path = try codexWorkspaceAuthPath(profileID: profileID)
        let files = LocalTextFileAccessor()
        if let previousAuthentication {
            try files.writeText(path, previousAuthentication)
        } else {
            try files.remove(path)
        }
        try workspace.remove(family: "codex", profileID: profileID, attemptID: attemptID)
    }

    /// managed 계정 제거 — switchable snapshot을 잃은 등록 profile 잔존 금지.
    /// workspace 먼저 삭제, 실패 시 snapshot·registry 유지 — registry preflight는 모든 삭제 전 실행.
    func removeAccount(_ profile: AccountProfile, from store: AccountProfilesStore) throws {
        if profile.family == "claude" {
            _ = try AccountSelectionSwitcher(switcher: switcher).recoverInterruptedSwitch(in: store)
        }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        if profile.family == "claude" { try AccountCredentialMutationLock.requireIdleClaudeRotation() }
        try store.validateArchive(profileID: profile.id)
        do {
            try removeSignInWorkspace(family: profile.family, profileID: profile.id)
        } catch {
            throw RemovalError.workspace
        }
        do {
            try AccountCredentialVault(keychain: keychain).delete(profile: profile)
        } catch {
            throw RemovalError.snapshot
        }
        try store.archive(profileID: profile.id)
    }

    enum RemovalError: LocalizedError {
        case workspace
        case snapshot

        var errorDescription: String? {
            switch self {
            case .workspace:
                "egasu couldn't delete this account's sign-in workspace. The account and its saved authentication were not removed — try again."
            case .snapshot:
                "egasu couldn't delete the saved Keychain authentication. The account remains registered and ready, so you can try removing it again."
            }
        }
    }

    enum ExternalReauthenticationResult: Equatable, Sendable {
        case unchanged
        case noUsableAuthentication
        case updated(profileID: String)
    }

    private struct ExternalClaudeObservation: Sendable {
        var previousSnapshot: AccountCredentialVault.Entry?
        var sharedState: AccountSwitchJournal.SharedState
        var snapshot: AccountCredentialVault.Entry
        var identityKey: String
        var profile: AccountProfile
    }

    /// 외부 로그인 관찰은 메인 액터 밖에서 수행. 저장 스냅샷의 Keychain 승인 요청은 수동 갱신에서만 허용.
    /// 승인과 저장소 쓰기는 백그라운드에서 수행하고 선택 저장 전 계정 목록과 인증 세대를 재확인.
    func reconcileSelectedClaudeSharedAuthenticationAfterStartup(
        in store: AccountProfilesStore
    ) async throws -> ExternalReauthenticationResult {
        let allowInteraction = ProviderRefreshContext.isManual
        if try await AccountSelectionSwitcher(switcher: switcher).recoverInterruptedSwitchAfterStartup(
            in: store, allowInteraction: allowInteraction), let profileID = store.preferredProfileID(family: "claude")
        {
            return .updated(profileID: profileID)
        }
        if let transaction = try store.pendingIdentityReplacement() {
            if let profile = store.profile(id: transaction.profileID) {
                guard
                    try await recoverStartupIdentityReplacement(
                        transaction, for: profile, in: store, allowInteraction: allowInteraction
                    )
                else { return .unchanged }
            } else {
                try store.cancelIdentityReplacement(transaction)
            }
        }
        guard let profile = store.preferredProfile(family: "claude") else { return .unchanged }
        let authenticationRevision = store.authenticationRevision
        let profiles = store.profiles(family: "claude")
        let familyRevision = AccountCredentialMutationLock.revision(for: "claude")
        func registryMatches() -> Bool {
            !store.hasUnreadableRegistry && store.authenticationRevision == authenticationRevision
                && store.preferredProfileID(family: "claude") == profile.id
                && store.profiles(family: "claude") == profiles
        }
        let observation = try await Task.detached(priority: .utility) {
            try await observeExternalClaudeAuthentication(
                for: profile, profiles: profiles, allowInteraction: allowInteraction)
        }.value
        guard let observation else { return .noUsableAuthentication }
        guard !Task.isCancelled, registryMatches(),
            try store.pendingIdentityReplacement() == nil, try switcher.switchJournal.load() == nil
        else { return .unchanged }
        guard AccountCredentialMutationLock.revision(for: "claude") == familyRevision else {
            throw ClaudeAuthError.credentialsChanged
        }
        let target = observation.profile
        let replacesCredential =
            observation.previousSnapshot != observation.snapshot || target.identityKey != observation.identityKey
        if !replacesCredential, target.id == profile.id { return .unchanged }

        let loginLock = try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        try AccountCredentialMutationLock.beginClaudeSwitch()
        defer { AccountCredentialMutationLock.endClaudeSwitch() }
        let transaction =
            replacesCredential
            ? try store.beginIdentityReplacement(
                profileID: target.id, with: observation.identityKey, replacesSharedAuthentication: false,
                externalClaudeGeneration: .init(
                    state: observation.sharedState, previous: observation.previousSnapshot,
                    replacement: observation.snapshot)
            ) : nil
        var appliedRevision: UInt64?
        var attemptedSelection = false
        do {
            let applied = try await loadOffMainActor {
                try applyExternalClaudeCredentials(
                    observation, at: familyRevision, replacesCredential: replacesCredential,
                    allowInteraction: allowInteraction)
            }
            appliedRevision = applied.revision
            if let failure = applied.failure { throw failure }
            guard !Task.isCancelled, registryMatches(), try store.pendingIdentityReplacement() == transaction,
                try switcher.switchJournal.load() == nil
            else { throw ClaudeAuthError.credentialsChanged }
            guard
                try AccountCredentialMutationLock.withUnchangedRevision(
                    applied.revision, family: "claude",
                    {
                        appliedRevision = AccountCredentialMutationLock.revision(for: "claude")
                        guard try switcher.readClaudeSwitchState(allowInteraction: false) == observation.sharedState
                        else { throw ClaudeAuthError.credentialsChanged }
                        attemptedSelection = true
                        try store.commitPreferredSelection(family: "claude", profileID: target.id)
                        if let transaction { _ = try store.commitIdentityReplacement(transaction) }
                    })
            else { throw ClaudeAuthError.credentialsChanged }
            return .updated(profileID: target.id)
        } catch {
            var restoredSelection = true
            if attemptedSelection, target.id != profile.id, store.preferredProfileID(family: "claude") == target.id {
                do {
                    try store.commitPreferredSelection(family: "claude", profileID: profile.id)
                } catch {
                    restoredSelection = false
                    AppDiagnostics.failure(
                        .accountRollback, error: error, providerID: "claude",
                        localContext: "external reauthentication: restore selection")
                }
            }
            if let transaction, try store.pendingIdentityReplacement() == transaction {
                let restored: Bool
                if let appliedRevision {
                    restored = try await loadOffMainActor {
                        var restored = false
                        _ = try AccountCredentialMutationLock.withUnchangedRevision(appliedRevision, family: "claude") {
                            let current = try switcher.loadSnapshot(for: target, allowInteraction: allowInteraction)
                            guard current == observation.snapshot || current == observation.previousSnapshot else {
                                return
                            }
                            restored = rollbackCredentialTransaction(
                                profile: target, previousSnapshot: observation.previousSnapshot,
                                allowInteraction: allowInteraction, context: "external reauthentication")
                        }
                        return restored
                    }
                } else {
                    restored = true
                }
                if restored, restoredSelection { try store.cancelIdentityReplacement(transaction) }
            }
            throw error
        }
    }

    nonisolated private func observeExternalClaudeAuthentication(
        for selected: AccountProfile, profiles: [AccountProfile], allowInteraction: Bool = false
    ) async throws -> ExternalClaudeObservation? {
        let selectedSnapshot = try switcher.loadSnapshot(for: selected, allowInteraction: allowInteraction)
        guard let verified = try await switcher.readSharedClaudeExternalAuthentication(
            comparedTo: selectedSnapshot, allowInteraction: allowInteraction)
        else { return nil }
        let shared = verified.observed
        let identityKey = verified.identityKey
        let profile =
            selected.identityKey == identityKey
            ? selected
            : profiles.first(where: { $0.identityKey == identityKey }) ?? selected
        let previousSnapshot =
            profile.id == selected.id
            ? selectedSnapshot
            : try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
        let latestSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
        let sharedState = try switcher.readClaudeSwitchState(allowInteraction: allowInteraction)
        guard latestSnapshot == previousSnapshot, sharedState.sourceID == verified.sourceID,
            sharedState.credentials == [shared.credential], sharedState.accounts == [shared.claudeOAuthAccount]
        else {
            AppLog.warn(.auth, "Claude sign-in changed during observation; preserving all authentication")
            throw ClaudeAuthError.credentialsChanged
        }
        return ExternalClaudeObservation(
            previousSnapshot: previousSnapshot, sharedState: sharedState,
            snapshot: verified.snapshot,
            identityKey: identityKey, profile: profile
        )
    }

    nonisolated private func sharedLoginMatches(
        _ entry: AccountCredentialVault.Entry, sourceID: String, allowInteraction: Bool
    ) throws -> Bool {
        let state = try switcher.readClaudeSwitchState(allowInteraction: allowInteraction)
        return state.sourceID == sourceID && state.credentials == [entry.credential]
            && state.accounts == [entry.claudeOAuthAccount]
    }

    /// 공유 로그인과 저장본을 같은 세대에서 확인한 뒤 계정 저장소만 갱신.
    nonisolated private func applyExternalClaudeCredentials(
        _ observation: ExternalClaudeObservation, at revision: UInt64, replacesCredential: Bool, allowInteraction: Bool
    ) throws -> (revision: UInt64, failure: (any Error)?) {
        var appliedRevision = revision
        var failure: (any Error)?
        guard
            try AccountCredentialMutationLock.withUnchangedRevision(
                revision, family: "claude",
                {
                    guard
                        try switcher.loadSnapshot(for: observation.profile, allowInteraction: allowInteraction)
                            == observation.previousSnapshot,
                        try switcher.readClaudeSwitchState(allowInteraction: allowInteraction)
                            == observation.sharedState
                    else { throw ClaudeAuthError.credentialsChanged }
                    if replacesCredential {
                        do {
                            try switcher.saveSnapshot(observation.snapshot, for: observation.profile)
                            try switcher.writeWorkspaceAuthentication(
                                observation.snapshot, for: observation.profile, allowInteraction: allowInteraction)
                            guard
                                try switcher.loadSnapshot(for: observation.profile, allowInteraction: allowInteraction)
                                    == observation.snapshot,
                                try switcher.readClaudeSwitchState(allowInteraction: allowInteraction)
                                    == observation.sharedState
                            else { throw ClaudeAuthError.credentialsChanged }
                        } catch {
                            failure = error
                        }
                    }
                    appliedRevision = AccountCredentialMutationLock.revision(for: "claude")
                })
        else { throw ClaudeAuthError.credentialsChanged }
        return (appliedRevision, failure)
    }

    /// 첫 계정 import — 이미 로그인된 기본 계정을 provider re-login 없이 registry에 등록.
    /// Claude 기본 인증은 프로필 API로 검증한 동일 값만 등록. 기본 로그인 부재 시 `nil`, 공유 인증은 읽기 전용.
    @discardableResult
    func importDefaultAccount(
        family: String,
        label: String = "default",
        into store: AccountProfilesStore
    ) async throws -> AccountProfile? {
        guard store.profiles(family: family).isEmpty else { return nil }
        let verified:
            (credential: ImportedCredential, proof: AccountCredentialSwitcher.VerifiedClaudeExternalAuthentication)?
        if family == "claude" {
            guard !store.hasUnreadableRegistry else { throw AccountProfileError.registryUnreadable }
            let profiles = store.profiles
            let preferred = store.preferredProfileID(family: family)
            let revision = store.authenticationRevision
            let replacement = try store.pendingIdentityReplacement()
            let original = try switcher.readClaudeSwitchState()
            guard let observed = try readDefaultCredential(family: family) else { return nil }
            let observer = switcher
            let entry = try await Task.detached(priority: .utility) {
                try await observer.readSharedClaudeExternalAuthentication(comparedTo: nil, allowInteraction: true)
            }.value
            try Task.checkCancellation()
            guard try store.pendingIdentityReplacement() == replacement else {
                throw AccountIdentityReplacementError.pendingTransaction
            }
            guard !store.hasUnreadableRegistry, store.profiles == profiles,
                store.preferredProfileID(family: family) == preferred,
                store.authenticationRevision == revision
            else {
                throw ImportError.verificationFailed(family: family)
            }
            guard let entry, entry.observed == observed.entry, original.sourceID == entry.sourceID
            else {
                throw ClaudeAuthError.credentialsChanged
            }
            verified = (
                ImportedCredential(entry: entry.snapshot, identityKey: entry.identityKey, label: observed.label), entry
            )
        } else {
            verified = nil
        }
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        if family == "claude" { try AccountCredentialMutationLock.requireIdleClaudeRotation() }
        if let proof = verified?.proof,
            try !sharedLoginMatches(proof.observed, sourceID: proof.sourceID, allowInteraction: true)
        {
            throw ClaudeAuthError.credentialsChanged
        }
        guard let credential = try verified?.credential ?? readDefaultCredential(family: family) else { return nil }
        let profile = try register(credential, family: family, label: label, into: store)
        store.setPreferred(family: family, profileID: profile.id)
        return profile
    }

    /// 충돌 없는 첫 label — 요청 label 그대로, 충돌 시 " 2", " 3", ….
    private func uniqueLabel(_ label: String, family: String, store: AccountProfilesStore) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = AccountProfilesStore.isValidLabel(trimmed) ? trimmed : "Account"
        let taken = Set(store.profiles(family: family).map { $0.label.lowercased() })
        guard taken.contains(base.lowercased()) else { return base }
        var attempt = 2
        while taken.contains("\(base) \(attempt)".lowercased()) {
            attempt += 1
        }
        return "\(base) \(attempt)"
    }
}
