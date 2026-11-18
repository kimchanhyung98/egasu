import AppKit
import SwiftUI

/// All Usage 격자 치수·글꼴 단일 출처 — 라벨 90 · 막대 · 값 52 · 초기화 56/64(시각 80), 행 높이 22.
enum DashboardGrid {
    static let cardPadding = Theme.Spacing.xl
    static let cardTopPadding = Theme.Spacing.m
    static let cardBottomPadding = Theme.Spacing.l
    static let headerGap = Theme.Spacing.xs
    static let sectionSpacing = Theme.Spacing.xxl
    static let accountSpacing = Theme.Spacing.m
    static let captionGap = Theme.Spacing.xs
    static let columnGap = Theme.Spacing.m
    static let rowHeight: CGFloat = 22
    static let levelHeight: CGFloat = 9
    static let chartHeight: CGFloat = 14
    static let labelWidth: CGFloat = 90
    static let valueWidth: CGFloat = 52
    static var resetWidth: CGFloat {
        switch L10n.language {
        case .english: 56
        case .korean, .japanese: 64
        }
    }
    static let clockResetWidth: CGFloat = 80

    static let headerFont: Font = .system(size: 15, weight: .semibold)
    static let planFont: Font = .system(size: 10, weight: .medium)
    static var planNSFont: NSFont { .systemFont(ofSize: 11) }
    static let planPadding: CGFloat = 5
    static let captionFont: Font = .system(size: 11, weight: .semibold)

    static let headerHeight: CGFloat = 24
    static let captionHeight = NSLayoutManager().defaultLineHeight(for: planNSFont).rounded(.up)
    static let iconSize: CGFloat = 16
}

/// 계정의 지표를 위에서 아래로 배치 — 첫 수신 전에는 지표마다 대기 행 표시.
struct DashboardLineStack<Row: View>: View {
    let account: DashboardAccount
    var layoutStyle = DashboardLayoutStyle.minimal
    @ViewBuilder let row: (DashboardLine) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(account.lines) { row($0) }
            if !account.waitingMetricIDs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(account.waitingMetricIDs, id: \.self) { _ in SkeletonMetricRow(layoutStyle: layoutStyle) }
                }
                .accessibilityElement()
                .accessibilityLabel(L10n.dashboard("Waiting for Usage"))
            }
        }
    }
}

/// 막대·값·초기화 자리를 회색 캡슐로 그린 대기 행.
private struct SkeletonMetricRow: View {
    let layoutStyle: DashboardLayoutStyle

    var body: some View {
        Group {
            if layoutStyle == .cards {
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().frame(width: 54, height: 8)
                    Capsule().frame(height: 5)
                    HStack {
                        Capsule().frame(width: 45, height: 7)
                        Spacer()
                        Capsule().frame(width: 80, height: 7)
                    }
                }
                .padding(.vertical, 8)
            } else {
                HStack(spacing: DashboardGrid.columnGap) {
                    Capsule().frame(width: 54, height: 8)
                        .frame(width: DashboardGrid.labelWidth, alignment: .leading)
                    Capsule().frame(height: DashboardGrid.levelHeight)
                    Capsule().frame(width: 30, height: 8)
                        .frame(width: DashboardGrid.valueWidth, alignment: .trailing)
                    Capsule().frame(width: 30, height: 7)
                        .frame(width: DashboardGrid.resetWidth, alignment: .trailing)
                }
                .frame(height: DashboardGrid.rowHeight)
            }
        }
        .skeleton()
    }
}

/// Usage Trend 일별 막대 — 최고값에 비례한 높이, 0인 날은 짧은 막대 유지.
struct TrendBars: View {
    let points: [MetricChartPoint]
    var height: CGFloat = DashboardGrid.chartHeight

    var body: some View {
        let maxValue = max(1, points.map(\.value).max() ?? 1)
        HStack(alignment: .bottom, spacing: 1) {
            // 일자 라벨을 키로 — 새로고침 때 위치 기반 재매핑 방지.
            ForEach(points, id: \.label) { point in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Theme.severityColor(.normal))
                    .frame(minWidth: 1.5, maxWidth: .infinity)
                    .frame(height: barHeight(point.value, max: maxValue))
            }
        }
        .frame(height: height, alignment: .bottom)
    }

    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        guard value > 0 else { return 2 }
        return Swift.max(height * 0.18, height * min(1, value / maxValue))
    }
}
