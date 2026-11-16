import Foundation

/// 이미 로그인된 provider 계정을 provider re-login 없이 managed registry로 import — credential read, identity 증명, Keychain·Sign-In Workspace snapshot 후 profile 등록.
/// 취소·실패·identity 부재 read는 아무것도 등록 안 함 — 인증 실패의 조용한 빈 계정화 금지.
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

    private let switcher: AccountCredentialSwitcher
    private let keychain: KeychainAccessing
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

    /// Shared Runtime Home의 현재 sign-in — 없으면 `nil`.
    /// Codex는 legacy `~/.config/codex/auth.json`과 `Codex Auth` Keychain item도 1회성 import 소스로 수용 — identity를 증명하는 첫 소스 채택, 디스크 무변경.
    func readDefaultCredential(family: String) throws -> ImportedCredential? {
        var entries: [AccountCredentialVault.Entry] = []
        if let shared = try switcher.readSharedAuthentication(family: family) {
            entries.append(shared)
        }
        if family == "codex" {
            let legacyHome = homeDirectory.appendingPathComponent(".config/codex").path
            if let legacy = try switcher.readAuthentication(family: family, home: legacyHome) {
                entries.append(legacy)
            }
            if let value = try? keychain.readGenericPassword(service: CodexAuthStore.keychainService),
               CodexAuthStore.parseAuth(value)?.tokens?.accessToken?.nilIfEmpty != nil {
                entries.append(AccountCredentialVault.Entry(credential: value, claudeOAuthAccount: nil))
            }
        }
        guard !entries.isEmpty else { return nil }
        // 소스를 순서대로 평가해 identity를 증명하는 첫 소스 사용 — 계정 특정 못 하는 token 형태 소스가 뒤의 유효 소스를 가리는 것 금지.
        for entry in entries {
            if let (identityKey, label) = switcher.identity(of: entry, family: family) {
                return ImportedCredential(entry: entry, identityKey: identityKey, label: label)
            }
        }
        throw ImportError.identityUnreadable(family: family)
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

    /// 증명된 credential을 snapshot하고 profile 등록 — workspace + Keychain 먼저, 원본 identity 재검증 후에만 registry 등록.
    /// 실패 시 staged 산출물 제거 — 아무것도 등록 안 함.
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
            try? AccountCredentialVault(keychain: keychain).delete(profile: staged)
            try? switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: staged.id)
            try? workspace.remove(family: family, profileID: staged.id)
            throw error
        }
    }

    /// profile sign-in workspace에 staged된 전부 삭제 — provider-scoped 로그인 credential 먼저, 다음 workspace 디렉터리 (삭제 순서 계약).
    /// Shared Runtime Home·legacy 디렉터리는 범위 밖.
    func removeSignInWorkspace(family: String, profileID: String) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        try switcher.removeWorkspaceCredentialArtifacts(family: family, profileID: profileID)
        try workspace.remove(family: family, profileID: profileID)
    }

    /// managed 계정 제거 — switchable snapshot을 잃은 등록 profile 잔존 금지.
    /// workspace 먼저 삭제, 실패 시 snapshot·registry 유지 — registry preflight는 모든 삭제 전 실행.
    func removeAccount(_ profile: AccountProfile, from store: AccountProfilesStore) throws {
        if profile.family == "claude" {
            _ = try AccountSelectionSwitcher(switcher: switcher).recoverInterruptedSwitch(in: store)
        }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
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
        var shared: AccountCredentialVault.Entry
        var snapshot: AccountCredentialVault.Entry
        var identityKey: String
        var profile: AccountProfile
    }

    /// 외부 로그인 관찰은 메인 액터 밖에서 수행. 저장 스냅샷의 Keychain 승인 요청은 수동 갱신에서만 허용.
    /// 적용 직전 공유 인증은 메인 액터에서 동기 재확인 — 검사와 저장 사이 비동기 대기 없음.
    func reconcileSelectedClaudeSharedAuthenticationAfterStartup(
        in store: AccountProfilesStore
    ) async throws -> ExternalReauthenticationResult {
        if try await AccountSelectionSwitcher(switcher: switcher).recoverInterruptedSwitchAfterStartup(in: store),
           let profileID = store.preferredProfileID(family: "claude") {
            return .updated(profileID: profileID)
        }
        let allowInteraction = ProviderRefreshContext.isManual
        if let transaction = try store.pendingIdentityReplacement(),
           let profile = store.profile(id: transaction.profileID) {
            let revision = store.authenticationRevision
            let codexRevision = profile.family == "codex" ? AccountCredentialMutationLock.revision : nil
            let savedSnapshot = try await loadOffMainActor { [switcher] in
                try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
            }
            guard !Task.isCancelled,
                  try store.pendingIdentityReplacement() == transaction,
                  store.profile(id: profile.id) == profile,
                  store.authenticationRevision == revision else { return .unchanged }
            let finishRecovery = {
                _ = try self.finishInterruptedIdentityReplacement(
                    transaction, profile: profile, savedSnapshot: savedSnapshot, in: store
                )
            }
            if let codexRevision {
                guard try AccountCredentialMutationLock.withUnchangedRevision(codexRevision, finishRecovery) else {
                    return .unchanged
                }
            } else {
                try finishRecovery()
            }
        } else {
            _ = try recoverInterruptedIdentityReplacement(in: store)
        }
        guard let profile = store.preferredProfile(family: "claude") else { return .unchanged }
        let authenticationRevision = store.authenticationRevision
        let profiles = store.profiles(family: "claude")
        let observation = try await Task.detached(priority: .utility) {
            try await observeExternalClaudeAuthentication(
                for: profile, profiles: profiles, allowInteraction: allowInteraction)
        }.value
        guard let observation else { return .noUsableAuthentication }
        guard !Task.isCancelled, store.preferredProfileID(family: "claude") == profile.id,
              store.profile(id: profile.id)?.identityKey == profile.identityKey,
              store.authenticationRevision == authenticationRevision,
              store.profiles(family: "claude") == profiles
        else {
            return .unchanged
        }
        guard try switcher.readSharedClaudeAuthenticationForReadiness() == observation.shared else {
            AppLog.warn(.auth, "Claude sign-in changed before applying observation; preserving all authentication")
            throw ClaudeAuthError.credentialsChanged
        }
        return try applyExternalClaudeAuthentication(observation, in: store)
    }

    nonisolated private func observeExternalClaudeAuthentication(
        for selected: AccountProfile, profiles: [AccountProfile], allowInteraction: Bool = false
    ) async throws -> ExternalClaudeObservation? {
        let selectedSnapshot = try switcher.loadSnapshot(for: selected, allowInteraction: allowInteraction)
        guard let verified = try await switcher.readSharedClaudeExternalAuthentication(comparedTo: selectedSnapshot)
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
        guard try switcher.readSharedClaudeAuthenticationForReadiness() == shared else {
            AppLog.warn(.auth, "Claude sign-in changed during observation; preserving all authentication")
            throw ClaudeAuthError.credentialsChanged
        }
        return ExternalClaudeObservation(
            previousSnapshot: previousSnapshot, shared: shared, snapshot: verified.snapshot,
            identityKey: identityKey, profile: profile
        )
    }

    private func applyExternalClaudeAuthentication(
        _ observation: ExternalClaudeObservation,
        in store: AccountProfilesStore
    ) throws -> ExternalReauthenticationResult {
        let profile = observation.profile
        if observation.previousSnapshot == observation.snapshot, profile.identityKey == observation.identityKey {
            guard store.preferredProfileID(family: "claude") != profile.id else { return .unchanged }
            try store.commitPreferredSelection(family: "claude", profileID: profile.id)
            return .updated(profileID: profile.id)
        }
        let transaction = try store.beginIdentityReplacement(
            profileID: profile.id, with: observation.identityKey, replacesSharedAuthentication: false
        )
        do {
            try switcher.saveSnapshot(observation.snapshot, for: profile)
            try switcher.writeWorkspaceAuthentication(observation.snapshot, for: profile)
            try store.commitPreferredSelection(family: "claude", profileID: profile.id)
            _ = try store.commitIdentityReplacement(transaction)
            return .updated(profileID: profile.id)
        } catch {
            let restored = rollbackCredentialTransaction(
                profile: profile, previousSnapshot: observation.previousSnapshot,
                previousShared: nil, restoresSharedAuthentication: false, context: "external reauthentication"
            )
            if restored { try? store.cancelIdentityReplacement(transaction) }
            throw error
        }
    }

    /// 완료된 로그인 작업 공간의 인증으로 해당 계정명의 provider binding 교체.
    /// stable profile id·label·선택 상태 유지. 활성 profile이면 Shared Runtime Home도 같은 트랜잭션에서 갱신.
    @discardableResult
    func completeReSignIn(
        profileID: String,
        in store: AccountProfilesStore,
        isActive: Bool,
        signInAttemptID: String? = nil
    ) throws -> AccountProfile {
        if store.profile(id: profileID)?.family == "claude", try switcher.switchJournal.load() != nil {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        _ = try recoverInterruptedIdentityReplacement(in: store, allowInteraction: true)
        guard let profile = store.profile(id: profileID) else {
            throw AccountProfileError.profileNotFound(profileID)
        }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        guard let credential = try readWorkspaceCredential(
            family: profile.family, profileID: profile.id, attemptID: signInAttemptID
        ) else {
            throw ImportError.noSignIn(family: profile.family)
        }

        let previousSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: true)
        let previousShared = isActive ? try switcher.readSharedAuthentication(family: profile.family) : nil
        let transaction = try store.beginIdentityReplacement(
            profileID: profile.id,
            with: credential.identityKey,
            replacesSharedAuthentication: isActive
        )
        do {
            try switcher.saveSnapshot(credential.entry, for: profile)
            if signInAttemptID != nil {
                try switcher.writeWorkspaceAuthentication(credential.entry, for: profile)
            }
            if isActive {
                try switcher.applySharedAuthentication(credential.entry, family: profile.family)
                guard let applied = try switcher.readSharedAuthentication(family: profile.family),
                      switcher.identity(of: applied, family: profile.family)?.identityKey == credential.identityKey
                else {
                    throw ImportError.verificationFailed(family: profile.family)
                }
            }
            let updated = try store.commitIdentityReplacement(transaction)
            AppLog.info(.auth, "account re-sign-in saved \(profile.family) profile \(profile.id.prefix(8)) identity_changed=\(profile.identityKey != credential.identityKey)")
            return updated
        } catch {
            let restored = rollbackCredentialTransaction(
                profile: profile,
                previousSnapshot: previousSnapshot,
                previousShared: previousShared,
                restoresSharedAuthentication: isActive,
                context: "account re-sign-in"
            )
            if restored {
                try? store.cancelIdentityReplacement(transaction)
            }
            throw error
        }
    }

    /// 중단된 identity 교체 journal을 snapshot 기준으로 완결하거나 쓰기 전 상태로 폐기.
    @discardableResult
    func recoverInterruptedIdentityReplacement(
        in store: AccountProfilesStore, allowInteraction: Bool = false
    ) throws -> Bool {
        guard let transaction = try store.pendingIdentityReplacement() else { return false }
        guard let profile = store.profile(id: transaction.profileID) else {
            try store.cancelIdentityReplacement(transaction)
            return false
        }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        let savedSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
        return try finishInterruptedIdentityReplacement(
            transaction, profile: profile, savedSnapshot: savedSnapshot, in: store
        )
    }

    private func finishInterruptedIdentityReplacement(
        _ transaction: AccountIdentityReplacement, profile: AccountProfile,
        savedSnapshot: AccountCredentialVault.Entry?, in store: AccountProfilesStore
    ) throws -> Bool {
        guard let snapshot = savedSnapshot,
              switcher.identity(of: snapshot, family: profile.family)?.identityKey
                == transaction.replacementIdentityKey
        else {
            if transaction.replacesSharedAuthentication, let savedSnapshot {
                try switcher.applySharedAuthentication(savedSnapshot, family: profile.family)
                try switcher.writeWorkspaceAuthentication(savedSnapshot, for: profile)
            }
            if profile.identityKey != transaction.previousIdentityKey {
                _ = try store.replaceIdentity(
                    profileID: profile.id,
                    with: transaction.previousIdentityKey
                )
            }
            try store.cancelIdentityReplacement(transaction)
            return false
        }

        try switcher.writeWorkspaceAuthentication(snapshot, for: profile)
        if transaction.replacesSharedAuthentication {
            try switcher.applySharedAuthentication(snapshot, family: profile.family)
            guard let applied = try switcher.readSharedAuthentication(family: profile.family),
                  switcher.identity(of: applied, family: profile.family)?.identityKey
                    == transaction.replacementIdentityKey
            else {
                throw ImportError.verificationFailed(family: profile.family)
            }
        }
        _ = try store.commitIdentityReplacement(transaction)
        AppLog.info(.auth, "recovered an interrupted account identity replacement")
        return true
    }

    @discardableResult
    private func rollbackCredentialTransaction(
        profile: AccountProfile,
        previousSnapshot: AccountCredentialVault.Entry?,
        previousShared: AccountCredentialVault.Entry? = nil,
        restoresSharedAuthentication: Bool = false,
        context: String
    ) -> Bool {
        var restored = true
        if let previousSnapshot {
            do {
                try switcher.saveSnapshot(previousSnapshot, for: profile)
                try switcher.writeWorkspaceAuthentication(previousSnapshot, for: profile)
            } catch {
                restored = false
                AppLog.error(.auth, "\(context) snapshot rollback failed: \(error.localizedDescription)")
            }
        } else {
            do {
                try AccountCredentialVault(keychain: keychain).delete(profile: profile)
                try removeSignInWorkspace(family: profile.family, profileID: profile.id)
            } catch {
                restored = false
                AppLog.error(.auth, "\(context) empty-state rollback failed: \(error.localizedDescription)")
            }
        }
        if restoresSharedAuthentication {
            if let previousShared {
                do {
                    try switcher.applySharedAuthentication(previousShared, family: profile.family)
                } catch {
                    restored = false
                    AppLog.error(.auth, "\(context) shared-home rollback failed: \(error.localizedDescription)")
                }
            } else {
                restored = false
                AppLog.error(.auth, "\(context) shared-home rollback requires crash recovery")
            }
        }
        return restored
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
        let verified: ImportedCredential?
        if family == "claude" {
            guard !store.hasUnreadableRegistry else { throw AccountProfileError.registryUnreadable }
            let profiles = store.profiles
            let preferred = store.preferredProfileID(family: family)
            let revision = store.authenticationRevision
            let replacement = try store.pendingIdentityReplacement()
            guard let observed = try readDefaultCredential(family: family) else { return nil }
            let observer = switcher
            let entry = try await Task.detached(priority: .utility) {
                try await observer.readSharedClaudeExternalAuthentication(comparedTo: nil)
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
            guard let entry, entry.observed == observed.entry,
                try switcher.readSharedAuthentication(family: family) == entry.observed
            else {
                throw ClaudeAuthError.credentialsChanged
            }
            verified = ImportedCredential(entry: entry.snapshot, identityKey: entry.identityKey, label: observed.label)
        } else {
            verified = nil
        }
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        guard let credential = try verified ?? readDefaultCredential(family: family) else { return nil }
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
