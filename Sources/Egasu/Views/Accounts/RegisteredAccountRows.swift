import SwiftUI

/// Claude·Codex 등록 계정 관리 — 상태 배지 · 새 터미널 세션 계정 스위치 · 다시 로그인 · 전환 복구 · 삭제.
/// 상태 배지는 로컬 인증 준비 상태와 실제 조회 결과를 합침. 전환은 공유 홈 하나를 유지한 채 인증만 교체.
struct RegisteredAccountRows: View {
    let profile: AccountProfile
    let onRemoved: () -> Void

    @Environment(AppContainer.self) private var container
    @State private var signInState: AccountSignInProbe.State?
    @State private var probeRefreshID = 0
    @State private var isSigningIn = false
    @State private var isRequestingKeychainAccess = false
    @State private var signInTask: Task<Void, Never>?
    @State private var hasPendingSwitch = false
    @State private var pendingSelection: AccountProfile?
    @State private var recoverySelection: AccountProfile?
    @State private var actionError: String?
    @State private var isConfirmingRemoval = false

    private var store: AccountProfilesStore { container.accountProfiles }
    private var familyTitle: String { profile.family == "claude" ? "Claude" : "Codex" }
    private var isSelected: Bool { store.preferredProfileID(family: profile.family) == profile.id }
    private var isBusy: Bool { isSigningIn || isRequestingKeychainAccess || container.accountSwitch.isSwitching }

    private struct ProbeRequest: Equatable {
        let profile: AccountProfile
        let isSelected: Bool
        let authenticationRevision: Int
        let refreshID: Int
    }

    var body: some View {
        let status = container.accountStatus(for: profile, localState: signInState)
        VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
            if hasPendingSwitch {
                rowButton(L10n.accounts("Use %@: %@", familyTitle, profile.label)) { recoverySelection = profile }
                    .disabled(isBusy)
                    .cardSurface()
                    // 확인창은 뷰마다 하나 — 복구 전환은 이 행에 붙임.
                    .accountSwitchConfirmation(
                        selection: $recoverySelection, error: $actionError, allowsRecoveryRetry: true)
            }
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(L10n.accounts("Status"))
                    Spacer(minLength: 8)
                    AccountStatusBadge(state: status)
                }
                .accountActionRowPadding()
                HStack(spacing: 8) {
                    Text(L10n.accounts("Use This Account"))
                    Spacer(minLength: 8)
                    Toggle(L10n.accounts("Use This Account"), isOn: selectionBinding)
                        .labelsHidden()
                        .settingsSwitchStyle()
                        .disabled(
                            Self.blocksSelection(
                                status: status, isBusy: isBusy, hasUnreadableRegistry: store.hasUnreadableRegistry
                            ))
                }
                .accountActionRowPadding()
                if Self.offersKeychainApproval(signInState) {
                    rowButton(L10n.accounts("Allow Keychain Access…"), action: requestKeychainAccess)
                        .disabled(isBusy)
                } else {
                    rowButton(L10n.accounts(isSigningIn ? "Signing In…" : "Sign In Again…"), action: signInAgain)
                        .disabled(isBusy)
                }
                rowButton(L10n.accounts("Remove Account…"), role: .destructive) { isConfirmingRemoval = true }
                    .disabled(isBusy)
                    .alert(L10n.accounts("Remove %@?", profile.label), isPresented: $isConfirmingRemoval) {
                        Button(L10n.accounts("Remove Account"), role: .destructive, action: removeAccount)
                            .disabled(isBusy)
                        Button(L10n.accounts("Cancel"), role: .cancel) {}
                    } message: {
                        Text(
                            L10n.accounts(
                                "egasu deletes its saved Keychain authentication and sign-in workspace for this account. Your Claude and Codex settings, sessions, and the current terminal login stay in place."
                            ))
                    }
            }
            .cardSurface()
            .accountSwitchConfirmation(selection: $pendingSelection, error: $actionError, localStates: localStates)
            if let message = actionError ?? status.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .padding(.horizontal, 12)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: probeRequest) { await refreshSignInState(probeRequest) }
        .task { refreshSwitchRecovery() }
        .onChange(of: container.accountSwitch.isSwitching) { _, isSwitching in
            if !isSwitching { refreshSwitchRecovery() }
        }
        .onChange(of: container.dataStore.refreshingProviderIDs) { previous, current in
            if Self.needsSignInRecheck(
                state: signInState, finishedCardIDs: previous.subtracting(current), profileID: profile.id,
                profileIDForCard: container.accountProfileID(for:)
            ) {
                probeRefreshID &+= 1
            }
        }
        .onDisappear { signInTask?.cancel() }
    }

    private var localStates: [String: AccountSignInProbe.State] {
        signInState.map { [profile.id: $0] } ?? [:]
    }

    private var probeRequest: ProbeRequest {
        ProbeRequest(
            profile: profile, isSelected: isSelected,
            authenticationRevision: store.authenticationRevision, refreshID: probeRefreshID
        )
    }

    private func rowButton(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) -> some View {
        Button(role: role, action: action) {
            Text(title)
                .foregroundStyle(
                    role == .destructive ? AnyShapeStyle(Color(nsColor: .systemRed)) : AnyShapeStyle(.tint)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .accountActionRowPadding()
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 스위치는 단일 선택으로 동작 — 켜면 전환 확인, 선택된 계정 끄기는 무시하여 선택 계정 유지.
    private var selectionBinding: Binding<Bool> {
        Binding(
            get: { isSelected },
            set: { isOn in
                guard isOn, !isSelected, !container.accountSwitch.isSwitching else { return }
                pendingSelection = profile
            }
        )
    }

    private func refreshSignInState(_ request: ProbeRequest) async {
        let profile = request.profile
        let isSelected = request.isSelected
        let state = await loadOffMainActor { AccountSignInProbe().state(for: profile, isSelected: isSelected) }
        guard !Task.isCancelled, request == probeRequest else { return }
        signInState = state
    }

    /// 저장 로그인을 승인 창과 함께 다시 읽음 — 승인되면 이 계정의 카드도 새로 조회해 대시보드 경고 해제.
    private func requestKeychainAccess() {
        guard !isBusy else { return }
        isRequestingKeychainAccess = true
        let request = probeRequest
        Task {
            let state = await loadOffMainActor {
                AccountSignInProbe().state(for: request.profile, isSelected: request.isSelected, allowInteraction: true)
            }
            isRequestingKeychainAccess = false
            // 승인 창이 떠 있는 동안 재확인 요청이 바뀌면 상태는 새 확인에 맡김 — 승인 자체는 유효해 카드 조회는 진행.
            if request == probeRequest { signInState = state }
            guard state.isReady else { return }
            for cardID in container.dataStore.knownProviderIDs
            where container.accountProfileID(for: cardID) == request.profile.id
                && container.enablement.isEnabled(cardID)
            {
                Task { _ = await container.refresh(providerID: cardID, force: true) }
            }
        }
    }

    /// 저장 로그인을 읽지 못한 경우에만 다시 로그인 대신 Keychain 승인 요청.
    static func offersKeychainApproval(_ state: AccountSignInProbe.State?) -> Bool {
        if case .readFailed? = state { true } else { false }
    }

    private func refreshSwitchRecovery() {
        guard profile.family == "claude" else { return }
        do {
            hasPendingSwitch = try AccountSelectionSwitcher().hasPendingSwitch()
        } catch {
            AppDiagnostics.failure(.accountSwitch, error: error, providerID: profile.family)
            actionError = UserFacingErrors.message(error)
        }
    }

    private func catalogDidChange() {
        container.refreshAccountCatalog()
        probeRefreshID &+= 1
    }

    /// 공식 재로그인 결과로 이 계정의 인증 교체 — Codex는 시도별 독립 작업 공간, 선택된 계정이면 공유 홈도 갱신.
    private func signInAgain() {
        guard !container.accountSwitch.isSwitching else { return }
        isSigningIn = true
        actionError = nil
        signInTask = Task {
            defer {
                isSigningIn = false
                refreshSwitchRecovery()
            }
            do {
                if profile.family == "claude",
                    try await AccountSelectionSwitcher().recoverInterruptedSwitchAfterStartup(in: store)
                {
                    catalogDidChange()
                }
                try Task.checkCancellation()
                let workspace = AccountSignInWorkspace()
                let signIn = try workspace.prepareReauthentication(family: profile.family, profileID: profile.id)
                defer {
                    if let attemptID = signIn.attemptID {
                        do {
                            try workspace.remove(family: profile.family, profileID: profile.id, attemptID: attemptID)
                        } catch {
                            AppDiagnostics.failure(
                                .accountSignIn, error: error, providerID: profile.family,
                                localContext: "Sign-in workspace cleanup failed")
                            actionError = UserFacingErrors.message(error)
                        }
                    }
                }
                AppLog.info(.auth, "account re-sign-in started \(profile.family) profile \(profile.id.prefix(8))")
                let code = try await AccountSignInLauncher().runLogin(
                    family: profile.family, home: signIn.directory.path)
                try Task.checkCancellation()
                guard code == 0 else {
                    actionError = L10n.accounts(
                        "The %@ sign-in did not complete. The saved account is unchanged.", familyTitle)
                    AppDiagnostics.record(
                        .accountSignIn, result: .failure, category: .subprocess, providerID: profile.family,
                        localContext: "Sign-in process exited with status \(code); saved account unchanged")
                    return
                }
                try AccountCredentialImporter().completeReSignIn(
                    profileID: profile.id,
                    in: store,
                    isActive: isSelected,
                    signInAttemptID: signIn.attemptID
                )
                AppDiagnostics.record(.accountSignIn, result: .success, providerID: profile.family)
                catalogDidChange()
            } catch is CancellationError {
                AppDiagnostics.record(.accountSignIn, result: .cancelled, providerID: profile.family)
            } catch {
                AppDiagnostics.failure(.accountSignIn, error: error, providerID: profile.family)
                actionError = UserFacingErrors.message(error)
            }
        }
    }

    /// 다른 계정이 있는 동안 새 터미널 세션 계정은 삭제 불가 — 패밀리가 쓸 계정 없이 남지 않게.
    static func blocksRemoval(of profile: AccountProfile, isSelected: Bool, familyCount: Int) -> Bool {
        isSelected && familyCount > 1
    }

    /// 전환 스위치 비활성 — 전환·재로그인 중, 계정 목록을 읽지 못함, 다시 로그인이 필요한 계정.
    static func blocksSelection(status: AccountStatus, isBusy: Bool, hasUnreadableRegistry: Bool) -> Bool {
        isBusy || hasUnreadableRegistry || !status.canSwitch
    }

    /// 이 계정의 새로 고침이 끝났는데 저장 로그인을 아직 확인하지 못했으면 재확인 — Keychain 승인 뒤 화면을 다시 열지 않아도 상태 갱신.
    static func needsSignInRecheck(
        state: AccountSignInProbe.State?, finishedCardIDs: Set<String>, profileID: String,
        profileIDForCard: (String) -> String?
    ) -> Bool {
        switch state {
        case nil, .readFailed?: finishedCardIDs.contains { profileIDForCard($0) == profileID }
        case .ready?, .needsSignIn?: false
        }
    }

    /// 제거 순서 고정: 앱 소유 작업 공간 → Keychain 사본 → 등록 해제. 실패하면 등록 유지(재시도 가능), 공유 홈은 그대로.
    private func removeAccount() {
        guard !container.accountSwitch.isSwitching else { return }
        // 다른 계정이 있는 동안 선택된 계정은 제거 불가 — 먼저 전환 필요.
        if Self.blocksRemoval(
            of: profile, isSelected: isSelected, familyCount: store.profiles(family: profile.family).count)
        {
            actionError = UserFacingErrors.message(AccountProfileError.removeSelectedProfile)
            return
        }
        do {
            try AccountCredentialImporter().removeAccount(profile, from: store)
            AppDiagnostics.record(.accountRemove, result: .success, providerID: profile.family)
        } catch {
            AppDiagnostics.failure(.accountRemove, error: error, providerID: profile.family)
            actionError = UserFacingErrors.message(error)
            return
        }
        container.refreshAccountCatalog()
        onRemoved()
    }
}
