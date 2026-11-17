import SwiftUI

/// 우클릭 "Share Screenshot" 액션용 프로바이더 사용량 오프스크린 PNG.
/// 전달된 계정 지표를 저장 순서대로 ×4 래스터화.
/// 환경 의존 없는 `[WidgetData]` 입력 — 앱·테스트에서 동일 렌더 보장.
struct ShareCardView: View {
    let provider: Provider
    var plan: String?
    let rows: [WidgetData]
    let appearance: ColorScheme
    /// 세션 중 rename된 라이브 카드 제목. `ImageRenderer`는 앱 environment 밖이라 명시 전달 필수.
    var displayNameOverride: String? = nil

    /// 저작 카드 폭 (pt). 렌더러가 `ShareCardRenderer.scale` 배율 적용, 높이는 행 합산으로 가변.
    static let width: CGFloat = 360

    var body: some View {
        ShareCardChrome(appearance: appearance) {
            headerRow
            metricsCard
        }
    }

    // MARK: - Header

    private var headerRow: some View {
        HStack(spacing: 10) {
            ProviderIcon(source: provider.icon, inset: 0.04)
                .frame(width: 22, height: 22)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(displayNameOverride ?? provider.displayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - Body

    /// 계정 지표의 정적 렌더. 빈 계정은 안내 문구 표시.
    @ViewBuilder
    private var metricsCard: some View {
        if rows.isEmpty {
            DashboardMetricCard {
                Text(L10n.dashboard("No metrics to show"))
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
            }
        } else {
            DashboardMetricCard {
                let condensed = WidgetData.condensedTextRowOffsets(in: rows)
                ForEach(Array(rows.enumerated()), id: \.offset) { index, data in
                    WidgetRowView(data: data, condensedTop: condensed.contains(index))
                }
            }
        }
    }
}
