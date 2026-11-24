import SwiftUI

/// 대시보드 계정 섹션별 목록 — 손잡이 드래그로 순서 변경, 행·화살표 클릭으로 상세 열기.
/// 같은 프로바이더 계정끼리는 등록 계정 순서, 다른 프로바이더 사이는 양쪽 계정이 1개일 때만 이동.
struct AccountListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    let rowFrames: [String: CGRect]

    @State private var activeAccountID: String?

    var body: some View {
        let accounts = container.accountListAccounts()
        VStack(alignment: .leading, spacing: 0) {
            if accounts.isEmpty {
                ContentUnavailableView {
                    Label(L10n.accounts("No Accounts"), systemImage: "person.crop.circle")
                }
            } else {
                VStack(spacing: 0) {
                    ForEach(accounts) { account in
                        row(account, in: accounts)
                    }
                }
                .cardSurface()
            }
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(Theme.notice)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .animation(Motion.spring, value: accounts.map(\.id))
    }

    /// 등록 계정 목록·순서를 읽지 못했을 때 — 저장값은 그대로 두고 알림.
    private var notice: String? {
        if container.accountProfiles.hasUnreadableRegistry {
            return UserFacingErrors.message(AccountProfileError.registryUnreadable)
        }
        return container.dataStore.accountReconciliationNotice ?? container.accountCardPresentation.errorMessage
    }

    @ViewBuilder
    private func row(_ account: DashboardAccount, in accounts: [DashboardAccount]) -> some View {
        let siblings = Self.familySiblings(of: account.id, among: accounts.map(\.id))
        let row = AccountListRow(
            account: account,
            isInUse: account.isInUse,
            grip: { ReorderGrip().highPriorityGesture(dragGesture(for: account, in: accounts)) },
            onOpen: { withAnimation(Motion.navigation) { popover.accountDetailID = account.id } }
        )
        .opacity(activeAccountID == account.id ? 0 : 1)
        .reorderFrame(id: account.id, in: .named(reorderSpaceName))
        if siblings.count > 1, let position = siblings.firstIndex(of: account.id) {
            row
                .accessibilityElement(children: .contain)
                .accessibilityLabel(account.fullName)
                .accessibilityValue(L10n.accounts("Position %lld of %lld", position + 1, siblings.count))
                .accessibilityActions {
                    if position > 0 {
                        Button(L10n.accounts("Move Up")) { move(account, onto: siblings[position - 1], in: accounts) }
                    }
                    if position < siblings.count - 1 {
                        Button(L10n.accounts("Move Down")) { move(account, onto: siblings[position + 1], in: accounts) }
                    }
                }
        } else {
            row
        }
    }

    /// VoiceOver 순서 변경 — 같은 프로바이더 계정 사이에서 한 칸 이동 후 새 위치 안내.
    private func move(_ account: DashboardAccount, onto target: String, in accounts: [DashboardAccount]) {
        guard reorder(account.id, onto: target, in: accounts) else { return }
        let siblings = Self.familySiblings(of: account.id, among: container.accountListAccounts().map(\.id))
        guard let position = siblings.firstIndex(of: account.id) else { return }
        AccessibilityNotification.Announcement(
            L10n.accounts("Moved %@ to position %lld of %lld.", account.fullName, position + 1, siblings.count)
        ).post()
    }

    /// 같은 프로바이더 계정 카드 ID — 목록 순서 그대로.
    static func familySiblings(of cardID: String, among ids: [String]) -> [String] {
        let family = AppContainer.dashboardFamilyID(for: cardID)
        return ids.filter { AppContainer.dashboardFamilyID(for: $0) == family }
    }

    private func dragGesture(for account: DashboardAccount, in accounts: [DashboardAccount]) -> some Gesture {
        reorderDragGesture(
            id: account.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeAccountID,
            lift: $reorderLift,
            makeLift: { value in
                let preview = AccountListRow(account: account, isInUse: account.isInUse, grip: { ReorderGrip() })
                    .liftedRowSurface()
                return ReorderLift.make(
                    id: account.id, payload: .view(AnyView(preview)), value: value, frames: rowFrames)
            },
            orderedIDs: { accounts.map(\.id) },
            reorder: { reorder(account.id, onto: $0, in: accounts) }
        )
    }

    private func reorder(_ dragged: String, onto target: String, in accounts: [DashboardAccount]) -> Bool {
        let family = AppContainer.dashboardFamilyID(for: dragged)
        guard family != AppContainer.dashboardFamilyID(for: target) else {
            return reorderAccount(dragged, onto: target, family: family)
        }
        guard Self.allowsProviderMove(dragged, onto: target, among: accounts.map(\.id)) else { return false }
        return layout.reorderProvider(dragged: dragged, target: target)
    }

    /// 다른 프로바이더 사이 이동은 양쪽 모두 계정이 1개일 때만 허용 — 여러 계정 묶음의 분리 방지.
    static func allowsProviderMove(_ dragged: String, onto target: String, among ids: [String]) -> Bool {
        let count = { (cardID: String) in
            ids.count { AppContainer.dashboardFamilyID(for: $0) == AppContainer.dashboardFamilyID(for: cardID) }
        }
        return count(dragged) == 1 && count(target) == 1
    }

    private func reorderAccount(_ dragged: String, onto target: String, family: String) -> Bool {
        guard let draggedProfile = container.accountProfileID(for: dragged),
            let targetProfile = container.accountProfileID(for: target)
        else { return false }
        return container.accountCardPresentation.reorder(
            dragged: draggedProfile, target: targetProfile, family: family,
            profiles: container.accountProfiles.profiles(family: family)
        )
    }
}

/// 계정 목록 행 — 손잡이·아이콘·프로바이더 이름·흐림 대상 계정명·상세 화살표.
struct AccountListRow<Grip: View>: View {
    let account: DashboardAccount
    var isInUse = false
    @ViewBuilder var grip: Grip
    var onOpen: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            grip

            HStack(spacing: 8) {
                ProviderIcon(source: account.provider.icon, inset: 0.04)
                    .frame(width: 18, height: 18)
                Text(account.providerName)
                    .foregroundStyle(.primary)
                    .layoutPriority(1)
                if let name = account.name {
                    Text(name)
                        .foregroundStyle(isInUse ? Theme.positive : AnyShapeStyle(.secondary))
                        .concealingAccountName()
                }
                Spacer(minLength: 0)
                if isInUse {
                    PlanBadge(plan: L10n.accounts("In Use"))
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onOpen() }

            Button(action: onOpen) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.accounts("Open %@", account.fullName))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, PanelMetrics.controlRowPadding)
    }
}
