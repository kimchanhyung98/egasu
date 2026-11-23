import Foundation

extension AccountCredentialImporter {
    /// 인증 없는 상태와 읽을 수 없는 인증 원문을 구분해 재로그인 세대 비교에 사용.
    nonisolated func readSharedCodexReplacementState() throws -> AccountCredentialVault.Entry? {
        let path = URL(fileURLWithPath: switcher.sharedHomePath(family: "codex"))
            .appendingPathComponent("auth.json").path
        return try LocalTextFileAccessor().readTextIfPresent(path).map {
            AccountCredentialVault.Entry(credential: $0, claudeOAuthAccount: nil)
        }
    }

    @discardableResult
    nonisolated func validateSharedCodexReplacement(
        _ generation: AccountIdentityReplacement.CodexGeneration, replacement: AccountCredentialVault.Entry? = nil
    ) throws -> String? {
        guard generation.sharedHome == switcher.sharedHomePath(family: "codex") else {
            throw CodexAuthError.credentialsChanged
        }
        let current = try readSharedCodexReplacementState().map(AccountIdentityReplacement.CodexGeneration.fingerprint)
        let replacementFingerprint = replacement.map(AccountIdentityReplacement.CodexGeneration.fingerprint)
        guard
            current == generation.previousSharedFingerprint || current == generation.replacementFingerprint
                || replacementFingerprint != nil && current == replacementFingerprint
        else {
            throw CodexAuthError.credentialsChanged
        }
        return current
    }

    nonisolated func codexReplacementRecovery(
        _ transaction: AccountIdentityReplacement, savedSnapshot: AccountCredentialVault.Entry?
    ) throws -> (targetSaved: Bool, sharedNeedsNoWrite: Bool) {
        let fingerprint = savedSnapshot.map(AccountIdentityReplacement.CodexGeneration.fingerprint)
        let identity = savedSnapshot.flatMap { switcher.identity(of: $0, family: "codex")?.identityKey }
        guard let generation = transaction.codexGeneration else {
            let current = try readSharedCodexReplacementState().map(
                AccountIdentityReplacement.CodexGeneration.fingerprint)
            // 구형 기록은 이후 로그인과 구분할 세대 지문이 없어 현재 저장본과 같은 공유 인증만 마무리.
            guard current == fingerprint else { throw CodexAuthError.credentialsChanged }
            return (try transaction.hasSavedCodexReplacement(savedSnapshot, identity: identity), true)
        }
        let targetSaved = try transaction.hasSavedCodexReplacement(savedSnapshot, identity: identity)
        let current = try validateSharedCodexReplacement(generation, replacement: targetSaved ? savedSnapshot : nil)
        if targetSaved { return (true, current == fingerprint) }
        if current == generation.previousSharedFingerprint { return (false, true) }
        guard fingerprint == generation.previousSharedFingerprint else { throw CodexAuthError.credentialsChanged }
        return (false, false)
    }

    nonisolated func rollbackSharedCodexReplacement(
        _ generation: AccountIdentityReplacement.CodexGeneration, previousShared: AccountCredentialVault.Entry?
    ) throws {
        let current = try validateSharedCodexReplacement(generation)
        guard current != generation.previousSharedFingerprint else { return }
        guard
            previousShared.map(AccountIdentityReplacement.CodexGeneration.fingerprint)
                == generation.previousSharedFingerprint
        else { throw CodexAuthError.credentialsChanged }
        if let previousShared {
            try switcher.applySharedAuthentication(previousShared, family: "codex")
        } else {
            let path = URL(fileURLWithPath: switcher.sharedHomePath(family: "codex")).appendingPathComponent(
                "auth.json")
            try FileManager.default.removeItem(at: path)
        }
    }

    func reconcileCodexIdentityReplacementAfterStartup(in store: AccountProfilesStore) async throws
        -> ExternalReauthenticationResult
    {
        guard let transaction = try store.pendingIdentityReplacement(),
            let profile = store.profile(id: transaction.profileID), profile.family == "codex"
        else { return .unchanged }
        let completed = try await recoverStartupIdentityReplacement(
            transaction, for: profile, in: store, allowInteraction: ProviderRefreshContext.isManual)
        return completed ? .updated(profileID: profile.id) : .unchanged
    }
}
