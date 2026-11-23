import Foundation

extension AppContainer {
    func accountStatus(for profile: AccountProfile, localState: AccountSignInProbe.State?) -> AccountStatus {
        dataStore.accountStatus(for: accountStatusCardID(for: profile), localState: localState)
    }

    func signInReasonWithoutAccountDetails(for profile: AccountProfile) -> String? {
        guard let cardID = accountStatusCardID(for: profile) else { return nil }
        return dataStore.refreshResults[cardID]?.failure?.presentation?.staticText
    }

    private func accountStatusCardID(for profile: AccountProfile) -> String? {
        let mapping = Dictionary(
            uniqueKeysWithValues: dataStore.knownProviderIDs.compactMap { cardID in
                accountProfileID(for: cardID).map { (cardID, $0) }
            })
        return AccountUsageCardPlanner.statusCardID(for: profile, profileIDsByCard: mapping)
    }

    /// Keychain 접근 실패는 해당 카드만 수동 갱신하고, 나머지 문제는 계정 상세로 연결.
    func fixAccount(_ cardID: String, openAccount: (String) -> Void) {
        guard dataStore.needsKeychainApproval(cardID) else { return openAccount(cardID) }
        guard !dataStore.refreshingProviderIDs.contains(cardID) else { return }
        Task { await refresh(providerID: cardID, force: true) }
    }

    /// 동일 provider 신원으로 재로그인한 경우도 새 credential 기준으로 해당 카드만 재확인.
    @discardableResult
    func refreshReauthenticatedAccounts(alreadyScheduledCardIDs: Set<String>) -> [String: Task<Void, Never>] {
        let revisions = accountProfiles.authenticationRevisionsByProfileID
        let changedIDs = Set(revisions.compactMap { profileID, revision in
            observedAuthenticationRevisions[profileID] != revision ? profileID : nil
        })
        observedAuthenticationRevisions = revisions
        var refreshes: [String: Task<Void, Never>] = [:]
        for cardID in dataStore.knownProviderIDs {
            guard let profileID = accountProfileID(for: cardID), changedIDs.contains(profileID) else { continue }
            dataStore.invalidateAuthentication(for: cardID)
            if enablement.isEnabled(cardID), !alreadyScheduledCardIDs.contains(cardID) {
                refreshes[cardID] = accountSwitch.startRefresh(providerID: cardID) {
                    await self.dataStore.refreshAfterAccountSelection(providerID: cardID)
                }
            }
        }
        return refreshes
    }

    static func externalClaudeReconciliationFailure(for error: Error, family: String = "claude") -> ProviderRefreshFailure {
        let category = ErrorCategory.classify(error)
        if family == "codex" || error is CodexAuthError {
            let presentation = UserFacingErrors.presentation(error)
            return ProviderRefreshFailure(message: presentation.key, category: category, presentation: presentation)
        }
        let fallback =
            "egasu couldn't update the selected Claude sign-in. The saved account was left unchanged. Check the app log and try again."
        let presentation: LocalizedMessage
        if let error = error as? ClaudeAuthError, error == .credentialsChanged || error == .rotationInProgress {
            presentation = UserFacingErrors.presentation(error)
        } else if let error = error as? AccountCredentialSwitcher.Error,
            [.switchRecoveryRequired, .selectionSaveFailed, .conflictingClaudeAuthentication].contains(error)
        {
            presentation = UserFacingErrors.presentation(error)
        } else if case KeychainError.readFailed = error {
            presentation = .init(
                "Couldn't read the Claude login from Keychain. Refresh Claude manually and allow access if macOS asks.")
        } else {
            presentation = .init(fallback)
        }
        return ProviderRefreshFailure(message: presentation.key, category: category, presentation: presentation)
    }

    static func applyExternalClaudeReconciliationError(
        _ failure: ProviderRefreshFailure?, to dataStore: WidgetDataStore,
        accountSwitch: AccountSwitchCoordinator, startedAt generation: Int, family: String = "claude"
    ) {
        guard !accountSwitch.isSwitching, accountSwitch.generation == generation else { return }
        dataStore.setAccountReconciliationFailure(failure, for: family)
    }
}
