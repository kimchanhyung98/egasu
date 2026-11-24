import Foundation

/// 명시적 Codex 전환은 저장본을 검증하고 공유 로그인 전환 뒤 중단 거래 확정.
@MainActor
enum CodexExplicitSwitchRecovery {
    struct Plan {
        let transaction: AccountIdentityReplacement
        let profile: AccountProfile
        let snapshot: AccountCredentialVault.Entry?
        let hasReplacement: Bool

        var resolvedProfile: AccountProfile {
            var resolved = profile
            resolved.identityKey = hasReplacement ? transaction.replacementIdentityKey : transaction.previousIdentityKey
            return resolved
        }
    }

    static func prepare(in store: AccountProfilesStore, using switcher: AccountCredentialSwitcher) throws -> Plan? {
        guard let transaction = try store.pendingIdentityReplacement(),
            let profile = store.profile(id: transaction.profileID), profile.family == "codex"
        else { return nil }
        let snapshot = try switcher.loadSnapshot(for: profile, allowInteraction: true)
        let identity = snapshot.flatMap { switcher.identity(of: $0, family: "codex")?.identityKey }
        let hasReplacement = try transaction.hasSavedCodexReplacement(snapshot, identity: identity)
        if let snapshot { try switcher.writeWorkspaceAuthentication(snapshot, for: profile) }
        return Plan(transaction: transaction, profile: profile, snapshot: snapshot, hasReplacement: hasReplacement)
    }

    static func apply(
        _ plan: Plan, to selected: AccountProfile, in store: AccountProfilesStore,
        using switcher: AccountCredentialSwitcher
    ) throws {
        let target = plan.profile.id == selected.id ? plan.resolvedProfile : selected
        let preferred = store.preferredProfile(family: "codex")
        let previous = plan.profile.id == preferred?.id ? nil : preferred
        var rollback: (previous: String?, target: String)?
        do {
            try switcher.switchAuthentication(
                to: target, from: previous,
                validateTarget: { entry in
                    rollback = (try sharedAuthenticationText(using: switcher), entry.credential)
                })
            try store.commitPreferredSelection(family: "codex", profileID: target.id)
            try complete(plan, in: store, using: switcher)
        } catch {
            if let rollback {
                do {
                    try restoreSharedAuthentication(rollback, using: switcher)
                } catch {
                    AppDiagnostics.failure(
                        .accountRollback, error: error, providerID: "codex",
                        localContext: "restore explicit recovery shared login")
                }
            }
            if let preferred, preferred.id != target.id,
                store.preferredProfileID(family: "codex") == target.id
            {
                do {
                    try store.commitPreferredSelection(family: "codex", profileID: preferred.id)
                } catch {
                    AppDiagnostics.failure(
                        .accountRollback, error: error, providerID: "codex",
                        localContext: "restore explicit recovery selection")
                }
            }
            throw error
        }
    }

    static func complete(_ plan: Plan, in store: AccountProfilesStore, using switcher: AccountCredentialSwitcher) throws
    {
        guard try store.pendingIdentityReplacement() == plan.transaction,
            try switcher.loadSnapshot(for: plan.profile, allowInteraction: true)
                .map(AccountIdentityReplacement.CodexGeneration.fingerprint)
                == plan.snapshot.map(AccountIdentityReplacement.CodexGeneration.fingerprint)
        else { throw CodexAuthError.credentialsChanged }
        if plan.hasReplacement {
            _ = try store.commitIdentityReplacement(plan.transaction)
        } else {
            if plan.profile.identityKey != plan.transaction.previousIdentityKey {
                _ = try store.replaceIdentity(profileID: plan.profile.id, with: plan.transaction.previousIdentityKey)
            }
            try store.cancelIdentityReplacement(plan.transaction)
        }
    }

    private nonisolated static func sharedAuthenticationText(using switcher: AccountCredentialSwitcher) throws
        -> String?
    {
        let path = URL(fileURLWithPath: switcher.sharedHomePath(family: "codex")).appendingPathComponent("auth.json")
        return try LocalTextFileAccessor().readTextIfPresent(path.path)
    }

    private nonisolated static func restoreSharedAuthentication(
        _ rollback: (previous: String?, target: String), using switcher: AccountCredentialSwitcher
    ) throws {
        let current = try sharedAuthenticationText(using: switcher).map(AccountSwitchJournal.fingerprint)
        if current == rollback.previous.map(AccountSwitchJournal.fingerprint) { return }
        guard current == AccountSwitchJournal.fingerprint(rollback.target) else {
            throw CodexAuthError.credentialsChanged
        }
        if let previous = rollback.previous {
            try switcher.applySharedAuthentication(
                .init(credential: previous, claudeOAuthAccount: nil), family: "codex")
        } else {
            let path = URL(fileURLWithPath: switcher.sharedHomePath(family: "codex")).appendingPathComponent(
                "auth.json")
            try FileManager.default.removeItem(at: path)
        }
    }
}
