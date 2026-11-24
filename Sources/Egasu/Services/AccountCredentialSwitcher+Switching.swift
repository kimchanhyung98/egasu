import Foundation

extension AccountCredentialSwitcher {
    // MARK: - Switch transaction

    /// 이전 계정의 갱신된 인증을 보존하고 대상 계정의 인증을 적용.
    /// 선택 계정은 이 함수의 검증이 끝난 뒤 호출자가 저장.
    /// Codex 추천의 출발 콜백에는 사용자·워크스페이스 키 전달.
    func switchAuthentication(
        to selected: AccountProfile,
        from current: AccountProfile?,
        verifiedClaudeDeparture: VerifiedClaudeExternalAuthentication? = nil,
        expectedTarget: AccountCredentialVault.Entry? = nil,
        expectedClaudeState: AccountSwitchJournal.SharedState? = nil,
        validateCodexDeparture: ((String?) throws -> Void)? = nil,
        validateTarget: ((AccountCredentialVault.Entry) throws -> Void)? = nil
    ) throws {
        guard AccountProfilesStore.isSupportedFamily(selected.family) else {
            throw Error.unsupportedFamily(selected.family)
        }
        // 활성 profile 재선택 시 쓰기 1건도 발생 금지.
        guard current?.id != selected.id else { return }
        AccountCredentialMutationLock.acquire(family: selected.family)
        defer { AccountCredentialMutationLock.release(family: selected.family) }
        if selected.family == "claude" { try AccountCredentialMutationLock.requireIdleClaudeRotation() }

        let target: AccountCredentialVault.Entry
        do {
            guard let snapshot = try loadSnapshot(for: selected, allowInteraction: true) else {
                throw Error.missingSnapshot(selected.label)
            }
            target = snapshot
        } catch AccountCredentialVaultError.missingEntry {
            throw Error.missingSnapshot(selected.label)
        }
        if let expectedTarget, target != expectedTarget { throw ClaudeAuthError.credentialsChanged }
        guard identity(of: target, family: selected.family)?.identityKey == selected.identityKey else {
            throw Error.snapshotIdentityMismatch(selected.label)
        }

        if let verifiedClaudeDeparture, let current, current.family == "claude" {
            guard try loadSnapshot(for: current, allowInteraction: true) == verifiedClaudeDeparture.baseline else {
                throw ClaudeAuthError.credentialsChanged
            }
        }
        // 활성 credential은 적용 후 rotate됐을 수 있음 — 현재 profile과 일치할 때만 보존.
        let initialClaudeState = selected.family == "claude" ? try readClaudeSwitchState() : nil
        if let expectedClaudeState, expectedClaudeState != initialClaudeState {
            throw ClaudeAuthError.credentialsChanged
        }
        if let verifiedClaudeDeparture, verifiedClaudeDeparture.sourceID != initialClaudeState?.sourceID {
            throw ClaudeAuthError.credentialsChanged
        }
        let active: AccountCredentialVault.Entry?
        if let initialClaudeState {
            active = sharedClaudeAuthentication(in: initialClaudeState)
        } else {
            active = try readSharedAuthentication(family: selected.family)
        }
        if selected.family == "claude", let verifiedClaudeDeparture, active != verifiedClaudeDeparture.observed {
            throw ClaudeAuthError.credentialsChanged
        }
        let checksCodexDeparture = selected.family == "codex" && validateCodexDeparture != nil
        var expectedCodexSnapshot =
            try checksCodexDeparture
            ? current.flatMap { try loadSnapshot(for: $0, allowInteraction: true) } : nil
        func validateCodexRecommendation() throws {
            guard selected.family == "codex", validateCodexDeparture != nil || validateTarget != nil else { return }
            let saved =
                try checksCodexDeparture
                ? current.flatMap { try loadSnapshot(for: $0, allowInteraction: true) } : nil
            if let validateTarget {
                guard let latestTarget = try loadSnapshot(for: selected, allowInteraction: true), latestTarget == target
                else {
                    throw CodexAuthError.credentialsChanged
                }
                try validateTarget(latestTarget)
            }
            let latest = try readSharedAuthentication(family: "codex")
            guard latest == active else { throw CodexAuthError.credentialsChanged }
            if let validateCodexDeparture {
                guard saved == expectedCodexSnapshot else { throw CodexAuthError.credentialsChanged }
                guard
                    let accountKey = latest.flatMap({ CodexResetClaimBinding.verifiedAccountKey(for: $0.credential) }),
                    saved.flatMap({ CodexResetClaimBinding.verifiedAccountKey(for: $0.credential) }) == accountKey
                else { throw AccountSwitchRecommendation.NoLongerAvailable() }
                try validateCodexDeparture(accountKey)
            }
        }
        if let current, current.family == selected.family, let active {
            let activeIdentity = identity(of: active, family: current.family)?.identityKey
            var preserved: AccountCredentialVault.Entry?
            if current.family == "claude" {
                if let verifiedClaudeDeparture {
                    if verifiedClaudeDeparture.identityKey == current.identityKey {
                        preserved = verifiedClaudeDeparture.snapshot
                    } else if !current.identityKey.contains("|"), activeIdentity == current.identityKey,
                        String(verifiedClaudeDeparture.identityKey.prefix { $0 != "|" }) == current.identityKey
                    {
                        preserved = verifiedClaudeDeparture.observed
                    }
                } else if activeIdentity == current.identityKey {
                    let saved = try loadSnapshot(for: current, allowInteraction: true)
                    guard saved == active else { throw ClaudeAuthError.credentialsChanged }
                    preserved = active
                }
            } else if activeIdentity == current.identityKey {
                preserved = active
                if current.family == "codex",
                    let snapshot = try checksCodexDeparture
                        ? expectedCodexSnapshot : loadSnapshot(for: current, allowInteraction: true),
                   snapshot.codexStaleSharedCredentialFingerprints?.contains(CodexAuthStore.credentialFingerprint(active.credential)) == true,
                   identity(of: snapshot, family: current.family)?.identityKey == current.identityKey {
                    preserved = snapshot
                }
            }
            if let preserved {
                try validateCodexRecommendation()
                if let initialClaudeState, try readClaudeSwitchState() != initialClaudeState {
                    throw ClaudeAuthError.credentialsChanged
                }
                try saveSnapshot(preserved, for: current)
                try writeWorkspaceAuthentication(preserved, for: current)
                if checksCodexDeparture { expectedCodexSnapshot = preserved }
            }
        }

        if let expectedTarget {
            guard try loadSnapshot(for: selected, allowInteraction: true) == expectedTarget else {
                throw ClaudeAuthError.credentialsChanged
            }
            if let verifiedClaudeDeparture,
                try readSharedAuthentication(family: "claude") != verifiedClaudeDeparture.observed
            {
                throw ClaudeAuthError.credentialsChanged
            }
        }
        try validateCodexRecommendation()
        do {
            try applySharedAuthentication(target, family: selected.family, expectedClaudeState: initialClaudeState)
            let applied = try readSharedAuthentication(family: selected.family)
            guard let applied,
                  identity(of: applied, family: selected.family)?.identityKey == selected.identityKey else {
                throw Error.switchVerificationFailed(selected.label)
            }
            if selected.family == "codex", target.codexStaleSharedCredentialFingerprints != nil {
                var synchronized = target
                synchronized.codexStaleSharedCredentialFingerprints = nil
                try saveSnapshot(synchronized, for: selected)
            }
        } catch {
            if selected.family == "codex", let active {
                do {
                    let current = try readSharedAuthentication(family: "codex")
                        .map { AccountSwitchJournal.fingerprint($0.credential) }
                    if current == AccountSwitchJournal.fingerprint(target.credential) {
                        try applySharedAuthentication(active, family: selected.family)
                    } else if current != AccountSwitchJournal.fingerprint(active.credential) {
                        throw CodexAuthError.credentialsChanged
                    }
                } catch {
                    AppDiagnostics.failure(
                        .accountRollback, error: error, providerID: selected.family,
                        localContext: "restore shared login")
                }
            }
            throw error
        }
    }
}
