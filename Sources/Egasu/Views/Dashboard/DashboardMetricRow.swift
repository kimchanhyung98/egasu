import SwiftUI

/// 격자 행 한 줄 — 막대 행(라벨 · 막대 · 값 · 초기화), 값 행(라벨 ··· 값), 차트 행(라벨 · 일별 막대).
struct DashboardMetricRow: View {
    let model: DashboardRowModel
    var chartPoints: [MetricChartPoint] = []
    var layoutStyle = DashboardLayoutStyle.minimal
    var onToggleMeterStyle: (() -> Void)?
    var onToggleResetDisplay: (() -> Void)?
    var paceTooltip: String?
    var valueTooltip: String?
    var resetTooltip: String?
    /// 값·차트에 호버 상세를 연결하는 영역 — 기본은 원래 뷰 유지.
    var figure: (AnyView) -> AnyView = { $0 }

    static let font: Font = .system(size: 12)
    static let resetFont: Font = .system(size: 11)

    var body: some View {
        Group {
            switch model.mark {
            case .bar(let fill, let severity, let value, let reset, let isUsedUp):
                Group {
                    if layoutStyle == .cards {
                        VStack(alignment: .leading, spacing: 4) {
                            label
                            level(fill: fill, severity: severity)
                                .frame(height: 5)
                            HStack(alignment: .firstTextBaseline, spacing: DashboardGrid.columnGap) {
                                valueText(model.cardValue ?? value, severity: severity)
                                Spacer(minLength: 0)
                                resetText(model.cardReset ?? reset, isUsedUp: isUsedUp)
                                    .multilineTextAlignment(.trailing)
                            }
                            .font(Self.resetFont)
                        }
                        .padding(.vertical, 6)
                    } else {
                        HStack(spacing: DashboardGrid.columnGap) {
                            label
                                .frame(width: DashboardGrid.labelWidth, alignment: .leading)
                            level(fill: fill, severity: severity)
                                .frame(height: DashboardGrid.levelHeight)
                            valueText(value, severity: severity)
                                .frame(width: DashboardGrid.valueWidth, alignment: .trailing)
                            resetText(reset, isUsedUp: isUsedUp)
                                .frame(
                                    width: model.showsClockTimes
                                        ? DashboardGrid.clockResetWidth : DashboardGrid.resetWidth, alignment: .trailing
                                )
                        }
                    }
                }
                .opacity(model.isFaded ? 0.5 : 1)
            case .value(let text, let detail, let severity):
                HStack(alignment: .firstTextBaseline, spacing: DashboardGrid.columnGap) {
                    label
                    Spacer(minLength: 0)
                    figure(
                        AnyView(
                            HStack(alignment: .firstTextBaseline, spacing: 0) {
                                Text(text)
                                    .foregroundStyle(Self.figureStyle(severity))
                                if let detail {
                                    Text(" · \(detail)")
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .monospacedDigit()
                            .lineLimit(1)
                            .contentTransition(.numericText())
                            .fixedSize()
                            .hoverTooltip(valueTooltip)
                            .accessibilityValue(Self.expiryAccessibilityValue(severity) ?? "")
                        ))
                }
            case .chart:
                if layoutStyle == .cards {
                    VStack(alignment: .leading, spacing: 4) {
                        label
                        figure(AnyView(TrendBars(points: chartPoints, height: 18).hoverTooltip(valueTooltip)))
                    }
                    .padding(.vertical, 6)
                } else {
                    HStack(spacing: DashboardGrid.columnGap) {
                        label
                            .frame(width: DashboardGrid.labelWidth, alignment: .leading)
                        figure(
                            AnyView(
                                TrendBars(points: chartPoints)
                                    .frame(maxWidth: .infinity)
                                    .hoverTooltip(valueTooltip)
                            ))
                    }
                }
            }
        }
        .font(Self.font)
        .frame(maxWidth: .infinity, minHeight: DashboardGrid.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var label: some View {
        Text(model.label)
            .font(layoutStyle == .cards ? .system(size: 13, weight: .semibold) : Self.font)
            .lineLimit(1)
    }

    private func level(fill: Double, severity: WidgetData.MeterSeverity) -> some View {
        LevelIndicator(fill: fill, severity: severity, paceMark: model.paceMark, softLimitMark: model.softLimitMark)
            .hoverTooltip(paceTooltip)
    }

    /// 값은 경고 전까지 행 기본 색.
    private static func figureStyle(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        switch severity {
        case .neutral, .normal: AnyShapeStyle(.primary)
        case .warning, .critical: AnyShapeStyle(Theme.severityTextColor(severity))
        }
    }

    private static func amountStyle(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        switch severity {
        case .neutral, .normal: AnyShapeStyle(.secondary)
        case .warning, .critical: AnyShapeStyle(Theme.severityTextColor(severity))
        }
    }

    static func expiryAccessibilityValue(_ severity: WidgetData.MeterSeverity) -> String? {
        switch severity {
        case .neutral, .normal: nil
        case .warning: L10n.dashboard("a reset expires within 7 days")
        case .critical: L10n.dashboard("a reset expires within 48 hours")
        }
    }

    @ViewBuilder
    private func valueText(_ value: String, severity: WidgetData.MeterSeverity) -> some View {
        let text = Text(value)
            .foregroundStyle(layoutStyle == .cards ? Self.figureStyle(severity) : Self.amountStyle(severity))
            .monospacedDigit()
            .lineLimit(1)
            .contentTransition(.numericText())
            .fixedSize()
        if let onToggleMeterStyle {
            Button(action: onToggleMeterStyle) { text }
                .buttonStyle(.plain)
                .hoverTooltip(valueTooltip)
        } else {
            text
                .hoverTooltip(valueTooltip)
        }
    }

    /// 초기화가 없으면 빈칸 — 이웃 행과 막대 길이 유지.
    @ViewBuilder
    private func resetText(_ reset: String?, isUsedUp: Bool) -> some View {
        let text = Text(reset ?? "")
            .font(Self.resetFont)
            .foregroundStyle(Self.amountStyle(isUsedUp ? .critical : .normal))
            .monospacedDigit()
            .lineLimit(layoutStyle == .cards ? nil : 1)
            .fixedSize(horizontal: layoutStyle == .minimal, vertical: true)
        if reset != nil, let onToggleResetDisplay {
            Button(action: onToggleResetDisplay) { text }
                .buttonStyle(.plain)
                .hoverTooltip(resetTooltip)
        } else {
            text
                .hoverTooltip(resetTooltip)
        }
    }
}
