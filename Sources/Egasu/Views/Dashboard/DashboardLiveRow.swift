import SwiftUI

/// 대시보드 행 — 초기화·만료·예측 기한이 있으면 30초마다, 예측 기한에는 정확히 다시 그림(네트워크 요청 없음).
/// 기간 비용은 사용 내역, Limit Resets는 초기화권, Usage Trend는 30일 상세를 호버·클릭으로 표시 — 사용량과 내역이 모두 없는 기간은 생략.
struct DashboardLiveRow: View {
    let line: DashboardLine
    var layoutStyle = DashboardLayoutStyle.minimal
    /// 빈 사용 내역 문구·공유 이미지의 프로바이더 이름.
    var providerName = ""
    /// 합계 패널의 불러오는 중·사유.
    var accountStatus = DashboardAccountStatus()
    /// 합계 패널 제목의 읽은 시각.
    var savedAt: Date?
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    var retainsResetClaimRow = false
    var onRetainResetClaimRow: ((CodexResetClaimBinding?) -> Void)?

    @Environment(\.reduceAnimations) private var reduceAnimations
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.codexResetClaim) private var codexResetClaim
    @State private var hover = HoverPopoverState()

    var body: some View {
        Group {
            if needsClock {
                TimelineView(WidgetRowTimelineSchedule(deadline: line.data.forecastDeadline)) { context in
                    row(now: context.date)
                }
            } else {
                row(now: Date())
            }
        }
        .onChange(of: hasDetail) { _, isAvailable in hover.detailAvailabilityChanged(isAvailable) }
        .onChange(of: line.data.modelBreakdown) { _, _ in hover.dismiss() }
        // 초기화권 사용이 강제 새로고침을 일으키므로 고정 중이면 결과 배너를 위해 유지.
        .onChange(of: line.data.expiriesAt) { _, _ in
            if !hover.isPinned && !retainsResetClaimRow { hover.dismiss() }
        }
        .onChange(of: line.data.codexResetClaimBinding) { _, _ in
            if retainsResetClaimRow { hover.dismiss() }
        }
        .onChange(of: hover.isPresented) { _, isPresented in
            if !isPresented { onRetainResetClaimRow?(nil) }
        }
        .onDisappear {
            hover.dismiss()
            onRetainResetClaimRow?(nil)
        }
    }

    var needsClock: Bool {
        // 마지막 초기화권 사용 후에도 같은 뷰에 상세 팝오버 유지.
        line.data.showsResetExpiries || line.data.resetsAt != nil || !line.data.expiriesAt.isEmpty
            || line.data.forecastDeadline != nil
    }

    private func row(now: Date) -> some View {
        let data = line.data.presented(at: now)
        return DashboardMetricRow(
            model: data.dashboardRow(now: now),
            chartPoints: data.chartPoints,
            layoutStyle: layoutStyle,
            onToggleMeterStyle: data.hasMeterStyleToggle ? onToggleMeterStyle : nil,
            onToggleResetDisplay: data.hasResetLabel(now: now) ? onToggleResetDisplay : nil,
            paceTooltip: paceTooltip(data, now: now),
            valueTooltip: valueTooltip(data, now: now),
            resetTooltip: data.resetTooltip(now: now),
            figure: figure
        )
    }

    func paceTooltip(_ data: WidgetData, now: Date) -> String? {
        let lines = [data.paceTooltip(now: now), data.softLimitStatusText].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    func valueTooltip(_ data: WidgetData, now: Date) -> String? {
        let data = data.presented(at: now)
        if data.isChart { return data.chartNote }
        if data.isForecast { return data.forecastTooltip(now: now) }
        if data.isBounded { return data.meterStyleTooltip }
        return hasDetail ? nil : data.unboundedValueTooltip
    }

    private var detailKind: WidgetRowDetail? {
        line.data.rowDetail(reportsModels: line.descriptor.isSpendTile)
    }

    var hasDetail: Bool { detailKind != nil }

    private var figure: (AnyView) -> AnyView {
        guard hasDetail else { return { $0 } }
        return { AnyView(hoverTrigger($0)) }
    }

    private func hoverTrigger(_ figure: AnyView) -> some View {
        let lit = hover.overInline || hover.isPresented
        return Button(action: hover.openDetails) { figure }
            .buttonStyle(.plain)
            .accessibilityHint(L10n.dashboard("Show details"))
            .hoverHighlight(lit)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
            }
            .motionAwareHoverPopover(
                isPresented: Binding(
                    get: { hover.isPresented },
                    // 외부 클릭은 호버 종료 없이 상세를 닫을 수 있으므로 전체 호버 상태 정리.
                    set: { if !$0 { hover.dismiss() } }
                ),
                reduceAnimations: reduceAnimations,
                content: { detail }
            )
    }

    @ViewBuilder
    private var detail: some View {
        let data = line.data
        switch detailKind {
        case .saved:
            UsageBreakdownSavedDetail(
                title: data.localizedTitle,
                figures: data.selectedValues.map { MetricFormatter.string(for: $0, style: .row) },
                savedAt: savedAt,
                status: accountStatus,
                onHoverChange: { inside in hover.detailHover(inside) }
            )
        case .breakdown, .empty:
            let usage = UsageBreakdown(title: data.localizedTitle, breakdown: data.hasModelBreakdown ? data.modelBreakdown ?? .empty : .empty)
            UsageBreakdownDetail(
                usage: usage, providerName: providerName, icon: data.icon,
                onCopy: { figure in
                    ShareCardRenderer.copy(UsageBreakdownShareCard(
                        usage: usage, providerName: providerName, icon: data.icon, figure: figure, appearance: colorScheme
                    ))
                },
                onHoverChange: { inside in hover.detailHover(inside) }
            )
        case .resets:
            RateLimitResetsDetail(
                count: data.resetCreditCount, expiries: data.expiriesAt,
                onHoverChange: { inside in hover.detailHover(inside) },
                onPinChange: { pinned in
                    hover.setPinned(pinned)
                    if pinned { onRetainResetClaimRow?(data.codexResetClaimBinding) }
                },
                onClaimResult: { hover.releasePin(after: .seconds(2)) },
                claimBinding: data.codexResetClaimBinding,
                claim: resetClaimAction
            )
        case .trend:
            UsageTrendDetail(title: data.localizedTitle, points: data.chartPoints, note: data.chartNote) { inside in
                hover.detailHover(inside)
            }
        case nil:
            EmptyView()
        }
    }

    private var resetClaimAction: ((Date, String) async -> ResetClaimOutcome)? {
        guard let binding = line.data.codexResetClaimBinding,
              let providerID = line.data.providerID else { return nil }
        return codexResetClaim?.claimAction(for: providerID, binding: binding)
    }
}
/// 30초 갱신 사이에 예측 만료 시각을 추가하는 행 전용 표시 일정.
struct WidgetRowTimelineSchedule: TimelineSchedule {
    let deadline: Date?
    var interval: TimeInterval = 30

    func entries(from startDate: Date, mode: Mode) -> Entries {
        Entries(
            nextPeriodic: startDate,
            deadline: deadline.map { max($0, startDate) },
            interval: interval
        )
    }

    struct Entries: Sequence, IteratorProtocol {
        private var nextPeriodic: Date
        private var deadline: Date?
        private let interval: TimeInterval
        private var finished = false

        fileprivate init(nextPeriodic: Date, deadline: Date?, interval: TimeInterval) {
            self.nextPeriodic = nextPeriodic
            self.deadline = deadline
            self.interval = interval
        }

        mutating func next() -> Date? {
            guard !finished else { return nil }
            let candidate = Swift.min(nextPeriodic, deadline ?? .distantFuture)
            if nextPeriodic <= candidate {
                nextPeriodic = nextPeriodic.addingTimeInterval(interval)
            }
            if let deadline, deadline <= candidate {
                finished = true
            }
            return candidate
        }
    }
}
