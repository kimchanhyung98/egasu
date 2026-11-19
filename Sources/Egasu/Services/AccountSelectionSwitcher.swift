import Foundation

/// 공유 로그인과 선택 계정의 전환 경계 — Claude의 중단 기록을 외부 로그인 반영보다 먼저 복구.
@MainActor
struct AccountSelectionSwitcher {
    private let switcher: AccountCredentialSwitcher
    private let journal: AccountSwitchJournal

    init(
        switcher: AccountCredentialSwitcher = AccountCredentialSwitcher(),
        journal: AccountSwitchJournal? = nil
    ) {
        self.switcher = switcher
        self.journal = journal ?? switcher.switchJournal
    }

    func hasPendingSwitch() throws -> Bool {
        try journal.load() != nil
    }

    func switchAuthentication(to selected: AccountProfile, in store: AccountProfilesStore) async throws {
        guard store.profile(id: selected.id) == selected else {
            throw AccountProfileError.profileNotFound(selected.id)
        }
        if selected.family != "claude" {
            try switcher.switchAuthentication(to: selected, from: store.preferredProfile(family: selected.family))
            store.setPreferred(family: selected.family, profileID: selected.id)
            return
        }
        guard !store.hasUnreadableRegistry, try store.pendingIdentityReplacement() == nil else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        var previousRecord = try journal.load()
        var interruptedState: AccountSwitchJournal.SharedState?
        if let record = previousRecord {
            let state = try await readSwitchState(in: store, expecting: record)
            if let profileID = selection(for: record, state: state, in: store) {
                try finish(record, selecting: profileID, observed: state, in: store)
                previousRecord = nil
            } else if state.permitsRetry(of: record) {
                interruptedState = state
            } else {
                guard try await repairRotatedDeparture(record, state: state, in: store) else {
                    throw AccountCredentialSwitcher.Error.switchRecoveryRequired
                }
                previousRecord = nil
            }
        }
        guard let preferred = store.preferredProfile(family: "claude") else {
            throw AccountProfileError.profileNotFound(selected.id)
        }
        guard preferred.id != selected.id || previousRecord != nil else { return }
        let previous: AccountProfile
        if let record = previousRecord {
            guard let profile = store.profile(id: record.previousProfileID),
                  profile.family == "claude", profile.identityKey == record.previousIdentity else {
                throw AccountIdentityReplacementError.invalidTransaction
            }
            previous = profile
        } else {
            previous = preferred
        }
        guard let target = try switcher.loadSnapshot(for: selected, allowInteraction: true) else {
            throw AccountCredentialSwitcher.Error.missingSnapshot(selected.label)
        }
        guard let targetAccount = target.claudeOAuthAccount,
            switcher.identity(of: target, family: "claude")?.identityKey == selected.identityKey
        else {
            throw AccountCredentialSwitcher.Error.snapshotIdentityMismatch(selected.label)
        }

        let state: AccountSwitchJournal.SharedState
        var previousCredential = previousRecord?.previousCredentialFingerprint
        var previousState = previousRecord?.previousStateFingerprint
        if let interruptedState, interruptedState.sourceID == nil {
            // 구형 세 곳의 원문 지문은 해당 사본을 확인한 뒤 현재 로그인 전용 지문으로 이전.
            state = try await readSwitchState(in: store, expecting: previousRecord, legacyRecord: false)
            guard try await readSwitchState(in: store, expecting: previousRecord) == interruptedState else {
                throw ClaudeAuthError.credentialsChanged
            }
            guard interruptedState.containsLegacyLogin(state) else {
                throw AccountCredentialSwitcher.Error.switchRecoveryRequired
            }
            let oldCredential = interruptedState.credentials.compactMap { $0 }.first {
                AccountSwitchJournal.fingerprint($0) == previousCredential
            }
            previousCredential = try oldCredential.map {
                AccountSwitchJournal.fingerprint(try ClaudeAccountLoginCredentials.loginOnly($0))
            }
            previousState = nil
        } else if let interruptedState {
            state = interruptedState
        } else {
            state = try await readSwitchState(in: store, expecting: previousRecord)
        }
        guard let sourceID = state.sourceID else { throw AccountIdentityReplacementError.invalidTransaction }
        let departure = try await verifiedDeparture(
            previousRecord == nil ? previous : nil, state: state, in: store, expecting: previousRecord
        )
        let activeFingerprint = departure.active.map { AccountSwitchJournal.fingerprint($0.credential) }
        let verifiedIdentity = departure.verified?.identityKey
        let canPreservePrevious =
            previousRecord == nil
            && (verifiedIdentity == previous.identityKey
                || (!previous.identityKey.contains("|")
                    && departure.active.flatMap { switcher.identity(of: $0, family: "claude")?.identityKey }
                        == previous.identityKey
                    && verifiedIdentity.map { String($0.prefix { $0 != "|" }) } == previous.identityKey))
        let record = AccountSwitchJournal.Record(
            previousProfileID: previous.id,
            previousIdentity: previous.identityKey,
            previousCredentialFingerprint: canPreservePrevious ? activeFingerprint : previousCredential,
            previousStateFingerprint: previousRecord == nil ? try state.fingerprint() : previousState,
            priorSelectionIDs: Array(Set((previousRecord?.priorSelectionIDs ?? []) + [preferred.id]))
                .filter { store.profile(id: $0)?.family == "claude" }.sorted(),
            selectedProfileID: selected.id,
            selectedIdentity: selected.identityKey,
            selectedCredentialFingerprint: AccountSwitchJournal.fingerprint(target.credential),
            sourceID: sourceID,
            retryStateFingerprints: try state.retryStateFingerprints(
                staging: targetAccount, identity: selected.identityKey)
        )

        let loginLock = try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        try AccountCredentialMutationLock.beginClaudeSwitch()
        defer { AccountCredentialMutationLock.endClaudeSwitch() }
        do {
            AccountCredentialMutationLock.acquire(family: "claude")
            defer { AccountCredentialMutationLock.release(family: "claude") }
            guard try switcher.readClaudeSwitchState() == state else { throw ClaudeAuthError.credentialsChanged }
            try journal.save(record, replacing: previousRecord)
            // 재시도 중 혼합된 공유 인증은 어느 계정의 저장 인증에도 반영하지 않음.
            try switcher.switchAuthentication(
                to: selected, from: previousRecord == nil ? previous : nil,
                verifiedClaudeDeparture: previousRecord == nil ? departure.verified : nil,
                expectedTarget: target, expectedClaudeState: state
            )
        } catch let switchError {
            do {
                if try journal.load() == record {
                    let interrupted = try await readSwitchState(in: store, expecting: record)
                    if interrupted.identities == [record.selectedIdentity], !interrupted.permitsRetry(of: record) {
                        _ = try await repairRotatedDeparture(
                            record, state: interrupted, in: store, sharedLoginLockHeld: true)
                    }
                }
            } catch {
                AppDiagnostics.failure(
                    .accountRollback, error: error, providerID: "claude",
                    localContext: "verify and repair interrupted switch metadata")
            }
            throw switchError
        }
        let applied = try await readSwitchState(in: store, expecting: record)
        guard
            applied.matches(
                credentialFingerprint: record.selectedCredentialFingerprint,
                identity: record.selectedIdentity,
                requiresAllSources: true
            )
        else {
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
        try finish(record, selecting: selected.id, observed: applied, in: store, sharedLoginLockHeld: true)
    }

    private func repairRotatedDeparture(
        _ record: AccountSwitchJournal.Record, state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore, sharedLoginLockHeld: Bool = false
    ) async throws -> Bool {
        guard record.sourceID != nil, state.sourceID == record.sourceID, record.retryStateFingerprints != nil,
            let previous = store.profile(id: record.previousProfileID), previous.family == "claude",
            previous.identityKey == record.previousIdentity, previous.identityKey.contains("|"),
            let previousFingerprint = record.previousCredentialFingerprint,
            let selected = store.profile(id: record.selectedProfileID), selected.family == "claude",
            selected.identityKey == record.selectedIdentity,
            let preferred = store.preferredProfileID(family: "claude"),
            ([previous.id, selected.id] + record.priorSelectionIDs).contains(preferred),
            let credential = state.credentials[0],
            let token = ClaudeAuthStore.parseCredentials(credential)?.claudeAiOauth?.accessToken?.nilIfEmpty
        else { return false }

        let profiles = store.profiles
        let revision = store.authenticationRevision
        let observer = switcher
        let snapshot = try await loadOffMainActor {
            try observer.loadSnapshot(for: previous, allowInteraction: true)
        }
        guard let saved = snapshot, let previousAccount = saved.claudeOAuthAccount,
            switcher.identity(of: saved, family: "claude")?.identityKey == previous.identityKey,
            AccountSwitchJournal.fingerprint(saved.credential) == previousFingerprint
        else { return false }
        let alreadyRepaired = state.accounts == [previousAccount] && state.identities == [previous.identityKey]
        let matchesStagedAccount = try state.matchesStagedAccount(of: record, with: saved.credential)
        guard alreadyRepaired || matchesStagedAccount else { return false }

        let profile = try await switcher.claudeProfile(for: token)
        guard try profile.accountIdentityKey() == previous.identityKey else {
            AppLog.warn(.auth, "interrupted Claude switch token ownership differs from the departing account")
            return false
        }
        try Task.checkCancellation()
        let loginLock =
            sharedLoginLockHeld
            ? nil : try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        AccountCredentialMutationLock.acquire(family: "claude")
        defer { AccountCredentialMutationLock.release(family: "claude") }
        try AccountCredentialMutationLock.requireIdleClaudeRotation()
        guard !store.hasUnreadableRegistry, store.profiles == profiles, store.authenticationRevision == revision,
            store.preferredProfileID(family: "claude") == preferred, try store.pendingIdentityReplacement() == nil,
            try journal.load() == record, try switcher.loadSnapshot(for: previous, allowInteraction: true) == saved
        else { throw ClaudeAuthError.credentialsChanged }
        let repaired = try switcher.repairSharedClaudeAccountMetadata(
            previousAccount, identity: previous.identityKey, expecting: state)
        try finish(record, selecting: previous.id, observed: repaired, in: store, sharedLoginLockHeld: true)
        return true
    }

    private func verifiedDeparture(
        _ previous: AccountProfile?,
        state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore,
        expecting record: AccountSwitchJournal.Record?
    ) async throws -> (
        active: AccountCredentialVault.Entry?, verified: AccountCredentialSwitcher.VerifiedClaudeExternalAuthentication?
    ) {
        let active = try switcher.readSharedAuthentication(family: "claude")
        guard let previous, let active,
            let activeIdentity = switcher.identity(of: active, family: "claude")?.identityKey,
            activeIdentity == previous.identityKey
                || (!activeIdentity.contains("|")
                    && activeIdentity == String(previous.identityKey.prefix { $0 != "|" }))
        else { return (active, nil) }
        let profiles = store.profiles
        let preferred = store.preferredProfileID(family: "claude")
        let revision = store.authenticationRevision
        let observer = switcher
        let observation = try await Task.detached(priority: .utility) {
            let snapshot = try observer.loadSnapshot(for: previous, allowInteraction: true)
            let verified = try await observer.readSharedClaudeExternalAuthentication(
                comparedTo: snapshot, allowInteraction: true)
            let currentSnapshot = try observer.loadSnapshot(for: previous, allowInteraction: true)
            let currentShared = try observer.readSharedAuthentication(family: "claude")
            let currentState = try observer.readClaudeSwitchState()
            return (
                snapshot: snapshot, verified: verified, currentSnapshot: currentSnapshot,
                currentShared: currentShared, currentState: currentState
            )
        }.value
        try Task.checkCancellation()
        guard !store.hasUnreadableRegistry, store.profiles == profiles,
            store.preferredProfileID(family: "claude") == preferred,
            store.authenticationRevision == revision,
            try store.pendingIdentityReplacement() == nil,
            try journal.load() == record
        else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        guard observation.verified?.observed == active,
            observation.currentSnapshot == observation.snapshot,
            observation.currentShared == observation.verified?.observed,
            observation.currentState == state
        else {
            throw ClaudeAuthError.credentialsChanged
        }
        return (active, observation.verified)
    }

    @discardableResult
    func recoverInterruptedSwitch(in store: AccountProfilesStore) throws -> Bool {
        guard let record = try journal.load() else { return false }
        let state = try switcher.readClaudeSwitchState(legacyRecord: record.sourceID == nil)
        return try recover(record, state: state, in: store)
    }

    @discardableResult
    func recoverInterruptedSwitchAfterStartup(
        in store: AccountProfilesStore, allowInteraction: Bool = true
    ) async throws -> Bool {
        guard let record = try journal.load() else { return false }
        let state = try await readSwitchState(in: store, expecting: record, allowInteraction: allowInteraction)
        return try recover(record, state: state, in: store, allowInteraction: allowInteraction)
    }

    private func readSwitchState(
        in store: AccountProfilesStore,
        expecting record: AccountSwitchJournal.Record?,
        legacyRecord: Bool? = nil,
        allowInteraction: Bool = true
    ) async throws -> AccountSwitchJournal.SharedState {
        guard !store.hasUnreadableRegistry, try journal.load() == record else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        let profiles = store.profiles
        let preferred = store.preferredProfileID(family: "claude")
        let revision = store.authenticationRevision
        let identityReplacement = try store.pendingIdentityReplacement()
        let observer = switcher
        let readsLegacy = legacyRecord ?? (record != nil && record?.sourceID == nil)
        let state = try await loadOffMainActor {
            try observer.readClaudeSwitchState(legacyRecord: readsLegacy, allowInteraction: allowInteraction)
        }
        try Task.checkCancellation()
        guard !store.hasUnreadableRegistry,
              store.profiles == profiles,
              store.preferredProfileID(family: "claude") == preferred,
              store.authenticationRevision == revision,
              try store.pendingIdentityReplacement() == identityReplacement,
              try journal.load() == record
        else {
            throw AccountIdentityReplacementError.pendingTransaction
        }
        if let sourceID = record?.sourceID, state.sourceID != sourceID {
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
        return state
    }

    private func recover(
        _ record: AccountSwitchJournal.Record,
        state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore,
        allowInteraction: Bool = true
    ) throws -> Bool {
        guard let profileID = selection(for: record, state: state, in: store) else {
            AppLog.error(.auth, "account switch recovery found an unknown credential generation; preserving saved accounts")
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
        try finish(record, selecting: profileID, observed: state, in: store, allowInteraction: allowInteraction)
        return true
    }

    private func selection(
        for record: AccountSwitchJournal.Record,
        state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore
    ) -> String? {
        guard state.sourceID == record.sourceID, !store.hasUnreadableRegistry,
              let previous = store.profile(id: record.previousProfileID),
              previous.family == "claude", previous.identityKey == record.previousIdentity,
              let selected = store.profile(id: record.selectedProfileID),
              selected.family == "claude", selected.identityKey == record.selectedIdentity,
              let preferred = store.preferredProfileID(family: "claude"),
              ([previous.id, selected.id] + record.priorSelectionIDs).contains(preferred)
        else { return nil }
        if state.matches(
            credentialFingerprint: record.selectedCredentialFingerprint,
            identity: record.selectedIdentity,
            requiresAllSources: true
        ) {
            return selected.id
        }
        if let previousFingerprint = record.previousStateFingerprint,
           (try? state.fingerprint()) == previousFingerprint {
            return previous.id
        }
        if let previousFingerprint = record.previousCredentialFingerprint,
           state.matches(
            credentialFingerprint: previousFingerprint,
            identity: record.previousIdentity,
            requiresAllSources: true
           ) {
            return previous.id
        }
        return nil
    }

    private func finish(
        _ record: AccountSwitchJournal.Record,
        selecting profileID: String,
        observed state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore,
        allowInteraction: Bool = true,
        sharedLoginLockHeld: Bool = false
    ) throws {
        let loginLock =
            sharedLoginLockHeld
            ? nil : try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        AccountCredentialMutationLock.acquire(family: "claude")
        defer { AccountCredentialMutationLock.release(family: "claude") }
        try AccountCredentialMutationLock.requireIdleClaudeRotation()
        guard try journal.load() == record else { throw AccountIdentityReplacementError.pendingTransaction }
        guard
            try switcher.readClaudeSwitchState(
                legacyRecord: record.sourceID == nil, allowInteraction: allowInteraction) == state
        else {
            throw ClaudeAuthError.credentialsChanged
        }
        try store.commitPreferredSelection(family: "claude", profileID: profileID)
        try journal.clear(record)
    }
}
