import AppKit
import SwiftUI

/// All Usage 본문 — 저장된 표시 방식에 따라 미니멀 격자·계정별 카드 전환.
/// 머리글 드래그 = 프로바이더 순서, 계정 캡션 드래그 = 계정 순서, 행 드래그 = 그 계정의 지표 순서.
struct WidgetGroupedListView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverState.self) private var popover
    @Environment(AccountRenameStore.self) private var renaming
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.concealsAccountNames) private var concealsAccountNames
    let families: [DashboardFamily]
    let reorderSpaceName: String
    @Binding var reorderLift: ReorderLift?
    @Binding var retainedResetClaims: [String: CodexResetClaimBinding]

    @State private var rowFrames: [String: CGRect] = [:]
    @State private var activeMetricID: String?
    @State private var activeAccountID: String?
    @State private var activeFamilyID: String?
    @State private var pendingAccountSwitch: AccountProfile?
    @State private var accountSwitchError: String?

    private var layoutStyle: DashboardLayoutStyle { dataStore.displaySettings.dashboardLayout }

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardGrid.sectionSpacing) {
            ForEach(families) { family in
                section(family)
                    .contextMenu {
                        DashboardMenu(sections: DashboardMenus.provider(family, refreshDisabled: refreshBlocked(family.accounts.map(\.id))), perform: perform)
                    }
                    .opacity(activeFamilyID == Self.familyFrameID(family.id) ? 0 : 1)
                    .reorderFrame(id: Self.familyFrameID(family.id), in: .named(reorderSpaceName))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onPreferenceChange(ReorderFramePreferenceKey.self) { rowFrames = $0 }
        .animation(Motion.spring, value: families.map(\.id))
        .accountSwitchConfirmation(selection: $pendingAccountSwitch, error: $accountSwitchError)
        .alert(
            L10n.dashboard("Couldn't Switch Account"),
            isPresented: isAccountSwitchErrorPresented,
            presenting: accountSwitchError
        ) { _ in
            Button(L10n.dashboard("OK"), role: .cancel) {}
        } message: { error in
            Text(error)
        }
    }

    /// 전환 확인창이 닫힌 뒤 오류 표시.
    private var isAccountSwitchErrorPresented: Binding<Bool> {
        Binding(
            get: { accountSwitchError != nil && pendingAccountSwitch == nil },
            set: { if !$0 { accountSwitchError = nil } }
        )
    }

    private func section(_ family: DashboardFamily) -> some View {
        DashboardProviderSection(family: family, layoutStyle: layoutStyle) { isHovered in
            DashboardProviderHeader(
                family: family,
                serviceIssue: container.providerStatus.status(for: family.provider.id).issue,
                isRevealed: isHovered,
                onCopyScreenshot: { shareScreenshot(family.id) },
                reorderGesture: AnyGesture(familyDragGesture(for: family).map { _ in () })
            )
        } account: { account in
            accountSection(account, in: family)
        }
    }

    private func status(for accountID: String) -> DashboardAccountStatus {
        let queued = dataStore.isRefreshQueued(for: accountID)
        let notice = dataStore.headerNotice(for: accountID).map {
            concealsAccountNames ? L10n.dashboard("Current usage unavailable.") : $0
        }
        return DashboardAccountStatus(
            refreshing: dataStore.refreshingProviderIDs.contains(accountID) && !queued,
            notice: notice,
            staleness: dataStore.stalenessHint(for: accountID),
            onFix: { container.fixAccount(accountID, openAccount: popover.openAccounts) }
        )
    }

    private func accountSection(_ account: DashboardAccount, in family: DashboardFamily) -> some View {
        let accountStatus = status(for: account.id)
        return VStack(alignment: .leading, spacing: 0) {
            DashboardAccountCaption(
                account: dataStore.showsAccountEmails ? account.showingEmail : account,
                plan: dataStore.plan(for: account.id), status: accountStatus,
                onToggleName: { dataStore.showsAccountEmails.toggle() }
            )
                .highPriorityGesture(accountDragGesture(for: account, in: family), including: family.accounts.count > 1 ? .all : .subviews)
            rows(of: account, status: accountStatus)
        }
        .contextMenu {
            DashboardMenu(sections: accountMenu(account, status: accountStatus), perform: perform)
        }
        .id(account.id)
        .opacity(activeAccountID == account.id ? 0 : 1)
        .reorderFrame(id: account.id, in: .named(reorderSpaceName))
    }

    private func rows(of account: DashboardAccount, status: DashboardAccountStatus) -> some View {
        DashboardLineStack(account: account, layoutStyle: layoutStyle) { line in
            DashboardLiveRow(
                line: line,
                layoutStyle: layoutStyle,
                providerName: account.providerName,
                accountStatus: status,
                savedAt: dataStore.snapshots[account.id]?.refreshedAt,
                onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
                retainsResetClaimRow: retainedResetClaims[line.id] != nil,
                onRetainResetClaimRow: { binding in
                    if retainedResetClaims[line.id] != binding { retainedResetClaims[line.id] = binding }
                }
            )
            .opacity(activeMetricID == line.id ? 0 : 1)
            .highPriorityGesture(metricDragGesture(for: line, in: account))
            .contentShape(Rectangle())
            .contextMenu {
                DashboardMenu(
                    sections: [DashboardMenus.metric(line.id, pinnable: line.descriptor.pinnable, pinned: layout.isMetricPinned(line.id))]
                        + accountMenu(account, status: status),
                    perform: perform
                )
            }
            .reorderFrame(id: line.id, in: .named(reorderSpaceName))
        }
    }

    private func accountMenu(_ account: DashboardAccount, status: DashboardAccountStatus) -> DashboardMenus.Sections {
        DashboardMenus.account(
            account,
            status: status.menuText,
            switchTitle: switchTitle(for: account.id),
            canRename: renaming.canRename(account.id),
            renameDisabled: concealsAccountNames,
            refreshDisabled: refreshBlocked([account.id])
        )
    }

    /// 사용 중이 아닌 등록 계정의 "Use {Provider}: {name}" — 전환 진행 중이면 비활성.
    private func switchTitle(for accountID: String) -> (title: String, profileID: String, isDisabled: Bool)? {
        guard let profile = AccountCardPresentationPlanner.switchProfile(
            providerID: accountID, mode: .separateCards,
            profileID: container.accountProfileID(for: accountID),
            profiles: container.accountProfiles.profiles
        ), container.accountProfiles.preferredProfileID(family: profile.family) != profile.id else { return nil }
        let name = AccountNamePrivacy.displayName(
            profile.label, email: container.accountLoginEmail(for: profile), conceals: concealsAccountNames
        )
        return (L10n.dashboard("Use %@: %@", profile.family.capitalized, name), profile.id, container.accountSwitch.isSwitching)
    }

    private func refreshBlocked(_ accountIDs: [String]) -> Bool {
        accountIDs.contains { container.accountSwitch.blocksRefresh(for: $0) }
    }

    private func perform(_ command: DashboardCommand) {
        switch command {
        case .refresh(let accountIDs):
            Task {
                for id in accountIDs where !container.accountSwitch.blocksRefresh(for: id) {
                    _ = await container.refresh(providerID: id, force: true)
                }
            }
        case .manageAccounts:
            popover.openAccounts(nil)
        case .open(let url):
            NSWorkspace.shared.open(url)
        case .editAccount(let accountID):
            popover.openAccounts(accountID)
        case .setPinned(let metricID, let pinned):
            withAnimation(Motion.spring) { layout.setMetric(metricID, pinned: pinned) }
        case .hide(let metricID):
            withAnimation(Motion.spring) { layout.setMetricEnabled(metricID, false) }
        case .rename(let accountID):
            guard !concealsAccountNames else { return }
            renaming.begin(accountID)
        case .switchAccount(let profileID):
            guard !container.accountSwitch.isSwitching else { return }
            pendingAccountSwitch = container.accountProfiles.profile(id: profileID)
        }
    }

    @discardableResult
    private func shareScreenshot(_ familyID: String) -> Bool {
        guard
            let family = container.dashboardFamilies(retainingResetClaims: retainedResetClaims)
                .first(where: { $0.id == familyID })
        else { return false }
        let plans = Dictionary(
            uniqueKeysWithValues: family.accounts.compactMap { account in
                dataStore.plan(for: account.id).map { (account.id, $0) }
            })
        guard
            ShareCardRenderer.share(
                family: family, plans: plans, appearance: colorScheme,
                blursAccountNames: container.privacy.hideUsageWhileScreenSharing,
                layoutStyle: layoutStyle
            )
        else { return false }
        popover.shareNotice.present(true)
        return true
    }

    // MARK: - Reorder

    private static func familyFrameID(_ familyID: String) -> String { "family:\(familyID)" }

    private func metricDragGesture(for line: DashboardLine, in account: DashboardAccount) -> some Gesture {
        reorderDragGesture(
            id: line.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeMetricID,
            lift: $reorderLift,
            makeLift: { value in
                let preview = DashboardMetricRow(
                    model: line.dashboardRow(), chartPoints: line.data.chartPoints, layoutStyle: layoutStyle,
                    valueTooltip: line.data.isChart ? line.data.chartNote : nil
                )
                    .padding(.horizontal, DashboardGrid.cardPadding)
                    .liftedRowSurface()
                return ReorderLift.make(id: line.id, payload: .view(AnyView(preview)), value: value, frames: rowFrames)
            },
            orderedIDs: { account.lines.map(\.id) },
            reorder: { layout.reorderMetric(dragged: line.id, target: $0, in: account.id) }
        )
    }

    private func accountDragGesture(for account: DashboardAccount, in family: DashboardFamily) -> some Gesture {
        reorderDragGesture(
            id: account.id,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeAccountID,
            lift: $reorderLift,
            makeLift: { value in
                let preview = DashboardAccountRows(
                    account: dataStore.showsAccountEmails ? account.showingEmail : account, plan: dataStore.plan(for: account.id),
                    layoutStyle: layoutStyle
                )
                    .padding(DashboardGrid.cardPadding)
                    .liftedRowSurface()
                return ReorderLift.make(id: account.id, payload: .view(AnyView(preview)), value: value, frames: rowFrames)
            },
            orderedIDs: { family.accounts.map(\.id) },
            reorder: { target in reorderAccount(account.id, onto: target, family: family.id) },
            shouldHandle: { family.accounts.count > 1 }
        )
    }

    /// 같은 프로바이더 안 계정 순서 — 등록 계정 순서 저장소를 그대로 사용.
    private func reorderAccount(_ dragged: String, onto target: String, family: String) -> Bool {
        guard let draggedProfile = container.accountProfileID(for: dragged),
              let targetProfile = container.accountProfileID(for: target) else { return false }
        return container.accountCardPresentation.reorder(
            dragged: draggedProfile, target: targetProfile, family: family,
            profiles: container.accountProfiles.profiles(family: family)
        )
    }

    private func familyDragGesture(for family: DashboardFamily) -> some Gesture {
        let frameID = Self.familyFrameID(family.id)
        return reorderDragGesture(
            id: frameID,
            coordinateSpaceName: reorderSpaceName,
            rowFrames: rowFrames,
            active: $activeFamilyID,
            lift: $reorderLift,
            makeLift: { value in
                let plans = Dictionary(uniqueKeysWithValues: family.accounts.compactMap { account in
                    dataStore.plan(for: account.id).map { (account.id, $0) }
                })
                let preview = DashboardProviderSection(family: family, layoutStyle: layoutStyle) { account in
                    DashboardAccountRows(account: dataStore.showsAccountEmails ? account.showingEmail : account,
                                         plan: plans[account.id], layoutStyle: layoutStyle)
                }
                return ReorderLift.make(id: frameID, payload: .view(AnyView(preview)), value: value, frames: rowFrames)
            },
            orderedIDs: {
                container.dashboardFamilies(retainingResetClaims: retainedResetClaims).map { Self.familyFrameID($0.id) }
            },
            reorder: { target in
                let targetFamilyID = String(target.dropFirst("family:".count))
                guard let draggedID = family.accounts.first?.id,
                      let targetID = container.dashboardFamilies(retainingResetClaims: retainedResetClaims)
                          .first(where: { $0.id == targetFamilyID })?.accounts.first?.id
                else { return false }
                return layout.reorderProvider(dragged: draggedID, target: targetID)
            }
        )
    }
}
