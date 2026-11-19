import SwiftUI

/// Accounts 화면 — 계정 목록과 계정 상세를 이동 방향에 맞춰 수평 전환.
/// 라우트는 `PopoverState.accountDetailID` — 패널 닫힘 초기화·Esc 처리와 같은 상태 공유.
struct AccountsView: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var reconciliationError: String?
    @State private var legacyShellSetup = LegacyClaudeShellSetup()

    private var showsClaudeShellNotice: Bool {
        guard let id = popover.accountDetailID else { return true }
        return ProviderAccountID.family(of: id) == "claude"
    }

    private struct ReconciliationRequest: Equatable {
        let authenticationRevision: Int
        let isSwitching: Bool
    }

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if let reconciliationError { ProblemCard(message: reconciliationError) }
                if showsClaudeShellNotice { LegacyClaudeShellNotices(setup: legacyShellSetup) }
                content
            }
            .padding(.horizontal, PanelMetrics.margin)
            .padding(.top, 7)
            .padding(.bottom, popover.accountDetailID == nil ? 0 : PanelMetrics.margin)
            .frame(maxWidth: .infinity)
        }
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        .sheet(isPresented: Bindable(popover).isAddingAccount) {
            AddAccountSheet()
        }
        .onAppear {
            // 다른 창의 설정 변경을 반영하도록 화면을 열 때마다 등록 계정 다시 읽기.
            container.accountProfiles.reloadFromDefaults()
            container.refreshAccountCatalog()
        }
        .task(id: showsClaudeShellNotice) {
            guard showsClaudeShellNotice else { return }
            let setup = await LegacyClaudeShellSetup.check()
            guard !Task.isCancelled else { return }
            legacyShellSetup = setup
        }
        .task(
            id: ReconciliationRequest(
                authenticationRevision: container.accountProfiles.authenticationRevision,
                isSwitching: container.accountSwitch.isSwitching
            )
        ) {
            guard !container.accountSwitch.isSwitching else { return }
            let message = await container.reconcileExternalClaudeAuthenticationAndRefreshCatalog()
            guard !Task.isCancelled else { return }
            reconciliationError = message
        }
    }

    @ViewBuilder
    private var content: some View {
        if let id = popover.accountDetailID {
            AccountDetailView(
                accountID: id,
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                rowFrames: rowFrames
            )
            .transition(.move(edge: .trailing))
        } else {
            AccountListView(
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                rowFrames: rowFrames
            )
            .transition(.move(edge: .leading))
        }
    }
}

struct LegacyClaudeShellNotices: View {
    let setup: LegacyClaudeShellSetup

    var body: some View {
        if !setup.found.isEmpty {
            ProblemCard(
                message: L10n.accounts(
                    "An old OpenUsage shell function can make Claude use a different login. Remove the “OpenUsage claude account switching” block from %@ and open a new terminal window.",
                    setup.found.joined(separator: ", ")
                ))
        }
        if !setup.unreadable.isEmpty {
            ProblemCard(
                message: L10n.accounts(
                    "Couldn’t check %@ for the old OpenUsage Claude shell function.",
                    setup.unreadable.joined(separator: ", ")
                ))
        }
    }
}
