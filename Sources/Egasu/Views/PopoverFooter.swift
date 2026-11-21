import AppKit
import SwiftUI

/// 화면별 푸터 — 대시보드는 버전·다음 업데이트 + 원형 ⋯ 메뉴, Accounts 목록은 계정 추가 버튼.
/// 화면 전환 중 각 페이지에 해당 화면의 푸터 표시.
struct PopoverFooter: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    @Environment(\.colorScheme) private var colorScheme
    private let screen: PopoverScreen

    private static let issuesURL = URL(string: "https://github.com/kimchanhyung98/egasu/issues/new/choose")!

    init?(screen: PopoverScreen, accountDetailID: String?) {
        guard screen == .dashboard || (screen == .accounts && accountDetailID == nil) else { return nil }
        self.screen = screen
    }

    @ViewBuilder
    var body: some View {
        Group {
            if screen == .dashboard {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    Spacer(minLength: 8)
                    if popover.dashboardTab == .priority, liveBoard.hasRows { copyPriorityButton }
                    optionsMenu
                }
                .padding(.horizontal, 4)
            } else {
                Button {
                    popover.isAddingAccount = true
                } label: {
                    Text(L10n.accounts("Add New Account")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .frame(minHeight: 26)
        .padding(.horizontal, PanelMetrics.margin)
        .padding(.top, DashboardContentView.barGap)
        .padding(.bottom, PanelMetrics.margin)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if screen == .dashboard, popover.shareNotice.value {
                shareCopiedPill
                    .offset(y: -34)
            }
        }
        .animation(Motion.spring, value: popover.shareNotice.value)
        .animation(Motion.spring, value: popover.shareNotice.trigger)
    }

    private var liveBoard: PriorityBoard {
        dataStore.priorityBoard(
            accounts: container.dashboardAccounts(), pinned: layout.priorityPinIDs, now: Date(),
            hidingEmails: true
        )
    }

    /// Priority 탭을 이미지로 복사 — 누른 순간의 보드를 읽음.
    private var copyPriorityButton: some View {
        Button {
            guard ShareCardRenderer.copy(PriorityShareCard(
                board: liveBoard, now: Date(), appearance: colorScheme,
                blursAccountNames: container.privacy.hideUsageWhileScreenSharing
            )) else { return }
            popover.shareNotice.present(true)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(L10n.dashboard("Copy Priority Screenshot"))
    }

    /// 원형 ⋯ 버튼 뒤 Options 메뉴. Check for Updates…는 항상 표시하고 Sparkle이 확인할 수 없으면 비활성.
    /// Accounts·Settings 단축키는 라벨 — 메뉴가 닫혀 있으면 `PopoverKeyReader`가 먼저 처리해 이중 발화 없음.
    /// ⌘Q는 다른 소유자가 없어 메뉴 항목이 직접 처리.
    private var optionsMenu: some View {
        Menu {
            Button { popover.toggle(.accounts) } label: {
                Label(L10n.common("Accounts"), systemImage: "person.crop.circle")
            }
            .keyboardShortcut(.return, modifiers: [])

            Button { popover.toggle(.settings) } label: {
                Label(L10n.common("Settings"), systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            Divider()

            Button { updater.checkForUpdates() } label: {
                Label(L10n.dashboard("Check for Updates…"), systemImage: "arrow.triangle.2.circlepath")
            }
            .disabled(!updater.canCheckForUpdates)

            Divider()

            Link(destination: Self.issuesURL) {
                Label(L10n.dashboard("Report an Issue…"), systemImage: "ladybug")
            }

            Button { AboutPanel.present() } label: {
                Label(L10n.dashboard("About egasu"), systemImage: "info.circle")
            }
            Button(role: .destructive) { NSApplication.shared.terminate(nil) } label: {
                Label(L10n.dashboard("Quit egasu"), systemImage: "power")
            }
            .keyboardShortcut("q")
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 26, height: 26)
                .background(Theme.controlFill, in: Circle())
                .contentShape(Circle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.dashboard("Options"))
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: L10n.dashboard("Copied to clipboard"),
            tint: Theme.positive,
            trigger: popover.shareNotice.trigger
        )
    }

    /// 버전 위, 다음 업데이트 카운트다운 아래.
    private var footerIdentity: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("egasu \(AppInfo.version)")
            nextUpdateButton
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }

    private var nextUpdateButton: some View {
        Button {
            refreshNow()
        } label: {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 5) {
                    Text(updateStatusText(now: context.date))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    if isUpdating {
                        MotionAwareProgressView(controlSize: .mini)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .hoverTooltip(L10n.dashboard("Refresh now (⌘R)"))
        .disabled(isUpdating || container.accountSwitch.isSwitching)
    }

    private var isUpdating: Bool {
        container.isRefreshingAll || !dataStore.refreshingProviderIDs.isEmpty
            || container.resetWatchCoordinator.isRefreshing
    }

    private func refreshNow() {
        guard !isUpdating, !container.accountSwitch.isSwitching else { return }
        Task { await container.refreshAll(force: true) }
    }

    private func updateStatusText(now: Date) -> String {
        let hasEnabledProvider = dataStore.knownProviderIDs.contains { container.enablement.isEnabled($0) }
        return RefreshSchedulePresentation.statusText(
            isUpdating: isUpdating,
            nextRefreshAt: hasEnabledProvider ? dataStore.nextGeneralRefreshAt : nil,
            now: now
        )
    }
}
