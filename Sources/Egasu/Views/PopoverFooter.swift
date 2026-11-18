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
    let screen: PopoverScreen

    private static let issuesURL = URL(string: "https://github.com/kimchanhyung98/egasu/issues/new/choose")!

    @ViewBuilder
    var body: some View {
        Group {
            if screen == .dashboard {
                HStack(alignment: .center, spacing: 8) {
                    footerIdentity
                    Spacer(minLength: 8)
                    optionsMenu
                }
                .padding(.horizontal, 4)
            } else if screen == .accounts, popover.accountDetailID == nil {
                Button {
                    popover.isAddingAccount = true
                } label: {
                    Text(L10n.accounts("Add New Account")).frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                EmptyView()
            }
        }
        .frame(minHeight: 26)
        .padding(.horizontal, PanelMetrics.margin)
        .padding(.top, 7)
        .padding(.bottom, PanelMetrics.margin)
        .frame(maxWidth: .infinity)
        .overlay(alignment: .top) {
            if screen == .dashboard, layout.shareConfirmation {
                shareCopiedPill
                    .offset(y: -34)
            }
        }
        .animation(Motion.spring, value: layout.shareConfirmation)
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

            shareScreenshotMenu

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

    @ViewBuilder
    private var shareScreenshotMenu: some View {
        let accounts = container.presentedShareAccounts()
        Menu {
            if accounts.isEmpty {
                // 스크린샷 대상 없음 — 빈 서브메뉴 대신 비활성 항목 표시
                Button(L10n.dashboard("No Enabled Providers")) {}
                    .disabled(true)
            } else {
                ForEach(accounts) { account in
                    Button(container.accountCardTitle(for: account.provider)) { shareCard(account.id) }
                }
            }
        } label: {
            Label(L10n.dashboard("Share Screenshot"), systemImage: "square.and.arrow.up")
        }
    }

    private func shareCard(_ accountID: String) {
        guard let account = container.dashboardAccounts().first(where: { $0.id == accountID }) else { return }
        ShareCardRenderer.share(
            account: account,
            plan: dataStore.plan(for: account.id),
            layout: layout,
            appearance: colorScheme,
            displayName: container.accountCardTitle(for: account.provider)
        )
    }

    private var shareCopiedPill: some View {
        TransientPill(
            systemImage: "checkmark.circle.fill",
            text: L10n.dashboard("Copied to clipboard"),
            tint: Theme.positive,
            trigger: layout.shareConfirmationTrigger
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
