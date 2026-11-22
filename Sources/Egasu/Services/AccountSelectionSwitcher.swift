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
                try await finish(record, selecting: profileID, observed: state, in: store)
                previousRecord = nil
            } else if state.permitsRetry(of: record) {
                interruptedState = state
            } else {
                guard
                    try await recoverRotatedLogin(
                        record, state: state, in: store, repairDepartingAccount: true) != nil
                else {
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
        try store.checkPendingPeerClaudeLoginChanges(home: switcher.homeDirectory, ownJournal: journal)
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
                        let recovered = try await recoverRotatedLogin(
                            record, state: interrupted, in: store, repairDepartingAccount: true,
                            sharedLoginLockHeld: true)
                        if recovered == selected.id { return }
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
        if applied.matches(
            credentialFingerprint: record.selectedCredentialFingerprint,
            identity: record.selectedIdentity, requiresAllSources: true
        ) {
            try await finish(record, selecting: selected.id, observed: applied, in: store, sharedLoginLockHeld: true)
        } else if try await recoverRotatedLogin(
            record, state: applied, in: store, repairDepartingAccount: false, sharedLoginLockHeld: true
        ) != selected.id {
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
    }

    private struct RotatedLoginCandidate: Sendable {
        var profile: AccountProfile
        var snapshot: AccountCredentialVault.Entry
        var accountToRestore: String?
    }

    private func recoverRotatedLogin(
        _ record: AccountSwitchJournal.Record, state: AccountSwitchJournal.SharedState,
        in store: AccountProfilesStore, repairDepartingAccount: Bool,
        allowInteraction: Bool = true, sharedLoginLockHeld: Bool = false
    ) async throws -> String? {
        guard record.sourceID != nil, state.sourceID == record.sourceID, record.retryStateFingerprints != nil,
            let previous = store.profile(id: record.previousProfileID), previous.family == "claude",
            previous.identityKey == record.previousIdentity,
            let selected = store.profile(id: record.selectedProfileID), selected.family == "claude",
            selected.identityKey == record.selectedIdentity,
            let preferred = store.preferredProfileID(family: "claude"),
            ([previous.id, selected.id] + record.priorSelectionIDs).contains(preferred),
            let credential = state.credentials[0],
            let token = ClaudeAuthStore.parseCredentials(credential)?.claudeAiOauth?.accessToken?.nilIfEmpty
        else { return nil }

        let profiles = store.profiles
        let revision = store.authenticationRevision
        let observer = switcher
        let candidates = try await loadOffMainActor {
            var candidates: [RotatedLoginCandidate] = []
            if selected.identityKey.contains("|"), state.identities == [selected.identityKey],
                let snapshot = try observer.loadSnapshot(for: selected, allowInteraction: allowInteraction),
                observer.identity(of: snapshot, family: "claude")?.identityKey == selected.identityKey,
                AccountSwitchJournal.fingerprint(snapshot.credential) == record.selectedCredentialFingerprint,
                let account = snapshot.claudeOAuthAccount, try state.matchesAccountMetadata(account)
            {
                candidates.append(.init(profile: selected, snapshot: snapshot, accountToRestore: nil))
            }
            if repairDepartingAccount, previous.identityKey.contains("|"),
                let previousFingerprint = record.previousCredentialFingerprint,
                let snapshot = try observer.loadSnapshot(for: previous, allowInteraction: allowInteraction),
                let account = snapshot.claudeOAuthAccount,
                observer.identity(of: snapshot, family: "claude")?.identityKey == previous.identityKey,
                AccountSwitchJournal.fingerprint(snapshot.credential) == previousFingerprint
            {
                let alreadyRepaired = state.accounts == [account] && state.identities == [previous.identityKey]
                let staged = try state.matchesStagedAccount(of: record, with: snapshot.credential)
                if alreadyRepaired || staged {
                    candidates.append(.init(profile: previous, snapshot: snapshot, accountToRestore: account))
                }
            }
            return candidates
        }
        guard !candidates.isEmpty else { return nil }

        let profile = try await switcher.claudeProfile(for: token)
        let identity = try profile.accountIdentityKey()
        guard let candidate = candidates.first(where: { $0.profile.identityKey == identity }) else {
            AppLog.warn(.auth, "interrupted Claude switch token ownership did not match a recorded account")
            return nil
        }
        try Task.checkCancellation()
        let loginLock =
            sharedLoginLockHeld
            ? nil : try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        let observed: AccountSwitchJournal.SharedState
        let familyRevision: UInt64
        do {
            AccountCredentialMutationLock.acquire(family: "claude")
            defer { AccountCredentialMutationLock.release(family: "claude") }
            try AccountCredentialMutationLock.requireIdleClaudeRotation()
            guard !store.hasUnreadableRegistry, store.profiles == profiles, store.authenticationRevision == revision,
                store.preferredProfileID(family: "claude") == preferred, try store.pendingIdentityReplacement() == nil,
                try journal.load() == record,
                try switcher.loadSnapshot(for: candidate.profile, allowInteraction: allowInteraction)
                    == candidate.snapshot
            else { throw ClaudeAuthError.credentialsChanged }
            if let account = candidate.accountToRestore {
                try store.checkPendingPeerClaudeLoginChanges(home: switcher.homeDirectory, ownJournal: journal)
                observed = try switcher.repairSharedClaudeAccountMetadata(account, identity: identity, expecting: state)
            } else {
                observed = state
            }
            familyRevision = AccountCredentialMutationLock.revision(for: "claude")
        }
        try await finish(
            record, selecting: candidate.profile.id, observed: observed, in: store,
            allowInteraction: allowInteraction, sharedLoginLockHeld: true, familyRevision: familyRevision)
        return candidate.profile.id
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
        let profileID = try recoveredSelection(for: record, state: state, in: store)
        let loginLock = try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        let revision = AccountCredentialMutationLock.revision(for: "claude")
        guard try switcher.readClaudeSwitchState(legacyRecord: record.sourceID == nil) == state else {
            throw ClaudeAuthError.credentialsChanged
        }
        try commit(record, selecting: profileID, at: revision, in: store)
        return true
    }

    @discardableResult
    func recoverInterruptedSwitchAfterStartup(
        in store: AccountProfilesStore, allowInteraction: Bool = true
    ) async throws -> Bool {
        guard let record = try journal.load() else { return false }
        let state = try await readSwitchState(in: store, expecting: record, allowInteraction: allowInteraction)
        if selection(for: record, state: state, in: store) == nil,
            try await recoverRotatedLogin(
                record, state: state, in: store, repairDepartingAccount: false, allowInteraction: allowInteraction
            ) != nil
        {
            return true
        }
        let profileID = try recoveredSelection(for: record, state: state, in: store)
        try await finish(record, selecting: profileID, observed: state, in: store, allowInteraction: allowInteraction)
        return true
    }

    private func readSwitchState(
        in store: AccountProfilesStore,
        expecting record: AccountSwitchJournal.Record?,
        legacyRecord: Bool? = nil,
        allowInteraction: Bool = true,
        matching expectedState: AccountSwitchJournal.SharedState? = nil
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
        if let expectedState, state != expectedState { throw ClaudeAuthError.credentialsChanged }
        if let sourceID = record?.sourceID, state.sourceID != sourceID {
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
        return state
    }

    private func recoveredSelection(
        for record: AccountSwitchJournal.Record, state: AccountSwitchJournal.SharedState, in store: AccountProfilesStore
    ) throws -> String {
        guard let profileID = selection(for: record, state: state, in: store) else {
            AppLog.error(.auth, "account switch recovery found an unknown credential generation; preserving saved accounts")
            throw AccountCredentialSwitcher.Error.switchRecoveryRequired
        }
        return profileID
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
        sharedLoginLockHeld: Bool = false,
        familyRevision: UInt64? = nil
    ) async throws {
        let loginLock =
            sharedLoginLockHeld
            ? nil : try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: switcher.homeDirectory)
        defer { withExtendedLifetime(loginLock) {} }
        let revision = familyRevision ?? AccountCredentialMutationLock.revision(for: "claude")
        _ = try await readSwitchState(in: store, expecting: record, allowInteraction: allowInteraction, matching: state)
        try commit(record, selecting: profileID, at: revision, in: store)
    }

    private func commit(
        _ record: AccountSwitchJournal.Record, selecting profileID: String, at revision: UInt64,
        in store: AccountProfilesStore
    ) throws {
        let committed = try AccountCredentialMutationLock.withUnchangedRevision(revision, family: "claude") {
            try AccountCredentialMutationLock.requireIdleClaudeRotation()
            guard try journal.load() == record else { throw AccountIdentityReplacementError.pendingTransaction }
            try store.commitPreferredSelection(family: "claude", profileID: profileID)
            try journal.clear(record)
        }
        guard committed else { throw ClaudeAuthError.credentialsChanged }
    }
}
