import Foundation

extension AccountCredentialImporter {
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
        let loginLock =
            isActive && profile.family == "claude"
            ? try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory) : nil
        defer { withExtendedLifetime(loginLock) {} }
        if loginLock != nil {
            try store.checkPendingPeerClaudeLoginChanges(
                home: switcher.homeDirectory, ownJournal: switcher.switchJournal)
        }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        if profile.family == "claude" { try AccountCredentialMutationLock.requireIdleClaudeRotation() }
        guard
            let credential = try readWorkspaceCredential(
                family: profile.family, profileID: profile.id, attemptID: signInAttemptID
            )
        else {
            throw ImportError.noSignIn(family: profile.family)
        }

        let previousSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: true)
        let isolatedCodexAttempt: (id: String, previousWorkspaceAuth: String?)?
        if profile.family == "codex", let signInAttemptID {
            let path = try codexWorkspaceAuthPath(profileID: profile.id)
            isolatedCodexAttempt = (signInAttemptID, try LocalTextFileAccessor().readTextIfPresent(path))
        } else {
            isolatedCodexAttempt = nil
        }
        let previousClaudeLogin = isActive && profile.family == "claude" ? try switcher.sharedClaudeLogin() : nil
        let claudeState = previousClaudeLogin?.state
        let previousShared =
            isActive && previousClaudeLogin == nil ? try switcher.readSharedAuthentication(family: profile.family) : nil
        let generation = try claudeState.map {
            try AccountIdentityReplacement.ClaudeGeneration(
                state: $0, previousSnapshot: previousSnapshot, replacement: credential.entry
            )
        }
        let transaction = try store.beginIdentityReplacement(
            profileID: profile.id,
            with: credential.identityKey,
            replacesSharedAuthentication: isActive, claudeGeneration: generation
        )
        do {
            try switcher.saveSnapshot(credential.entry, for: profile)
            if signInAttemptID != nil {
                try switcher.writeWorkspaceAuthentication(credential.entry, for: profile)
            }
            if isActive {
                try applySharedSignIn(
                    credential.entry, for: profile, transaction: transaction, expectedClaudeState: claudeState
                )
            }
            let updated = try store.commitIdentityReplacement(transaction)
            AppLog.info(
                .auth,
                "account re-sign-in saved \(profile.family) identity_changed=\(profile.identityKey != credential.identityKey)"
            )
            return updated
        } catch {
            let restored = rollbackCredentialTransaction(
                profile: profile,
                previousSnapshot: previousSnapshot,
                previousShared: previousShared, previousClaudeLogin: previousClaudeLogin,
                transaction: transaction,
                isolatedCodexAttempt: isolatedCodexAttempt,
                context: "account re-sign-in"
            )
            if restored {
                cleanup(family: profile.family, context: "clear restored sign-in journal") {
                    try store.cancelIdentityReplacement(transaction)
                }
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
        let validatesShared = profile.family == "claude" && transaction.replacesSharedAuthentication
        let loginLock =
            validatesShared ? try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory) : nil
        defer { withExtendedLifetime(loginLock) {} }
        if loginLock != nil {
            try store.checkPendingPeerClaudeLoginChanges(
                home: switcher.homeDirectory, ownJournal: switcher.switchJournal)
        }
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        if profile.family == "claude" { try AccountCredentialMutationLock.requireIdleClaudeRotation() }
        let savedSnapshot = try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
        return try finishInterruptedIdentityReplacement(
            transaction, profile: profile, savedSnapshot: savedSnapshot, in: store, allowInteraction: allowInteraction
        )
    }

    /// 승인 가능한 Keychain 작업은 백그라운드에서 수행하고 같은 세대에서만 복구 기록 확정.
    func recoverStartupIdentityReplacement(
        _ transaction: AccountIdentityReplacement, for profile: AccountProfile,
        in store: AccountProfilesStore, allowInteraction: Bool
    ) async throws -> Bool {
        let revision = store.authenticationRevision
        let familyRevision = AccountCredentialMutationLock.revision(for: profile.family)
        let savedSnapshot = try await loadOffMainActor { [switcher] in
            try switcher.loadSnapshot(for: profile, allowInteraction: allowInteraction)
        }
        guard !Task.isCancelled,
            try store.pendingIdentityReplacement() == transaction,
            store.profile(id: profile.id) == profile,
            store.authenticationRevision == revision
        else { return false }
        if profile.family == "codex" {
            return try AccountCredentialMutationLock.withUnchangedRevision(familyRevision) {
                _ = try finishInterruptedIdentityReplacement(
                    transaction, profile: profile, savedSnapshot: savedSnapshot, in: store,
                    allowInteraction: allowInteraction)
            }
        }
        let validatesShared = transaction.replacesSharedAuthentication
        let loginLock =
            validatesShared ? try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory) : nil
        defer { withExtendedLifetime(loginLock) {} }
        if loginLock != nil {
            try store.checkPendingPeerClaudeLoginChanges(
                home: switcher.homeDirectory, ownJournal: switcher.switchJournal)
        }
        try AccountCredentialMutationLock.beginClaudeSwitch()
        defer { AccountCredentialMutationLock.endClaudeSwitch() }
        typealias Recovery = (hasReplacement: Bool, revision: UInt64, shared: AccountSwitchJournal.SharedState?)
        let recovery = try await loadOffMainActor { () -> Recovery? in
            var result: Recovery?
            _ = try AccountCredentialMutationLock.withUnchangedRevision(familyRevision, family: profile.family) {
                let hasReplacement = try applyInterruptedCredentialFiles(
                    transaction, profile: profile, savedSnapshot: savedSnapshot, allowInteraction: allowInteraction)
                let shared =
                    validatesShared && hasReplacement
                    ? try switcher.readClaudeSwitchState(allowInteraction: allowInteraction) : nil
                if let shared, let generation = transaction.claudeGeneration,
                    !generation.matchesReplacement(shared, identity: transaction.replacementIdentityKey)
                {
                    throw ClaudeAuthError.credentialsChanged
                }
                result = (hasReplacement, AccountCredentialMutationLock.revision(for: profile.family), shared)
            }
            return result
        }
        guard let recovery, !Task.isCancelled, try store.pendingIdentityReplacement() == transaction,
            store.profile(id: profile.id) == profile, store.authenticationRevision == revision
        else { return false }
        guard
            try AccountCredentialMutationLock.withUnchangedRevision(
                recovery.revision, family: profile.family,
                {
                    if let shared = recovery.shared,
                        try switcher.readClaudeSwitchState(allowInteraction: false) != shared
                    {
                        throw ClaudeAuthError.credentialsChanged
                    }
                    try finishIdentityReplacementRecord(
                        transaction, profile: profile, hasReplacement: recovery.hasReplacement, in: store)
                })
        else { return false }
        return true
    }

    func finishInterruptedIdentityReplacement(
        _ transaction: AccountIdentityReplacement, profile: AccountProfile,
        savedSnapshot: AccountCredentialVault.Entry?, in store: AccountProfilesStore, allowInteraction: Bool
    ) throws -> Bool {
        let hasReplacement = try applyInterruptedCredentialFiles(
            transaction, profile: profile, savedSnapshot: savedSnapshot, allowInteraction: allowInteraction)
        try finishIdentityReplacementRecord(transaction, profile: profile, hasReplacement: hasReplacement, in: store)
        return hasReplacement
    }

    func finishIdentityReplacementRecord(
        _ transaction: AccountIdentityReplacement, profile: AccountProfile, hasReplacement: Bool,
        in store: AccountProfilesStore
    ) throws {
        if hasReplacement {
            _ = try store.commitIdentityReplacement(transaction)
            AppLog.info(.auth, "recovered an interrupted account identity replacement")
        } else {
            if profile.identityKey != transaction.previousIdentityKey {
                _ = try store.replaceIdentity(profileID: profile.id, with: transaction.previousIdentityKey)
            }
            try store.cancelIdentityReplacement(transaction)
        }
    }

    nonisolated func applyInterruptedCredentialFiles(
        _ transaction: AccountIdentityReplacement, profile: AccountProfile,
        savedSnapshot: AccountCredentialVault.Entry?, allowInteraction: Bool
    ) throws -> Bool {
        let activeClaude = transaction.replacesSharedAuthentication && profile.family == "claude"
        let state = activeClaude ? try switcher.readClaudeSwitchState(allowInteraction: allowInteraction) : nil
        let targetSaved: Bool
        var sharedMatchesSnapshot = false
        let savedIdentity = savedSnapshot.flatMap { switcher.identity(of: $0, family: profile.family)?.identityKey }
        if let state {
            let savedFingerprint = try savedSnapshot.map(AccountIdentityReplacement.ClaudeGeneration.fingerprint)
            if let savedFingerprint, let savedIdentity {
                sharedMatchesSnapshot = state.matches(
                    credentialFingerprint: savedFingerprint, identity: savedIdentity, requiresAllSources: true
                )
            }
            if let generation = transaction.claudeGeneration {
                targetSaved =
                    savedIdentity == transaction.replacementIdentityKey
                    && savedFingerprint == generation.replacementCredentialFingerprint
                let prior = try state.fingerprint() == generation.previousStateFingerprint
                // 중단 지점이 계정 정보 교체 직후라면 이전 토큰과 새 계정 정보가 함께 남음.
                let staged =
                    state.accounts == [savedSnapshot?.claudeOAuthAccount]
                    && state.credentials[0].map(AccountSwitchJournal.fingerprint)
                        == generation.previousCredentialFingerprint
                guard state.sourceID == generation.sourceID else { throw ClaudeAuthError.credentialsChanged }
                if targetSaved {
                    guard prior || sharedMatchesSnapshot || staged else { throw ClaudeAuthError.credentialsChanged }
                } else {
                    guard prior, savedFingerprint == generation.previousSnapshotFingerprint,
                        savedSnapshot == nil || savedIdentity == transaction.previousIdentityKey
                    else { throw ClaudeAuthError.credentialsChanged }
                }
            } else {
                // 이전 기록에는 출처·세대 지문이 없어 공유 인증과 저장본이 같은 경우만 마무리.
                guard sharedMatchesSnapshot else { throw ClaudeAuthError.credentialsChanged }
                targetSaved = savedIdentity == transaction.replacementIdentityKey
            }
        } else if let generation = transaction.externalClaudeGeneration {
            let fingerprint = try savedSnapshot.map(AccountIdentityReplacement.ExternalClaudeGeneration.fingerprint)
            if fingerprint == generation.previousSnapshotFingerprint {
                return false
            }
            // 이미 검증한 보관함 저장만 완료. 이후의 CLI 로그인은 다음 관찰에서 별도 반영.
            guard fingerprint == generation.replacementSnapshotFingerprint,
                savedIdentity == transaction.replacementIdentityKey
            else { throw ClaudeAuthError.credentialsChanged }
            targetSaved = true
        } else {
            targetSaved = savedIdentity == transaction.replacementIdentityKey
        }

        guard targetSaved, let snapshot = savedSnapshot else {
            if transaction.replacesSharedAuthentication, let savedSnapshot {
                if !activeClaude { try switcher.applySharedAuthentication(savedSnapshot, family: profile.family) }
                try switcher.writeWorkspaceAuthentication(
                    savedSnapshot, for: profile, allowInteraction: allowInteraction)
            }
            return false
        }

        try switcher.writeWorkspaceAuthentication(snapshot, for: profile, allowInteraction: allowInteraction)
        if transaction.replacesSharedAuthentication, !sharedMatchesSnapshot {
            try applySharedSignIn(
                snapshot, for: profile, transaction: transaction, expectedClaudeState: state,
                allowInteraction: allowInteraction)
        } else if let state, try switcher.readClaudeSwitchState(allowInteraction: allowInteraction) != state {
            throw ClaudeAuthError.credentialsChanged
        }
        return true
    }

    nonisolated private func applySharedSignIn(
        _ entry: AccountCredentialVault.Entry, for profile: AccountProfile,
        transaction: AccountIdentityReplacement, expectedClaudeState: AccountSwitchJournal.SharedState?,
        allowInteraction: Bool = true
    ) throws {
        try switcher.applySharedAuthentication(
            entry, family: profile.family, expectedClaudeState: expectedClaudeState, allowInteraction: allowInteraction
        )
        if let generation = transaction.claudeGeneration {
            guard
                generation.matchesReplacement(
                    try switcher.readClaudeSwitchState(allowInteraction: allowInteraction),
                    identity: transaction.replacementIdentityKey
                )
            else { throw ClaudeAuthError.credentialsChanged }
        } else {
            guard let applied = try switcher.readSharedAuthentication(family: profile.family),
                switcher.identity(of: applied, family: profile.family)?.identityKey
                    == transaction.replacementIdentityKey
            else { throw ImportError.verificationFailed(family: profile.family) }
        }
    }

    @discardableResult
    nonisolated func rollbackCredentialTransaction(
        profile: AccountProfile,
        previousSnapshot: AccountCredentialVault.Entry?,
        previousShared: AccountCredentialVault.Entry? = nil,
        previousClaudeLogin: AccountCredentialSwitcher.SharedClaudeLogin? = nil,
        transaction: AccountIdentityReplacement? = nil, allowInteraction: Bool = true,
        isolatedCodexAttempt: (id: String, previousWorkspaceAuth: String?)? = nil,
        context: String
    ) -> Bool {
        var restored = true
        if let transaction, transaction.replacesSharedAuthentication {
            do {
                if let generation = transaction.claudeGeneration {
                    let current = try switcher.readClaudeSwitchState(allowInteraction: allowInteraction)
                    if try current.fingerprint() != generation.previousStateFingerprint {
                        guard let previousClaudeLogin,
                            generation.matchesReplacement(current, identity: transaction.replacementIdentityKey)
                        else { throw ClaudeAuthError.credentialsChanged }
                        try switcher.rollbackSharedClaudeLogin(to: previousClaudeLogin, replacing: current)
                    }
                } else if let previousShared {
                    try switcher.applySharedAuthentication(previousShared, family: profile.family)
                } else {
                    throw AccountIdentityReplacementError.invalidTransaction
                }
            } catch {
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: profile.family,
                    localContext: "\(context): restore shared login")
                // 다른 CLI 세대가 관찰되면 다시 시도할 수 있도록 교체 저장본과 기록 보존.
                if transaction.claudeGeneration != nil { return false }
                restored = false
            }
        }
        if let previousSnapshot {
            do {
                if isolatedCodexAttempt == nil {
                    try switcher.writeWorkspaceAuthentication(
                        previousSnapshot, for: profile, allowInteraction: allowInteraction)
                }
                // 복구 기록은 보관함으로 적용 여부를 판단. 작업 공간까지 복구한 뒤 보관함을 되돌림.
                try switcher.saveSnapshot(previousSnapshot, for: profile)
            } catch {
                restored = false
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: profile.family,
                    localContext: "\(context): restore saved login")
            }
        } else {
            do {
                if isolatedCodexAttempt == nil {
                    try removeSignInWorkspace(family: profile.family, profileID: profile.id)
                }
                try AccountCredentialVault(keychain: keychain).delete(profile: profile)
            } catch {
                restored = false
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: profile.family,
                    localContext: "\(context): remove staged login")
            }
        }
        if let isolatedCodexAttempt {
            do {
                try restoreCodexWorkspace(
                    profileID: profile.id, attemptID: isolatedCodexAttempt.id,
                    previousAuthentication: isolatedCodexAttempt.previousWorkspaceAuth)
            } catch {
                restored = false
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: profile.family,
                    localContext: "\(context): restore Codex sign-in workspace")
            }
        }
        return restored
    }
}
