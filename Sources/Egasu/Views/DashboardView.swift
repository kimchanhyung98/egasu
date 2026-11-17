import SwiftUI

/// 패널 콘텐츠 루트 — Dashboard·Accounts·Settings 전환과 패널 높이를 같은 애니메이션으로 구동.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(UpdaterController.self) private var updater
    @Environment(PopoverState.self) private var popover
    @Environment(AccountRenameStore.self) private var renaming
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var reorderLift: ReorderLift?
    /// SwiftUI가 구동하는 패널 높이 — 0이면 첫 측정 전까지 패널 제어기가 정한 크기 유지.
    @State private var animatedHeight: CGFloat = 0
    @State private var didEstablishHeight = false
    @State private var measuredIdeal = MeasuredPanelHeights()
    @State private var isOpening = false
    @State private var slideProgress: CGFloat = 1
    @State private var animatedSlideID = 0
    /// 전환을 마친 화면 ID — 완료 전까지 두 화면을 유지하여 떠나는 화면과 바를 함께 이동.
    /// 스프링 시작 시 slideProgress의 목표값은 이미 1이므로 전환 완료 판정에 사용하지 않음.
    @State private var settledSlideID = 0
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    private static let reorderSpace = "popoverReorderSpace"

    var body: some View {
        modeBody
            .frame(width: PanelMetrics.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panelBody)
            .accountRenameErrorAlert(renaming: renaming, isPopoverShown: popover.popoverShown)
            // `.animation(nil, ...)` 밖에서 패널 높이를 구동하여 화면 이동과 애니메이션 동기화.
            .drivesPanelHeight(animatedHeight)
            .overlay(alignment: .topLeading) {
                if let reorderLift {
                    ReorderLiftPreview(lift: reorderLift)
                        .environment(\.concealsAccountNames, AccountNamePrivacy.concealsAccountNames(
                            on: popover.screen, isEnabled: container.privacy.hideUsageWhileScreenSharing
                        ))
                }
            }
            .coordinateSpace(name: Self.reorderSpace)
            .background(
                // Esc는 한 단계 복귀하고 대시보드에서는 패널 닫기. Return은 Accounts 진입·한 단계 복귀만 수행.
                PopoverKeyReader(
                    onEscape: { popover.back() },
                    onReturn: {
                        guard popover.screen == .dashboard else { return popover.back() }
                        popover.toggle(.accounts)
                        return true
                    },
                    // ⌘,는 모든 화면에서 Settings 토글 — Options 메뉴 항목의 ⌘, 라벨과 이중 등록 충돌 방지.
                    onSettings: {
                        popover.toggle(.settings)
                        return true
                    },
                    // ⌘Z는 마지막 레이아웃 변경 취소 — 취소할 변경이 없으면 소리 없이 무시.
                    onUndo: {
                        guard layout.canUndo else { return true }
                        withAnimation(Motion.spring) { _ = layout.undo() }
                        return true
                    }
                )
            )
            .onChange(of: popover.popoverShown) { _, shown in
                if shown {
                    // 닫힌 뒤에도 SwiftUI 뷰가 유지되므로 다시 열 때 현재 높이를 애니메이션 없이 설정.
                    if let target = heightTarget(for: popover.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                    isOpening = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        isOpening = false
                    }
                } else {
                    resetTransientState()
                }
            }
            // 화면 전환 중 드래그가 해제되면 onEnded가 오지 않으므로 미리보기 직접 정리.
            .onChange(of: popover.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            .onChange(of: popover.accountDetailID) { reorderLift = nil }
            // 전환마다 시작 위치를 먼저 적용하고 다음 실행 순서에서 애니메이션 시작 — 한 클로저의 연속 변경은 병합 가능.
            .onChange(of: popover.screenSlideID) { _, id in
                guard id != 0 else { return }
                if reduceAnimations {
                    animatedSlideID = id
                    settledSlideID = id
                    slideProgress = 1
                    if let target = heightTarget(for: popover.screen) {
                        didEstablishHeight = true
                        animatedHeight = target
                    }
                    return
                }
                slideProgress = 0
                animatedSlideID = id
                let destination = popover.screen
                Task { @MainActor in
                    let coTarget: CGFloat? = heightTarget(for: destination)
                        ?? (animatedHeight > 0 ? animatedHeight : nil)
                    if coTarget != nil { didEstablishHeight = true }
                    withAnimation(Motion.navigation, completionCriteria: .removed) {
                        slideProgress = 1
                        if let coTarget { animatedHeight = coTarget }
                    } completion: {
                        settledSlideID = id
                        guard let target = heightTarget(for: popover.screen) else { return }
                        if !didEstablishHeight {
                            didEstablishHeight = true
                            animatedHeight = target
                        } else if abs(target - animatedHeight) > 1 {
                            withAnimation(Motion.navigation) { animatedHeight = target }
                        }
                    }
                }
            }
            // macOS 15에서 바 여백 적용 전에 측정될 수 있으므로 전환 중에도 보정된 높이 반영.
            .onChange(of: measuredIdeal[popover.screen, popover.dashboardTab]) { _, _ in
                guard let target = heightTarget(for: popover.screen) else { return }
                if !didEstablishHeight {
                    didEstablishHeight = true
                    animatedHeight = target
                } else if isOpening || !isSliding {
                    // 화면 전환 중이 아니면 새 높이 즉시 적용.
                    animatedHeight = target
                } else if abs(target - animatedHeight) > 1 {
                    withAnimation(Motion.navigation) { animatedHeight = target }
                }
            }
    }

    private func resetTransientState() {
        // 닫힌 패널은 포인터 이탈을 알리지 않으므로 남은 툴팁·호버 팝오버 정리.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        // 닫힐 때 열린 이름 편집은 저장 — 포커스 이탈이 오지 않음.
        renaming.commit()
        layout.clearShareConfirmation()
        popover.reset()
        reorderLift = nil
        layout.cancelDrag()
        // 다음 열기에서 새 높이를 애니메이션 없이 적용하도록 미설정 값 0으로 초기화.
        animatedHeight = 0
        didEstablishHeight = false
        dashboardScrollPosition.scrollTo(edge: .top)
    }

    /// 수평 화면 배치 — 평소 한 화면, 전환 중 두 화면을 위치 이동으로 표시.
    /// 반투명 카드의 깜빡임을 방지하도록 불투명도 전환 없이 위치만 이동.
    private var modeBody: some View {
        let pages = slidePages
        return HStack(alignment: .top, spacing: 0) {
            ForEach(pages, id: \.self) { screen in
                screenView(screen)
                    .frame(width: PanelMetrics.width)
                    .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: PanelMetrics.width, alignment: .leading)
        .offset(x: slideOffset(pages))
        .animation(nil, value: popover.screenSlideID)
    }

    private var isSliding: Bool {
        Self.screenTransitionIsActive(
            reduceAnimations: reduceAnimations,
            screenSlideID: popover.screenSlideID,
            settledSlideID: settledSlideID
        )
    }

    static func screenTransitionIsActive(
        reduceAnimations: Bool,
        screenSlideID: Int,
        settledSlideID: Int
    ) -> Bool {
        !reduceAnimations
            && screenSlideID != 0
            && screenSlideID != settledSlideID
    }

    private var slidePages: [PopoverScreen] {
        guard isSliding else { return [popover.screen] }
        let from = popover.screenSlideFrom
        let to = popover.screen
        return from.slideRank < to.slideRank ? [from, to] : [to, from]
    }

    private func slideOffset(_ pages: [PopoverScreen]) -> CGFloat {
        guard isSliding, pages.count > 1 else { return 0 }
        let fromOffset = -CGFloat(pages.firstIndex(of: popover.screenSlideFrom) ?? 0) * PanelMetrics.width
        let toOffset = -CGFloat(pages.firstIndex(of: popover.screen) ?? 0) * PanelMetrics.width
        let progress = animatedSlideID == popover.screenSlideID ? slideProgress : 0
        return fromOffset + progress * (toOffset - fromOffset)
    }

    @ViewBuilder
    private func screenView(_ screen: PopoverScreen) -> some View {
        scrollBody(for: screen)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
            } action: { _, height in
                if height > 0 { measuredIdeal[screen, popover.dashboardTab] = height }
            }
            .panelBars {
                PopoverTopBar(screen: screen)
            } bottom: {
                PopoverFooter(screen: screen)
            }
            // 전환 중 두 페이지도 각 화면의 범위 유지 — Accounts 본문·상단 바·확인창은 항상 원문.
            .environment(\.concealsAccountNames, AccountNamePrivacy.concealsAccountNames(
                on: screen, isEnabled: container.privacy.hideUsageWhileScreenSharing
            ))
    }

    private func heightTarget(for screen: PopoverScreen) -> CGFloat? {
        measuredIdeal[screen, popover.dashboardTab].map { MenuBarPopover.clampHeight?($0) ?? $0 }
    }

    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                container: container,
                layout: layout,
                updater: updater,
                reorderSpaceName: Self.reorderSpace,
                horizontalPadding: PanelMetrics.margin,
                bottomGap: PanelMetrics.margin,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .accounts:
            AccountsView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift
            )
        case .settings:
            SettingsScreen(reorderSpaceName: Self.reorderSpace, reorderLift: $reorderLift)
        }
    }
}
