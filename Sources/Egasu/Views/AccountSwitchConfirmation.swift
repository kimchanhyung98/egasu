import SwiftUI

extension View {
    func accountSwitchConfirmation(
        selection: Binding<AccountProfile?>,
        onError: @escaping (String?) -> Void,
        localStates: [String: AccountSignInProbe.State] = [:],
        allowsRecoveryRetry: Bool = false,
        onSignInRequired: ((AccountProfile, String) -> Void)? = nil
    ) -> some View {
        modifier(
            AccountSwitchConfirmation(
                selection: selection, onError: onError, localStates: localStates,
                allowsRecoveryRetry: allowsRecoveryRetry,
                onSignInRequired: onSignInRequired
            ))
    }
}

private struct AccountSwitchConfirmation: ViewModifier {
    @Environment(AppContainer.self) private var container
    @Environment(\.concealsAccountNames) private var concealsAccountNames
    @Binding var selection: AccountProfile?
    let onError: (String?) -> Void
    let localStates: [String: AccountSignInProbe.State]
    let allowsRecoveryRetry: Bool
    let onSignInRequired: ((AccountProfile, String) -> Void)?

    private var store: AccountProfilesStore { container.accountProfiles }

    private var isPresented: Binding<Bool> {
        Binding(
            get: { selection != nil },
            set: { if !$0 { selection = nil } }
        )
    }

    func body(content: Content) -> some View {
        content
            .confirmationDialog(
                L10n.accounts("Switch Account?"),
                isPresented: isPresented,
                titleVisibility: .visible,
                presenting: selection
            ) { profile in
                Button(L10n.accounts("Use %@: %@", profile.family.capitalized, displayName(for: profile))) {
                    switchTo(profile)
                }
                .disabled(container.accountSwitch.isSwitching || container.popover.signingInAgainAccountID != nil)
                Button(L10n.accounts("Cancel"), role: .cancel) {}
            } message: { profile in
                Text(
                    L10n.accounts(
                        "New %@ sessions using the default sign-in will use %@. Your settings, memory, and sessions stay in place. Custom terminal authentication settings still apply.",
                        profile.family, displayName(for: profile)
                    )
                )
            }
    }

    private func displayName(for profile: AccountProfile) -> String {
        AccountNamePrivacy.displayName(
            profile.label, email: container.accountLoginEmail(for: profile), conceals: concealsAccountNames
        )
    }

    private func switchTo(_ profile: AccountProfile) {
        guard !container.accountSwitch.isSwitching, container.popover.signingInAgainAccountID == nil else { return }
        let providerIDs = AccountSwitchCoordinator.providerIDs(to: profile, from: store.preferredProfile(family: profile.family))
        container.accountSwitch.start(
            profileID: profile.id,
            waitForRefreshes: { await container.waitForAccountSwitchWork(providerIDs: providerIDs) }
        ) {
            let switcher = AccountSelectionSwitcher()
            let status = container.accountStatus(for: profile, localState: localStates[profile.id])
            let isRecoveryRetry = try allowsRecoveryRetry && profile.family == "claude" && switcher.hasPendingSwitch()
            guard status.canSwitch || isRecoveryRetry else {
                let fallback = L10n.accounts("Sign in again before switching to this account.")
                if profile.family == "codex", let onSignInRequired {
                    let reason =
                        concealsAccountNames
                        ? container.signInReasonWithoutAccountDetails(for: profile) : status.message
                    onSignInRequired(profile, reason ?? fallback)
                } else {
                    onError(status.message ?? fallback)
                }
                let category: ErrorCategory = if case .sessionExpired = status { .authExpired } else { .notLoggedIn }
                AppDiagnostics.record(
                    .accountSwitch, result: .failure, category: category, providerID: profile.family,
                    localContext: "Account switch requires sign-in; account switch not applied")
                return
            }
            try await switcher.switchAuthentication(to: profile, in: store)
            let refreshes = container.refreshAccountCatalog()
            await container.refreshSharedRuntime(afterSwitchingTo: profile)
            for (providerID, refresh) in refreshes where providerIDs.contains(providerID) { await refresh.value }
            onError(nil)
            AppDiagnostics.record(.accountSwitch, result: .success, providerID: profile.family)
        } onFailure: { switchError in
            AppDiagnostics.failure(.accountSwitch, error: switchError, providerID: profile.family)
            onError(
                AccountNamePrivacy.switchErrorMessage(
                    switchError, name: profile.label, email: container.accountLoginEmail(for: profile),
                    conceals: concealsAccountNames
                ))
        }
    }
}
