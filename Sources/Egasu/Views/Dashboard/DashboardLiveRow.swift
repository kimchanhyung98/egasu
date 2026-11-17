import SwiftUI

/// 대시보드 행 — 초기화·만료·예측 기한이 있으면 30초마다, 예측 기한에는 정확히 다시 그림(네트워크 요청 없음).
/// 모델별 사용 내역과 초기화권은 기존 호버 상세 사용 — 상세 교체 전까지 같은 조회·사용 요청 경로 유지.
struct DashboardLiveRow: View {
    let line: DashboardLine
    var layoutStyle = DashboardLayoutStyle.minimal
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?

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
        .onChange(of: line.data.modelBreakdown) { _, _ in hover.dismiss() }
        .onChange(of: line.data.chartPoints) { _, _ in hover.dismiss() }
        // 초기화권 사용이 강제 새로고침을 일으키므로 고정 중이면 결과 배너를 위해 유지.
        .onChange(of: line.data.expiriesAt) { _, _ in
            if !hover.isPinned { hover.dismiss() }
        }
        .onDisappear { hover.dismiss() }
    }

    private var needsClock: Bool {
        line.data.resetsAt != nil || !line.data.expiriesAt.isEmpty || line.data.forecastDeadline != nil
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

    var hasDetail: Bool {
        line.data.hasModelBreakdown || (line.data.showsResetExpiries && line.data.hasData)
            || (line.data.isChart && line.data.hasData && !line.data.chartPoints.isEmpty)
    }

    private var figure: (AnyView) -> AnyView {
        guard hasDetail else { return { $0 } }
        return { AnyView(hoverTrigger($0)) }
    }

    private func hoverTrigger(_ figure: AnyView) -> some View {
        let lit = hover.overInline || hover.isPresented
        return
            figure
            .hoverHighlight(lit)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active = phase { hover.inlineHover(true) } else { hover.inlineHover(false) }
            }
            .popover(
                isPresented: Binding(
                    get: { hasDetail && hover.isPresented },
                    set: { if !$0 { hover.dismiss() } }
                ),
                arrowEdge: .top
            ) { detail }

    }

    @ViewBuilder
    private var detail: some View {
        let data = line.data
        if let breakdown = data.modelBreakdown {
            ModelUsageDetail(title: data.localizedTitle, breakdown: breakdown) { inside in
                hover.detailHover(inside)
            }
        } else if data.isChart {
            UsageTrendDetail(title: data.localizedTitle, points: data.chartPoints, note: data.chartNote) { inside in
                hover.detailHover(inside)
            }
        } else if data.showsResetExpiries {
            RateLimitResetsDetail(
                count: data.resetCreditCount, expiries: data.expiriesAt,
                onHoverChange: { inside in hover.detailHover(inside) },
                onPinChange: { pinned in hover.setPinned(pinned) },
                claimBinding: data.codexResetClaimBinding,
                claim: resetClaimAction
            )
        }
    }

    private var resetClaimAction: ((Date, String) async -> ResetClaimOutcome)? {
        guard let binding = line.data.codexResetClaimBinding,
            let providerID = line.data.providerID
        else { return nil }
        return codexResetClaim?.claimAction(for: providerID, binding: binding)
    }
}
