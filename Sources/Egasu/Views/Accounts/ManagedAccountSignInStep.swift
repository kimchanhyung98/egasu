import SwiftUI

/// Claude·Codex 계정 추가 — Add Account 클릭 시 로그인 또는 기존 인증 가져오기 시작.
/// 첫 계정에 기본 로그인이 있으면 인증 가져오기, 그 외에는 공식 CLI 로그인 실행.
/// 첫 계정은 공유 홈, 추가 계정은 앱 소유 로그인 작업 공간 사용 — 브라우저는 CLI에서 열기.
/// 추가 계정은 등록만 수행 — 새 터미널 세션의 계정 선택 유지.
struct ManagedAccountSignInStep: View {
    let family: String
    let icon: IconSource
    let cancel: () -> Void
    let onCompleted: () -> Void

    @Environment(AppContainer.self) private var container
    @State private var phase: Phase = .idle
    @State private var signInTask: Task<Void, Never>?

    private enum Phase: Equatable {
        case idle
        case signingIn
        case failed(String, allowsSignInAgain: Bool = false)
    }

    private var store: AccountProfilesStore { container.accountProfiles }
    private var familyTitle: String { family == "claude" ? "Claude" : "Codex" }
    private var isFirstAccount: Bool { store.profiles(family: family).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SheetHeader(
                icon: icon,
                title: L10n.accounts("Add %@", familyTitle),
                message: isFirstAccount
                    ? L10n.accounts(
                        "If you're already signed in, egasu imports that account without another login. Otherwise the official %@ sign-in opens in your browser.",
                        familyTitle)
                    : L10n.accounts(
                        "The official %@ sign-in opens in your browser. Your current account and terminal sessions stay unchanged.",
                        familyTitle)
            )
            SheetButtons(
                secondary: SheetAction(title: L10n.accounts("Cancel"), shortcut: .cancelAction) {
                    signInTask?.cancel()
                    cancel()
                },
                primary: SheetAction(
                    title: L10n.accounts(primaryTitle),
                    isDisabled: phase == .signingIn || isBlocked,
                    action: { addAccount() }
                )
            )
            if case .failed(_, true) = phase, family == "claude", isFirstAccount {
                Button(L10n.accounts("Sign In Again")) { addAccount(signInAgain: true) }
                    .glassButtonStyle()
                    .controlSize(.small)
                    .disabled(isBlocked)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.horizontal, 20)
            }
            status
                .padding(.bottom, 20)
        }
        .onDisappear { signInTask?.cancel() }
    }

    private var isBlocked: Bool {
        Self.blocksAdding(
            isSwitching: container.accountSwitch.isSwitching, hasUnreadableRegistry: store.hasUnreadableRegistry)
    }

    /// 계정 전환 중이거나 목록을 읽지 못하면 추가 차단 — 공유 홈 로그인 변경 후 등록 실패 방지.
    static func blocksAdding(isSwitching: Bool, hasUnreadableRegistry: Bool) -> Bool {
        isSwitching || hasUnreadableRegistry
    }

    private var primaryTitle: String {
        switch phase {
        case .idle: "Add Account"
        case .signingIn: "Signing In…"
        case .failed: "Try Again"
        }
    }

    @ViewBuilder
    private var status: some View {
        switch phase {
        case .idle:
            if store.hasUnreadableRegistry {
                SheetStatus(text: UserFacingErrors.message(AccountProfileError.registryUnreadable), isError: true)
            } else {
                SheetStatus(text: nil)
            }
        case .signingIn:
            SheetStatus(text: L10n.accounts("Waiting for the %@ sign-in to finish…", familyTitle), isWorking: true)
        case .failed(let message, _):
            SheetStatus(text: message, isError: true)
        }
    }

    private func addAccount(signInAgain: Bool = false) {
        guard !isBlocked else { return }
        phase = .signingIn
        let family = family
        let importer = AccountCredentialImporter()

        // 첫 계정 → Shared Runtime Home으로 공식 로그인; 추가 계정 → 새 Sign-In Workspace 범위의 공식 로그인.
        let profileID = isFirstAccount ? nil : UUID().uuidString
        signInTask = Task {
            var importingDefault = false
            do {
                try Task.checkCancellation()
                if signInAgain {
                    guard !store.hasUnreadableRegistry else { throw AccountProfileError.registryUnreadable }
                    guard try store.pendingIdentityReplacement() == nil else {
                        throw AccountIdentityReplacementError.pendingTransaction
                    }
                    guard try !AccountSelectionSwitcher().hasPendingSwitch() else {
                        throw AccountCredentialSwitcher.Error.switchRecoveryRequired
                    }
                    guard family == "claude", profileID == nil, store.profiles(family: family).isEmpty else {
                        throw AccountCredentialImporter.ImportError.verificationFailed(family: family)
                    }
                }
                // 명시적 재로그인 외에는 현재 기본 로그인부터 검증해 가져오기.
                importingDefault = profileID == nil && !signInAgain
                if importingDefault,
                    let profile = try await importer.importDefaultAccount(family: family, into: store)
                {
                    AppLog.info(
                        .config, "accounts: imported the signed-in default \(family) account (\(profile.id.prefix(8))…)"
                    )
                    finish()
                    return
                }
                importingDefault = false
                let workspace = AccountSignInWorkspace()
                let home: String?
                if let profileID {
                    home = try workspace.prepare(family: family, profileID: profileID).path
                } else {
                    home = nil
                }
                let code = try await AccountSignInLauncher().runLogin(family: family, home: home)
                try Task.checkCancellation()
                guard code == 0 else {
                    AppDiagnostics.record(
                        .accountAdd, result: .failure, category: .subprocess, providerID: family,
                        localContext: "Sign-in process exited with status \(code); no account added")
                    if let profileID { try? importer.removeSignInWorkspace(family: family, profileID: profileID) }
                    phase = .failed(
                        L10n.accounts("The %@ sign-in did not complete. Nothing was added — try again.", familyTitle))
                    return
                }
                if let profileID {
                    guard let credential = try importer.readWorkspaceCredential(family: family, profileID: profileID)
                    else {
                        AppDiagnostics.record(.accountAdd, result: .failure, category: .authInvalid, providerID: family)
                        try? importer.removeSignInWorkspace(family: family, profileID: profileID)
                        phase = .failed(
                            L10n.accounts(
                                "The %@ sign-in finished without a usable credential. Nothing was added.", familyTitle))
                        return
                    }
                    // 새 profile은 등록만 하고 선택하지 않음 — add가 새 터미널의 사용 계정을 조용히 바꾸지 않게 보장.
                    _ = try importer.register(
                        credential,
                        family: family,
                        label: credential.label ?? "Account",
                        id: profileID,
                        into: store
                    )
                } else {
                    guard try await importer.importDefaultAccount(family: family, into: store) != nil else {
                        AppDiagnostics.record(.accountAdd, result: .failure, category: .authInvalid, providerID: family)
                        phase = .failed(
                            L10n.accounts(
                                "The %@ sign-in finished without a usable credential. Nothing was added.", familyTitle))
                        return
                    }
                }
                finish()
            } catch is CancellationError {
                AppDiagnostics.record(.accountAdd, result: .cancelled, providerID: family)
                if let profileID {
                    try? importer.removeSignInWorkspace(family: family, profileID: profileID)
                }
            } catch {
                if let profileID {
                    try? importer.removeSignInWorkspace(family: family, profileID: profileID)
                }
                let allowsSignInAgain =
                    importingDefault && family == "claude"
                    && !store.hasUnreadableRegistry && store.profiles(family: family).isEmpty
                    && (error is ClaudeAuthError || error is ClaudeUsageError || error is URLError
                        || error is DecodingError || error is AccountCredentialImporter.ImportError)
                fail(error, allowsSignInAgain: allowsSignInAgain)
            }
        }
    }

    private func finish() {
        AppDiagnostics.record(.accountAdd, result: .success, providerID: family)
        onCompleted()
    }

    private func fail(_ error: any Error, allowsSignInAgain: Bool = false) {
        AppDiagnostics.failure(.accountAdd, error: error, providerID: family)
        phase = .failed(UserFacingErrors.message(error), allowsSignInAgain: allowsSignInAgain)
    }
}
