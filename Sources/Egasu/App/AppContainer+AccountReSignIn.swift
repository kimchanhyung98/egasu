import Foundation

enum AccountReSignInIssue {
    case failed(any Error)
    case processExited(family: String)
    case savedWithCleanupFailure

    var allowsRetry: Bool {
        switch self {
        case .failed(let error): (error as? AccountCredentialImporter.ImportError) != .reSignInIdentityUnavailable
        case .processExited: true
        case .savedWithCleanupFailure: false
        }
    }

    func message(concealsAccountNames: Bool = false) -> String {
        switch self {
        case .failed(let error):
            let presentation = UserFacingErrors.presentation(error)
            if concealsAccountNames {
                return presentation.staticText ?? L10n.accounts("Check this account's sign-in status in Accounts.")
            }
            return presentation.localized
        case .processExited(let family):
            return L10n.accounts("The %@ sign-in did not complete. The saved account is unchanged.", family.capitalized)
        case .savedWithCleanupFailure:
            return L10n.accounts("Sign-in saved. egasu couldn't remove the temporary sign-in folder.")
        }
    }
}

extension AppContainer {
    /// 브라우저에서 돌아올 때까지 대상 프로필을 유지하고, 현재 선택에 따라 공유 인증 갱신 여부를 결정.
    func startReSignIn(
        for profile: AccountProfile, expectedIdentityKey: String? = nil,
        completion: @escaping ([AccountReSignInIssue]) -> Void
    ) -> Task<Void, Never>? {
        guard !accountSwitch.isSwitching, !accountProfiles.hasUnreadableRegistry else { return nil }
        return popover.startReSignIn(for: profile.id) { [self] in
            var issues: [AccountReSignInIssue] = []
            var saved = false
            defer {
                if !Task.isCancelled, saved || !issues.isEmpty { completion(issues) }
            }
            do {
                if profile.family == "claude",
                    try await AccountSelectionSwitcher().recoverInterruptedSwitchAfterStartup(in: accountProfiles)
                {
                    refreshAccountCatalog()
                }
                try Task.checkCancellation()
                let workspace = AccountSignInWorkspace()
                let signIn = try workspace.prepareReauthentication(family: profile.family, profileID: profile.id)
                defer {
                    let cleanupError = Self.finishSignInAttempt(family: profile.family, saved: saved) {
                        if let attemptID = signIn.attemptID {
                            try workspace.remove(family: profile.family, profileID: profile.id, attemptID: attemptID)
                        }
                    }
                    if let cleanupError { issues.append(cleanupError) }
                }
                AppLog.info(.auth, "account re-sign-in started \(profile.family)")
                let code = try await AccountSignInLauncher().runLogin(
                    family: profile.family, home: signIn.directory.path)
                guard !Task.isCancelled, popover.popoverShown else { throw CancellationError() }
                guard code == 0 else {
                    issues.append(.processExited(family: profile.family))
                    AppDiagnostics.record(
                        .accountSignIn, result: .failure, category: .subprocess, providerID: profile.family,
                        localContext: "Sign-in process exited with status \(code); saved account unchanged")
                    return
                }
                try AccountCredentialImporter().completeReSignIn(
                    profileID: profile.id,
                    in: accountProfiles,
                    isActive: accountProfiles.preferredProfileID(family: profile.family) == profile.id,
                    signInAttemptID: signIn.attemptID, expectedIdentityKey: expectedIdentityKey
                )
                saved = true
                refreshAccountCatalog()
            } catch is CancellationError {
                AppDiagnostics.record(.accountSignIn, result: .cancelled, providerID: profile.family)
            } catch {
                AppDiagnostics.failure(.accountSignIn, error: error, providerID: profile.family)
                issues.insert(.failed(error), at: 0)
            }
        }
    }

    /// 재로그인 결과는 시도 폴더 정리 후 확정. 이미 실패한 로그인의 정리 오류는 복구 작업으로 기록.
    static func finishSignInAttempt(family: String, saved: Bool, cleanup: () throws -> Void) -> AccountReSignInIssue? {
        do {
            try cleanup()
            if saved { AppDiagnostics.record(.accountSignIn, result: .success, providerID: family) }
            return nil
        } catch {
            if saved {
                AppDiagnostics.record(
                    .accountSignIn, result: .degraded, providerID: family, error: error,
                    localContext: "remove saved sign-in attempt workspace")
                return .savedWithCleanupFailure
            }
            AppDiagnostics.failure(
                .accountRollback, error: error, providerID: family, localContext: "remove sign-in attempt workspace")
            return .failed(error)
        }
    }
}
