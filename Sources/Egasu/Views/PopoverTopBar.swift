import SwiftUI

/// 하위 화면 상단 바 — 파란 뒤로 화살표와 가운데 제목.
/// 화면 전환 중 각 페이지의 바와 내용을 함께 이동.
struct PopoverTopBar: View {
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    let screen: PopoverScreen

    @ViewBuilder
    var body: some View {
        switch screen {
        case .dashboard:
            EmptyView()
        case .accounts:
            if let accountID = popover.accountDetailID, let provider = container.accountManagementProvider(id: accountID) {
                navigationBar(back: { popover.back() }) {
                    AccountTitle(provider: provider)
                } trailing: {
                    ProviderIcon(source: provider.icon, inset: 0.04)
                        .frame(width: 22, height: 22)
                        .frame(width: 28, height: 28)
                        .accessibilityHidden(true)
                }
            } else {
                navigationBar(back: { popover.back() }) {
                    Text(L10n.common("Accounts"))
                } trailing: {
                    EmptyView()
                }
            }
        case .settings:
            VStack(spacing: 10) {
                ZStack {
                    Text(L10n.common("Settings"))
                        .font(.headline)
                    HStack(spacing: 0) {
                        backButton { popover.back() }
                        Spacer(minLength: 0)
                    }
                }
                .frame(height: 28)
                SettingsTabBar()
            }
            .padding(.horizontal, PanelMetrics.margin)
            .padding(.top, PanelMetrics.margin)
            .padding(.bottom, DashboardContentView.barGap)
        }
    }

    private func navigationBar<Title: View, Trailing: View>(
        back: @escaping () -> Void,
        @ViewBuilder title: () -> Title,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        ZStack {
            title()
                .font(.headline)
                .lineLimit(1)
                .padding(.horizontal, 40)
                .frame(maxWidth: .infinity)

            HStack(spacing: 0) {
                backButton(action: back)
                Spacer(minLength: 8)
                trailing()
            }
        }
        .padding(.horizontal, PanelMetrics.margin)
        .frame(height: 36, alignment: .bottom)
        .frame(maxWidth: .infinity)
    }

    private func backButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(L10n.dashboard("Back"), systemImage: "chevron.backward")
                .labelStyle(.iconOnly)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.severityColor(.normal))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverTooltip(L10n.dashboard("Back"))
        .accessibilityLabel(L10n.dashboard("Back"))
    }
}

/// Settings 탭 막대 — 기호 + 이름, 고른 탭은 파란 글자와 배경.
private struct SettingsTabBar: View {
    @Environment(PopoverState.self) private var popover
    @Environment(\.reduceAnimations) private var reduceAnimations

    var body: some View {
        HStack(spacing: 2) {
            ForEach(SettingsTab.allCases, id: \.self) { tab(for: $0) }
        }
    }

    private func tab(for tab: SettingsTab) -> some View {
        let isSelected = popover.settingsTab == tab
        return Button {
            popover.settingsTab = tab
        } label: {
            VStack(spacing: 2) {
                Image(systemName: tab.symbol)
                    .font(.system(size: 16))
                    .frame(height: 20)
                Text(tab.title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? AnyShapeStyle(Theme.severityColor(.normal)) : AnyShapeStyle(.secondary))
            .frame(maxWidth: .infinity)
            .padding(.top, 5)
            .padding(.bottom, 4)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Theme.controlFill)
                }
            }
            .animation(reduceAnimations ? nil : .easeInOut(duration: 0.18), value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// 계정 상세 제목 — Claude·Codex 등록 계정은 계정명(누르면 제자리 이름 변경), 그 밖은 프로바이더 이름.
private struct AccountTitle: View {
    let provider: Provider

    @Environment(AppContainer.self) private var container
    @Environment(AccountRenameStore.self) private var renaming
    @State private var isHovered = false

    var body: some View {
        if let edit = renaming.edit, edit.cardID == provider.id {
            InlineRenameField(renaming: renaming, edit: edit)
                .multilineTextAlignment(.center)
        } else if renaming.canRename(provider.id), let name = container.accountProfileLabel(for: provider.id) {
            Button {
                renaming.begin(provider.id)
            } label: {
                Text(name)
                    .concealingAccountName()
                    .hoverHighlight(isHovered)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }
            .accessibilityLabel(L10n.accounts("Rename %@", container.displayName(for: provider)))
        } else {
            Text(container.displayName(for: provider))
        }
    }
}
