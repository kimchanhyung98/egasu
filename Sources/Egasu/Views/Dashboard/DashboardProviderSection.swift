import SwiftUI

/// 프로바이더 섹션 — Minimal은 계정 묶음 카드, Cards는 계정별 독립 카드.
struct DashboardProviderSection<Header: View, Account: View>: View {
    let family: DashboardFamily
    var layoutStyle = DashboardLayoutStyle.minimal
    @ViewBuilder var header: (_ isHovered: Bool) -> Header
    @ViewBuilder var account: (DashboardAccount) -> Account

    @State private var isHovered = false
    @Environment(PopoverState.self) private var popover: PopoverState?

    var body: some View {
        VStack(alignment: .leading, spacing: DashboardGrid.headerGap) {
            header(isHovered)
            if layoutStyle == .cards {
                VStack(alignment: .leading, spacing: DashboardGrid.accountSpacing) {
                    ForEach(family.accounts) { entry in
                        card { account(entry) }
                    }
                }
            } else {
                card {
                    VStack(alignment: .leading, spacing: DashboardGrid.accountSpacing) {
                        ForEach(family.accounts) { account($0) }
                    }
                }
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .onChange(of: popover?.popoverShown) { _, shown in
            if shown == false { isHovered = false }
        }
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, DashboardGrid.cardPadding)
            .padding(.top, DashboardGrid.cardTopPadding)
            .padding(.bottom, DashboardGrid.cardBottomPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface()
    }
}

extension DashboardProviderSection where Header == DashboardProviderHeader {
    init(
        family: DashboardFamily, layoutStyle: DashboardLayoutStyle = .minimal,
        @ViewBuilder account: @escaping (DashboardAccount) -> Account
    ) {
        self.init(
            family: family, layoutStyle: layoutStyle,
            header: { _ in DashboardProviderHeader(family: family) }, account: account
        )
    }
}

/// 카드 밖 머리글 — 프로바이더 이름·서버 장애 상태·오른쪽 로고와 호버 시 복사 버튼.
struct DashboardProviderHeader: View {
    let family: DashboardFamily
    var serviceIssue: ProviderServiceIssue?
    var isRevealed = false
    var onCopyScreenshot: (() -> Bool)?
    var reorderGesture: AnyGesture<Void>?

    var body: some View {
        HStack(spacing: onCopyScreenshot == nil ? Theme.Spacing.s : 0) {
            reorderArea(titleArea)
            if let onCopyScreenshot {
                CopyFeedbackButton(
                    accessibilityLabel: L10n.dashboard("Copy %@ Screenshot", family.displayName),
                    isRevealed: isRevealed,
                    action: onCopyScreenshot
                )
                // 기존 슬롯 양쪽 여백을 28pt 버튼 입력 영역에 포함.
                .frame(width: DashboardGrid.iconSize + 2 * Theme.Spacing.s)
                .zIndex(1)
            }
            reorderArea(
                ProviderIcon(source: family.provider.icon, inset: 0.04)
                    .frame(width: DashboardGrid.iconSize, height: DashboardGrid.iconSize)
                    .accessibilityHidden(true)
            )
        }
        .padding(.horizontal, DashboardGrid.cardPadding)
        .frame(height: DashboardGrid.headerHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private var titleArea: some View {
        HStack(spacing: Theme.Spacing.s) {
            Text(family.displayName)
                .font(DashboardGrid.headerFont)
                .lineLimit(1)
            if let serviceIssue {
                let icon = ServerIssueIcon(issue: serviceIssue, providerName: family.displayName)
                if let link = family.provider.visibleLinks.first(where: { $0.label == "Status" }),
                    let url = URL(string: link.url)
                {
                    Link(destination: url) { icon }
                        .buttonStyle(.plain)
                } else {
                    icon
                }
            }
            Spacer(minLength: DashboardGrid.columnGap)
        }
    }

    @ViewBuilder
    private func reorderArea<Content: View>(_ content: Content) -> some View {
        if let reorderGesture {
            content
                .frame(height: DashboardGrid.headerHeight)
                .contentShape(Rectangle())
                .highPriorityGesture(reorderGesture)
        } else {
            content
        }
    }
}

/// 계정 캡션 — 계정명, 상태 표시, 오른쪽 플랜 배지.
struct DashboardAccountCaption: View {
    let account: DashboardAccount
    var plan: String?
    var status = DashboardAccountStatus()
    var signInFeedback: String?
    /// 계정명 ↔ 로그인 이메일 — 이메일을 아는 계정만, 공유 이미지에서는 생략.
    var onToggleName: (() -> Void)?

    /// 우클릭 Rename의 제자리 편집 — 공유 이미지에는 없음.
    @Environment(AccountRenameStore.self) private var renaming: AccountRenameStore?
    @Environment(\.concealsAccountNames) private var concealsAccountNames

    @ViewBuilder
    var body: some View {
        if account.name != nil || plan != nil || status.isShowing {
            caption
                .padding(.bottom, DashboardGrid.captionGap)
                .onChange(of: concealsAccountNames) { _, concealed in
                    if concealed, let edit = renaming?.edit, edit.cardID == account.id {
                        renaming?.cancel(edit)
                    }
                }
        }
    }

    private var caption: some View {
        HStack(spacing: Theme.Spacing.s) {
            if !concealsAccountNames, let renaming, let edit = renaming.edit, edit.cardID == account.id {
                InlineRenameField(renaming: renaming, edit: edit)
                    .font(DashboardGrid.captionFont)
                    .frame(maxWidth: 180)
            } else if let name = account.name {
                if let onToggleName, account.email != nil {
                    Button(action: onToggleName) { nameText(name) }
                        .buttonStyle(.plain)
                } else {
                    nameText(name)
                }
            }
            status.glyph
            if let signInFeedback {
                Text(signInFeedback)
                    .font(DashboardGrid.captionFont)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: DashboardGrid.columnGap)
            if let plan {
                PlanBadge(plan: plan)
            }
        }
        .frame(height: DashboardGrid.captionHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func nameText(_ name: String) -> some View {
        Text(name)
            .font(DashboardGrid.captionFont)
            .foregroundStyle(account.isInUse ? Theme.positive : AnyShapeStyle(.secondary))
            .lineLimit(1)
            .truncationMode(account.isNamedByEmail ? .middle : .tail)
            .concealingAccountName()
    }
}

/// 플랜·"In Use" 작은 배지.
struct PlanBadge: View {
    let plan: String

    var body: some View {
        Text(plan)
            .font(DashboardGrid.planFont)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, DashboardGrid.planPadding)
            .frame(height: DashboardGrid.captionHeight)
            .background(Theme.controlFill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
    }
}

/// 계정 상태 표시 — 갱신 중 진행 표시, 문제 발생 시 상세 연결 경고, 오래된 데이터는 시계 표시.
struct DashboardAccountStatus {
    var refreshing = false
    var notice: String?
    var staleness: StalenessHint?
    var onFix: (() -> Void)?

    var isShowing: Bool { refreshing || notice != nil || staleness != nil }

    @MainActor @ViewBuilder
    var glyph: some View {
        if refreshing {
            MotionAwareProgressView(controlSize: .mini)
                .accessibilityLabel(L10n.dashboard("Refreshing"))
        } else if let notice {
            Button { onFix?() } label: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
            }
            .buttonStyle(.plain)
            .disabled(onFix == nil)
            .hoverTooltip(notice)
            .accessibilityLabel(notice)
        } else if let staleness {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .hoverTooltip(staleness.tooltip)
                .accessibilityLabel(staleness.label)
        }
    }
}

/// 계정 섹션의 정적 모양 — 공유 이미지와 드래그 미리보기.
struct DashboardAccountRows: View {
    let account: DashboardAccount
    var plan: String?
    var layoutStyle = DashboardLayoutStyle.minimal
    var showsEmptyMessage = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DashboardAccountCaption(account: account, plan: plan)
            if showsEmptyMessage && account.lines.isEmpty && account.waitingMetricIDs.isEmpty {
                Text(L10n.dashboard("No metrics to show"))
                    .font(DashboardMetricRow.font)
                    .foregroundStyle(.secondary)
                    .frame(minHeight: DashboardGrid.rowHeight, alignment: .leading)
            } else {
                DashboardLineStack(account: account, layoutStyle: layoutStyle) { line in
                    DashboardMetricRow(
                        model: line.dashboardRow(), chartPoints: line.data.chartPoints, layoutStyle: layoutStyle,
                        valueTooltip: line.data.isChart ? line.data.chartNote : nil
                    )
                }
            }
        }
    }
}
