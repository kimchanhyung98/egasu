import SwiftUI

/// Total Spend 공유용 PNG — 공통 링을 별도 이미지로 렌더링.
/// 본문은 `TotalSpendRingContent` 재사용으로 팝오버 표시와 동일한 링·범례 보장.
struct TotalSpendShareCardView: View {
    let total: TotalSpend
    let metric: TotalSpendMetric
    let appearance: ColorScheme

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        ShareCardFrame(appearance: appearance) {
            VStack(alignment: .leading, spacing: DashboardGrid.headerGap) {
                headerRow
                    .padding(.horizontal, DashboardGrid.cardPadding)
                    .frame(height: DashboardGrid.headerHeight)
                TotalSpendRingContent(projection: projection)
                    .padding(DashboardGrid.cardPadding)
                    .frame(maxWidth: .infinity)
                    .cardSurface()
            }
        }
    }

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(metric.title)
                .font(DashboardGrid.headerFont)
                .foregroundStyle(.primary)
            Text(L10n.metrics(total.period.rawValue))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }
}
