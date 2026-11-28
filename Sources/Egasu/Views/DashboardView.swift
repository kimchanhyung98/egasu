import SwiftUI

/// 패널 콘텐츠 루트 — Dashboard·Accounts·Settings 전환과 패널 높이를 같은 애니메이션으로 구동.
struct DashboardView: View {
    @Environment(AppContainer.self) private var container
    @Environment(LayoutStore.self) private var layout
    @Environment(PopoverState.self) private var popover
    @Environment(AccountRenameStore.self) private var renaming
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var settingsOperations: SettingsOperations
    @State private var reorderLift: ReorderLift?
    @State private var heightPath = PanelHeightPath()
    @State private var heightPresentation = PanelHeightPresentation()
    @State private var heightMotion = 0
    @State private var measuredIdeal = MeasuredPanelHeights()
    @State private var openingSlideID: Int?
    @State private var slideProgress: CGFloat = 1
    @State private var animatedSlideID = 0
    /// 전환을 마친 화면 ID — 완료 전까지 두 화면을 유지하여 떠나는 화면과 바를 함께 이동.
    /// 스프링 시작 시 slideProgress의 목표값은 이미 1이므로 전환 완료 판정에 사용하지 않음.
    @State private var settledSlideID = 0
    @State private var dashboardScrollPosition = ScrollPosition(edge: .top)
    private static let reorderSpace = "popoverReorderSpace"

    init(settingsOperations: SettingsOperations = SettingsOperations()) {
        _settingsOperations = State(initialValue: settingsOperations)
    }

    var body: some View {
        modeBody
            .frame(width: PanelMetrics.width)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Theme.panelBody)
            .accountRenameErrorAlert(renaming: renaming, isPopoverShown: popover.popoverShown)
            // `.animation(nil, ...)` 밖에서 패널 높이를 구동하여 화면 이동과 애니메이션 동기화.
            .background {
                Color.clear
                    .modifier(
                        PanelHeightModifier(
                            path: heightPath, progress: slideProgress, motion: heightMotion,
                            presentation: heightPresentation
                        )
                    )
                    .id(heightMotion)
                    .transition(.identity)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
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
            .onChange(of: popover.popoverShown, initial: true) { wasShown, shown in
                if shown {
                    openingSlideID = popover.screenSlideID
                    settledSlideID = popover.screenSlideID
                    if let target = heightTarget(for: popover.screen) {
                        heightPath = PanelHeightPath(start: target, end: target)
                    }
                } else if wasShown {
                    resetTransientState()
                }
            }
            // 화면 전환 중 드래그가 해제되면 onEnded가 오지 않으므로 미리보기 직접 정리.
            .onChange(of: popover.screen) {
                reorderLift = nil
                layout.cancelDrag()
            }
            .onChange(of: Navigation(slide: popover.screenSlideID, detail: popover.accountDetailID)) { old, new in
                reorderLift = nil
                guard popover.popoverShown else { return }
                let screenChanged = old.slide != new.slide
                if !screenChanged, isSliding { return }
                beginNavigation(animate: !reduceAnimations && !(screenChanged && new.slide == openingSlideID))
            }
            // 시작 프레임이 뷰에 반영된 뒤 같은 진행률로 화면과 패널 높이 이동.
            .onChange(of: heightMotion) {
                guard popover.popoverShown, slideProgress == 0 else { return }
                let slide = popover.screenSlideID
                withAnimation(Motion.navigation, completionCriteria: .removed) {
                    slideProgress = 1
                } completion: {
                    guard popover.isShowingSlide(slide) else { return }
                    settledSlideID = slide
                }
            }
            .onChange(of: heightTarget(for: popover.screen)) { _, target in
                guard popover.popoverShown, let target else { return }
                updateHeightTarget(target)
            }
    }

    private struct Navigation: Equatable {
        let slide: Int
        let detail: String?
    }

    private func updateHeightTarget(_ target: CGFloat) {
        guard target != heightPath.end else { return }
        let frame = heightPresentation.current
        let start = frame.progress == 0 ? heightPath.start : frame.height
        guard frame.progress < 1, start > 0, !reduceAnimations else {
            heightMotion = heightPresentation.settle(at: target)
            heightPath = PanelHeightPath(start: target, end: target)
            return
        }
        heightPath = PanelHeightPath(start: start, end: target, startProgress: frame.progress)
    }

    private func beginNavigation(animate: Bool) {
        let frame = heightPresentation.restart()
        let start = MenuBarPopover.presentedHeight?() ?? (frame.height > 0 ? frame.height : heightPath.end)
        let target = heightTarget(for: popover.screen) ?? start
        let slide = popover.screenSlideID
        // 표시된 높이를 시작점으로 사용하고 이전 움직임의 보간이 새 진행률에 섞이지 않도록 효과만 교체.
        withAnimation(nil) {
            heightMotion = frame.motion
            animatedSlideID = slide
            heightPath = PanelHeightPath(start: animate && start > 0 ? start : target, end: target)
            slideProgress = animate ? 0 : 1
            if !animate {
                heightPresentation.present(target, at: 1, motion: frame.motion)
                settledSlideID = slide
            }
        }
    }

    private func resetTransientState() {
        // 닫힌 패널은 포인터 이탈을 알리지 않으므로 남은 툴팁·호버 팝오버 정리.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        ReducedMotionPopoverController.dismissAll()
        // 닫힐 때 열린 이름 편집은 저장 — 포커스 이탈이 오지 않음.
        renaming.commit()
        popover.reset()
        reorderLift = nil
        layout.cancelDrag()
        // 다음 열기에서 새 높이를 애니메이션 없이 적용하도록 미설정 값 0으로 초기화.
        heightMotion = heightPresentation.restart().motion
        heightPath = PanelHeightPath()
        slideProgress = 1
        settledSlideID = popover.screenSlideID
        openingSlideID = nil
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
        let detail = popover.displayedAccountDetail(on: screen)
        let footer = PopoverFooter(screen: screen, accountDetailID: detail)
        let hasFooter = footer != nil
        let tab = popover.dashboardTab
        scrollBody(for: screen, accountDetailID: detail)
            .onScrollGeometryChange(for: PanelPageMeasurement?.self) { geometry in
                PanelPageMeasurement(screen: screen, tab: tab, detail: detail, hasFooter: hasFooter, geometry: geometry)
            } action: { _, measurement in
                if let measurement, measurement.height > 0 {
                    measuredIdeal[screen, measurement.tab, measurement.detail] = measurement.height
                }
            }
            .panelBars {
                PopoverTopBar(screen: screen, accountDetailID: detail)
                    .animation(accountPageAnimation, value: detail)
            } bottom: {
                footer
            }
            // 전환 중 두 페이지도 각 화면의 범위 유지 — Accounts 본문·상단 바·확인창은 항상 원문.
            .environment(\.concealsAccountNames, AccountNamePrivacy.concealsAccountNames(
                on: screen, isEnabled: container.privacy.hideUsageWhileScreenSharing
            ))
    }

    private var accountPageAnimation: Animation? {
        isSliding || reduceAnimations ? nil : Motion.navigation
    }

    private func heightTarget(for screen: PopoverScreen) -> CGFloat? {
        measuredIdeal[screen, popover.dashboardTab, popover.accountDetailID].map {
            MenuBarPopover.clampHeight?($0) ?? $0
        }
    }

    @ViewBuilder
    private func scrollBody(for screen: PopoverScreen, accountDetailID: String?) -> some View {
        switch screen {
        case .dashboard:
            DashboardContentView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift,
                scrollPosition: $dashboardScrollPosition
            )
        case .accounts:
            AccountsView(
                reorderSpaceName: Self.reorderSpace,
                reorderLift: $reorderLift,
                pageAnimation: accountPageAnimation,
                accountDetailID: accountDetailID
            )
        case .settings:
            SettingsScreen(operations: settingsOperations)
                .environment(container.iCloudSync)
                .environment(container.usageTimerSetting)
                .environment(container.notificationSettings)
        }
    }
}
