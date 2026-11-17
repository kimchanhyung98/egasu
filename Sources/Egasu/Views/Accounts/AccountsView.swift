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

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: PanelMetrics.sectionSpacing) {
                if let reconciliationError { ProblemCard(message: reconciliationError) }
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
        .task {
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
