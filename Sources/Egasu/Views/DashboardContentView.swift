import SwiftUI

/// 대시보드 스크롤 내용 — 업데이트 배너·공통 사용량 요약·All Usage.
/// 화면 전환·패널 크기·바·키보드·닫기 처리는 `DashboardView` 소관.
struct DashboardContentView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @Environment(UpdaterController.self) private var updater
    let reorderSpaceName: String

    @Binding var reorderLift: ReorderLift?
    @Binding var scrollPosition: ScrollPosition

    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true
    @State private var retainedResetClaims: [String: CodexResetClaimBinding] = [:]

    /// 내용과 옆 바가 각각 가지는 간격 — 둘을 합친 값이 바와 내용 사이 간격.
    static let barGap: CGFloat = 7

    var body: some View {
        PopoverScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 자동 확인에서 발견한 업데이트를 상단 배너로 표시 — Dock 없는 앱의 Sparkle 창이 가려지는 상황 방지.
                if let updateVersion = updater.availableUpdateVersion {
                    UpdateBannerCard(version: updateVersion)
                        .padding(.bottom, PanelMetrics.sectionSpacing)
                        .transition(.scale(scale: 0.95).combined(with: .opacity))
                }
                if hasEnabledProvider, showTotalSpend, layout.hasSpendCapableProvider {
                    TotalSpendCard()
                        .padding(.bottom, PanelMetrics.sectionSpacing)
                }
                widgetContent
            }
            .animation(Motion.spring, value: updater.availableUpdateVersion)
            .padding(.horizontal, PanelMetrics.margin)
            .padding(.top, PanelMetrics.margin)
            .padding(.bottom, Self.barGap)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollPosition($scrollPosition)
        .onChange(of: popover.dashboardTab) { scrollPosition.scrollTo(edge: .top) }
    }

    @ViewBuilder
    private var widgetContent: some View {
        if !hasEnabledProvider {
            EmptyDashboardView { popover.openAccounts(nil) }
        } else {
            allUsageContent
        }
    }

    @ViewBuilder
    private var allUsageContent: some View {
        let families = container.dashboardFamilies(retainingResetClaims: retainedResetClaims)
        if families.isEmpty {
            hiddenMetricsNotice
        } else {
            WidgetGroupedListView(
                families: families,
                reorderSpaceName: reorderSpaceName,
                reorderLift: $reorderLift,
                retainedResetClaims: $retainedResetClaims
            )
        }
    }

    private var hiddenMetricsNotice: some View {
        Text(L10n.dashboard("No usage to show. Check visible metrics in Accounts."))
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }

    /// 켜진 프로바이더가 하나라도 있는지 — 없으면 계정 추가 빈 상태.
    private var hasEnabledProvider: Bool {
        layout.registry.providers.contains { container.enablement.isEnabled($0.id) }
    }
}
