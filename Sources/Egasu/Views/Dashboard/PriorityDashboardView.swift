import SwiftUI

/// Priority 탭 — 모든 계정의 한도 중 확인이 필요한 것만 급한 순서로.
struct PriorityDashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverState.self) private var popover

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let accounts = container.dashboardAccounts().map { dataStore.showsAccountEmails ? $0.showingEmail : $0 }
            PriorityBoardList(
                board: dataStore.priorityBoard(accounts: accounts, pinned: layout.priorityPinIDs, now: context.date),
                now: context.date,
                onToggleMeterStyle: { dataStore.meterStyle.toggle() },
                onToggleResetDisplay: { dataStore.resetDisplayMode.toggle() },
                onToggleAccountName: { dataStore.showsAccountEmails.toggle() },
                onShowAllUsage: { popover.dashboardTab = .allUsage },
                onFixAccount: { container.fixAccount($0, openAccount: popover.openAccounts) },
                onMetricCommand: { command in
                    withAnimation(Motion.spring) {
                        switch command {
                        case .setPinned(let id, let pinned): layout.setMetric(id, pinned: pinned)
                        case .hide(let id): layout.setMetricEnabled(id, false)
                        default: break
                        }
                    }
                }
            )
        }
    }
}

/// Priority 목록 — 탭과 공유 이미지가 공유.
struct PriorityBoardList: View {
    @Environment(\.concealsAccountNames) private var concealsAccountNames
    let board: PriorityBoard
    let now: Date
    /// 공유 이미지처럼 누를 수 없는 곳에서는 생략.
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    /// 계정명 ↔ 로그인 이메일 — 이메일을 아는 계정의 이름만 누를 수 있음.
    var onToggleAccountName: (() -> Void)?
    var onShowAllUsage: (() -> Void)?
    var onFixAccount: ((String) -> Void)?
    var onMetricCommand: ((DashboardCommand) -> Void)?

    private static let gaugeSide: CGFloat = 32

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.margin) {
            if !board.pinned.isEmpty { pinnedSection }
            summary
            if !board.waiting.isEmpty { waitingSection }
            if !board.usedUp.isEmpty { usedUpSection }
        }
    }

    @ViewBuilder
    private var summary: some View {
        switch board.summary {
        case .waitingForUsage:
            EmptyView()
        case .noReportedLimits:
            VStack(spacing: 4) {
                Text(L10n.dashboard("No Reported Limits"))
                    .font(.system(size: 13, weight: .medium))
                allUsageButton
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        case .unavailable:
            accountNotices
        case .allClear, .listed:
            VStack(alignment: .leading, spacing: PanelMetrics.margin) {
                if !board.attention.isEmpty || board.showsClearRow { attentionSection }
                if board.offersAllUsage { allUsageButton }
                if !board.useItOrLoseIt.isEmpty { useItOrLoseItSection }
                if !board.notices.isEmpty { accountNotices }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var allUsageButton: some View {
        if let onShowAllUsage {
            ViewAllUsageButton(action: onShowAllUsage)
        }
    }

    private var accountNotices: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 2) {
                sectionLabel(L10n.dashboard("Needs Attention"))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.notice)
                    .padding(.bottom, 2)
                    .accessibilityHidden(true)
            }
            ForEach(board.notices) { notice in
                noticeRow(notice)
                    .padding(.horizontal, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func noticeRow(_ notice: PriorityBoard.AccountNotice) -> some View {
        HStack(spacing: 8) {
            icon(notice.account.provider, side: 15)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(notice.account.providerName)
                    .font(.system(size: 13, weight: .semibold))
                if let name = notice.account.name {
                    toggling(nameToggle(for: notice.account)) {
                        Text(name)
                            .font(.system(size: 11))
                            .foregroundStyle(notice.account.isInUse ? Theme.positive : AnyShapeStyle(.secondary))
                            .truncationMode(notice.account.isNamedByEmail ? .middle : .tail)
                            .concealingAccountName()
                    }
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let onFixAccount {
                Button(L10n.dashboard("Fix")) { onFixAccount(notice.account.id) }
                    .controlSize(.small)
            }
        }
        .frame(height: 28)
        .accessibilityValue(concealsAccountNames ? L10n.dashboard("Current usage unavailable.") : notice.message)
    }

    private var pinnedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(L10n.dashboard("Pinned"))
            ForEach(board.pinned) { pin in
                pinnedRow(pin)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu { metricMenu(pin.line, pinned: true) }
            }
        }
    }

    private func pinnedRow(_ pin: PinnedMetric) -> some View {
        let spent =
            switch pin.item?.reason {
            case .usedUp?, .emptyBalance?: true
            default: false
            }
        let callout =
            pin.item?.runOutText(now: now).map { ($0, Theme.severityTextColor(.warning)) }
            ?? pin.item?.resetsInText(now: now).map { ($0, Theme.severityTextColor(.normal)) }
        return limitRow(
            pin.account, pin.data, severity: pin.item?.severity ?? pin.data.fillSeverity,
            callout: callout, status: spent ? L10n.dashboard("Used Up") : nil,
            truncatesValue: pin.line.dashboardRow(now: now).truncatesValue
        )
    }

    private var attentionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(L10n.dashboard("Running Out"))
            if board.attention.isEmpty { clearRow }
            ForEach(board.attention) { item in
                limitRow(
                    item.account, item.data, severity: item.severity,
                    callout: item.runOutText(now: now).map { ($0, Theme.severityTextColor(.warning)) }
                )
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .contextMenu { metricMenu(item.line, pinned: item.isPinned) }
            }
        }
    }

    private var usedUpSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(L10n.dashboard("Used Up"))
            ForEach(board.usedUp) { item in
                usedUpRow(item)
                    .padding(.horizontal, 4)
                    .contentShape(Rectangle())
                    .contextMenu { metricMenu(item.line, pinned: item.isPinned) }
            }
        }
        .opacity(0.5)
    }

    private var useItOrLoseItSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionLabel(L10n.dashboard("Use It or Lose It"))
            ForEach(board.useItOrLoseIt) { item in
                limitRow(
                    item.account, item.data, severity: item.severity,
                    callout: item.resetsInText(now: now).map { ($0, Theme.severityTextColor(.normal)) }
                )
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .contextMenu { metricMenu(item.line, pinned: item.isPinned) }
            }
        }
    }

    /// 고정·해제와 Hide — 숨기면 그 계정에서만 빠지고 고정도 풀림.
    @ViewBuilder
    private func metricMenu(_ line: DashboardLine, pinned: Bool) -> some View {
        if let onMetricCommand {
            DashboardMenu(
                sections: [DashboardMenus.metric(line.id, pinnable: line.descriptor.pinnable, pinned: pinned)],
                perform: onMetricCommand
            )
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func icon(_ provider: Provider, side: CGFloat) -> some View {
        ProviderIcon(source: provider.icon, inset: 0.04)
            .frame(width: side, height: side)
            .frame(width: 16)
    }

    private func nameToggle(for account: DashboardAccount) -> (() -> Void)? {
        account.email == nil ? nil : onToggleAccountName
    }

    /// All Usage에서 값·초기화를 누를 때와 같은 전환.
    @ViewBuilder
    private func toggling(_ action: (() -> Void)?, @ViewBuilder label: () -> some View) -> some View {
        if let action {
            Button(action: action, label: label)
                .buttonStyle(.plain)
        } else {
            label()
        }
    }

    /// `callout`은 초기화 자리를 대신 — 빠른 소진으로만 오른 한도의 소진 시각, 초기화 전 사용 한도의 초기화.
    private func limitRow(
        _ account: DashboardAccount, _ data: WidgetData, severity: WidgetData.MeterSeverity,
        callout: (text: String, color: Color)? = nil, status: String? = nil, truncatesValue: Bool = false
    ) -> some View {
        HStack(spacing: 10) {
            PriorityGauge(
                fraction: data.fraction, severity: severity, icon: account.provider.icon,
                paceMark: data.paceMark(now: now))
            VStack(alignment: .leading, spacing: 1) {
                Text(data.localizedTitle)
                    .font(.system(size: 13, weight: .medium))
                toggling(nameToggle(for: account)) {
                    Text(account.subtitle)
                        .accessibilityLabel(account.fullName)
                        .font(.system(size: 11))
                        .foregroundStyle(account.isInUse ? Theme.positive : AnyShapeStyle(.secondary))
                        .truncationMode(account.isNamedByEmail ? .middle : .tail)
                        .modifier(ConcealIfNamed(isNamed: account.name != nil))
                }
            }
            .lineLimit(1)
            .layoutPriority(truncatesValue ? 1 : 0)
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 1) {
                toggling(status == nil && data.hasMeterStyleToggle ? onToggleMeterStyle : nil) {
                    Text(status ?? data.amountText)
                        .font(.system(size: 13, weight: .medium))
                        .monospacedDigit()
                }
                if let callout {
                    Text(callout.text)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(callout.color)
                        .monospacedDigit()
                } else if let reset = data.compactResetText(now: now) {
                    toggling(onToggleResetDisplay) {
                        Text(reset)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }
            .lineLimit(1)
            .truncationMode(truncatesValue ? .middle : .tail)
            .fixedSize(horizontal: !truncatesValue, vertical: true)
        }
        .frame(height: 46)
    }

    private func usedUpRow(_ item: PriorityItem) -> some View {
        HStack(spacing: 8) {
            icon(item.account.provider, side: 15)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(item.data.localizedTitle)
                    .font(.system(size: 13))
                toggling(nameToggle(for: item.account)) {
                    Text(item.account.subtitle)
                        .accessibilityLabel(item.account.fullName)
                        .font(.system(size: 11))
                        .foregroundStyle(item.account.isInUse ? Theme.positive : AnyShapeStyle(.secondary))
                        .truncationMode(item.account.isNamedByEmail ? .middle : .tail)
                        .modifier(ConcealIfNamed(isNamed: item.account.name != nil))
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if let note = item.usedUpNote(now: now) {
                toggling(item.data.resetsAt == nil ? nil : onToggleResetDisplay) {
                    Text(note)
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .lineLimit(1)
                        .fixedSize()
                }
            }
        }
        .frame(height: 28)
    }

    private var clearRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "circle.dashed")
                .font(.system(size: 16))
                .frame(width: Self.gaugeSide)
                .accessibilityHidden(true)
            Text(L10n.dashboard("No Matching Limits"))
                .font(.system(size: 13))
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .frame(minHeight: Self.gaugeSide)
        .padding(.horizontal, 4)
        .accessibilityElement(children: .combine)
    }

    /// 대기 계정의 자리 표시 행 — 수신할 한도를 모르므로 링은 원판으로 표시.
    private var waitingSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(board.waiting) { account in
                HStack(spacing: 10) {
                    Circle()
                        .frame(width: Self.gaugeSide, height: Self.gaugeSide)
                    VStack(alignment: .leading, spacing: 6) {
                        Capsule().frame(width: 84, height: 9)
                        Capsule().frame(width: 56, height: 7)
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 6) {
                        Capsule().frame(width: 48, height: 9)
                        Capsule().frame(width: 32, height: 7)
                    }
                }
                .skeleton()
                .frame(height: 46)
                .padding(.horizontal, 4)
                .accessibilityElement()
                .accessibilityLabel(L10n.dashboard("Waiting for Usage"))
                .accessibilityValue(concealsAccountNames ? account.providerName : account.fullName)
            }
        }
    }
}

/// 계정명일 때만 흐림 — 프로바이더 이름은 그대로.
private struct ConcealIfNamed: ViewModifier {
    let isNamed: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if isNamed { content.concealingAccountName() } else { content }
    }
}

/// 프로바이더 마크를 둘러싼 한도 링 — Used·Left와 무관하게 같은 방향으로 채우고 고른 속도 위치에 눈금.
private struct PriorityGauge: View {
    let fraction: Double
    let severity: WidgetData.MeterSeverity
    let icon: IconSource
    let paceMark: Double?

    private static let lineWidth: CGFloat = 3

    var body: some View {
        ZStack {
            Circle()
                .inset(by: Self.lineWidth / 2)
                .stroke(Theme.meterTrack, lineWidth: Self.lineWidth)
            Circle()
                .inset(by: Self.lineWidth / 2)
                .trim(from: 0, to: fraction)
                .stroke(Theme.severityColor(severity), style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if let paceMark {
                PaceTick(mark: paceMark)
                    .stroke(style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .blendMode(.destinationOut)
                PaceTick(mark: paceMark)
                    .stroke(Theme.paceMark, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
            }
            ProviderIcon(source: icon, inset: 0.04)
                .frame(width: 16, height: 16)
        }
        .compositingGroup()
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

/// 링 트랙을 가로지르는 짧은 선 — 12시 방향부터 시계 방향으로 `mark` 바퀴.
private struct PaceTick: Shape {
    let mark: Double

    func path(in rect: CGRect) -> Path {
        let angle = mark * 2 * .pi
        func point(_ radius: CGFloat) -> CGPoint {
            CGPoint(x: rect.midX + radius * sin(angle), y: rect.midY - radius * cos(angle))
        }
        var path = Path()
        path.move(to: point(rect.width / 2 - 4.25))
        path.addLine(to: point(rect.width / 2 + 0.75))
        return path
    }
}
