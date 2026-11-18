import SwiftUI

/// 프로바이더 카드의 공유 이미지 — 머리글 + 계정 섹션(전체 또는 계정 하나).
/// 폭·불투명 바탕(`ImageRenderer`에는 창 바탕이 없음)·강제 모양을 스스로 지정.
struct ShareCardView: View {
    let family: DashboardFamily
    var plans: [String: String] = [:]
    let appearance: ColorScheme
    /// 이메일 계정명은 생략하고 Privacy Mode가 켜지면 별명도 흐리게 표시.
    var blursAccountNames = false
    var layoutStyle = DashboardLayoutStyle.minimal

    static let width: CGFloat = 360
    static let inset: CGFloat = 16

    var body: some View {
        ShareCardFrame(appearance: appearance, blursAccountNames: blursAccountNames) {
            DashboardProviderSection(family: family.forSharing, layoutStyle: layoutStyle) { account in
                DashboardAccountRows(
                    account: account, plan: plans[account.id], layoutStyle: layoutStyle, showsEmptyMessage: true
                )
            }
        }
    }
}

/// Priority 탭의 공유 이미지 — 탭 막대 없이 목록만.
struct PriorityShareCard: View {
    let board: PriorityBoard
    let now: Date
    let appearance: ColorScheme
    var blursAccountNames = false

    var body: some View {
        ShareCardFrame(appearance: appearance, blursAccountNames: blursAccountNames) {
            PriorityBoardList(board: board, now: now)
        }
    }
}

/// 공유 이미지 공통 틀 — 패널 바탕, 막대는 도형, 하단 브랜드 띠.
/// AppKit 기준 뷰가 노란 상자로 그려지지 않도록 툴팁 비활성화.
struct ShareCardFrame<Content: View>: View {
    let appearance: ColorScheme
    var blursAccountNames = false
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            content
                .padding(ShareCardView.inset)
            watermarkFooter
        }
        .frame(width: ShareCardView.width, alignment: .topLeading)
        .background(Theme.panelBody)
        .environment(\.drawsLevelsAsShapes, true)
        .environment(\.concealsAccountNames, blursAccountNames)
        .environment(\.hoverTooltipsDisabled, true)
        .environment(\.colorScheme, appearance)
    }

    private var watermarkFooter: some View {
        HStack(spacing: 6) {
            ProviderIcon(source: .providerMark("egasu"), inset: 0)
                .frame(width: 16, height: 16)
            Text("egasu")
                .font(.system(size: 13, weight: .semibold))
            Spacer(minLength: 8)
            Text(L10n.dashboard("Monitor Your AI Subscriptions"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, ShareCardView.inset)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(Theme.cardFill)
        .overlay(alignment: .top) { Rectangle().fill(.separator).frame(height: 0.5) }
    }
}
