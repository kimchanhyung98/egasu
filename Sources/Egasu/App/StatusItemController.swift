import AppKit
import KeyboardShortcuts
import SwiftUI

/// 키 입력을 받을 수 있는 테두리 없는 비활성화 대시보드 패널.
/// NSPopover는 앱 활성화 후에만 키 창이 되므로 비동기·거부 가능한 LSUIElement 활성화에서 첫 입력 유실 가능.
/// `canBecomeKey`가 true인 `.nonactivatingPanel`로 앱 활성화 없이 첫 키 입력 수신.
class MenuBarPanel: NSPanel {
    static let cornerRadius: CGFloat = 20

    /// 투명한 테두리 없는 패널 — 둥근 모서리는 프레임 뷰에서 처리.
    /// 시트의 어두운 배경이 콘텐츠 뷰의 형제이므로 프레임 뷰 마스크로 함께 잘라내기.
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        guard let frameView = contentView?.superview else { return }
        frameView.wantsLayer = true
        frameView.layer?.cornerRadius = Self.cornerRadius
        frameView.layer?.cornerCurve = .continuous
        frameView.layer?.masksToBounds = true
    }

    /// 콘텐츠 뷰의 자식으로 대시보드 호스팅.
    /// 호스팅 뷰가 콘텐츠 뷰 자체이면 창 크기를 강제 변경하므로 PanelHeightController와의 크기 충돌 방지.
    func host(_ view: NSHostingView<some View>) {
        guard let contentView else { return }
        view.sizingOptions = []
        view.layerContentsRedrawPolicy = .duringViewResize
        view.frame = contentView.bounds
        view.autoresizingMask = [.width, .height]
        contentView.addSubview(view)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 패널 클릭을 먼저 키 창으로 처리 — AppKit의 포커스 전환이 이름 변경용 더블클릭의 첫 클릭을 소비하지 않도록 방지.
    override func sendEvent(_ event: NSEvent) {
        if !isKeyWindow, attachedSheet == nil,
           [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
            makeKey()
        }
        super.sendEvent(event)
    }

    /// 숨겨진 Settings의 비활성 입력기가 포커스를 받아 다음 키를 단축키로 저장하는 상황 방지.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        if let recorder = responder as? KeyboardShortcuts.RecorderCocoa, !recorder.isEnabled { return false }
        return super.makeFirstResponder(responder)
    }

    /// 컨트롤의 포커스 링과 단축키 입력 대기 해제 — 일반 텍스트 편집은 유지.
    func clearStrayFocus() {
        guard !ShortcutRecorderField.isRecordingActive else { return }
        let recording = (firstResponder as? NSTextView)?.delegate is KeyboardShortcuts.RecorderCocoa
        guard recording || !(firstResponder is NSText) else { return }
        _ = makeFirstResponder(nil)
    }
}

/// 메뉴 막대 상태 항목과 대시보드 패널 소유.
/// SwiftUI MenuBarExtra의 입력·프로그래밍 방식 표시 제약 때문에 AppKit 패널 사용.
@MainActor
final class StatusItemController: NSObject {
    private let container: AppContainer
    private let statusItem: NSStatusItem
    /// 메뉴 막대 렌더링 수명 관리 — 적용 클로저는 제어기 대신 NSStatusItem만 보유.
    private let imageUpdater: StatusItemImageUpdater
    private let panel: MenuBarPanel
    private let heightController: PanelHeightController
    private lazy var outsideClickMonitor = PanelOutsideClickMonitor(
        panel: panel,
        statusItem: statusItem,
        isMorphing: { [weak self] in self?.heightController.isMorphing ?? false },
        isSigningIn: { [weak self] in self?.container.popover.signingInAgainAccountID != nil },
        onInsidePanelClick: { [weak self] in self?.panel.clearStrayFocus() },
        onDismiss: { [weak self] in self?.hidePanel() }
    )
    private let host: NSHostingView<AnyView>
    /// 테마 변경 구독 해제용 관찰자 토큰.
    private var appearanceObserver: NSObjectProtocol?

    init(container: AppContainer, updater: UpdaterController) {
        self.container = container
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem
        // 상태 항목만 캡처하여 순환 참조 방지 — 버튼은 적용 시점마다 조회.
        self.imageUpdater = StatusItemImageUpdater(container: container, updater: updater) { image in
            statusItem.button?.image = image
        }

        // 제자리 계정 이름 변경 — 상단 바 제목과 패널 닫힘 정리가 같은 편집을 공유.
        let renaming = AccountRenameStore(
            profileID: { container.accountProfileID(for: $0) },
            label: { container.accountProfiles.profile(id: $0)?.label },
            email: { id in
                container.accountProfiles.profile(id: id).flatMap { container.accountLoginEmail(for: $0) }
            },
            rename: { profileID, name in
                try container.accountProfiles.rename(profileID: profileID, to: name)
                container.refreshAccountCatalog()
            }
        )
        let host = NSHostingView(
            rootView: AnyView(
                DashboardView()
                    .reduceAnimationsWhenRequested()
                    .environment(\.locale, L10n.locale)
                    .environment(container)
                    .environment(container.layout)
                    .environment(container.dataStore)
                    .environment(container.popover)
                    .environment(renaming)
                    .environment(updater)
                    .environment(\.codexResetClaim, container.codexResetClaim)
            )
        )
        self.host = host

        let panel = MenuBarPanel(contentRect: NSRect(
            x: 0,
            y: 0,
            width: PanelMetrics.width,
            height: PanelHeightController.defaultHeight
        ))
        self.panel = panel
        self.heightController = PanelHeightController(
            panel: panel,
            currentScreen: { container.popover.screen },
            currentTab: { container.popover.dashboardTab }
        )

        super.init()

        configurePanel()
        configureStatusItem()
        imageUpdater.update()

        appearanceObserver = NotificationCenter.default.addObserver(
            forName: AppearanceSetting.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.appearance = AppearanceSetting.current.nsAppearance
            }
        }
        // 앱 수명 동안 유지되는 제어기에 단축키 한 번 등록.
        KeyboardShortcuts.onKeyUp(for: .togglePopover) { [weak self] in
            AppLog.info(.statusItem, "Global shortcut fired; toggling popover")
            self?.togglePopover()
        }

        // 대시보드의 Esc는 메뉴 막대 클릭과 같은 경로로 닫기.
        MenuBarPopover.dismissHandler = { [weak self] in
            self?.hidePanel()
        }
        // 사용량 알림 클릭 — All Usage로 열기.
        MenuBarPopover.showHandler = { [weak self] in
            self?.showPopover(dashboardTab: .allUsage)
        }

        heightController.installBridge()

        AppLog.info(.statusItem, "Status item ready (button: \(self.statusItem.button != nil), shortcut: \(KeyboardShortcuts.getShortcut(for: .togglePopover)?.description ?? "none"))")
    }

    // MARK: - Panel configuration

    private func configurePanel() {
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.animationBehavior = .none
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // 앱 테마를 고정 적용 — System은 nil, 변경은 appearanceObserver로 추적.
        panel.appearance = AppearanceSetting.current.nsAppearance

        panel.host(host)
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        button.target = self
        button.action = #selector(statusButtonClicked)
        // 좌클릭은 패널 열기·닫기, 우클릭·Control 클릭은 메뉴 표시.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    // MARK: - Show / hide

    @objc private func statusButtonClicked() {
        let event = NSApp.currentEvent
        let isContextClick = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        if isContextClick {
            showContextMenu()
        } else {
            togglePopover()
        }
    }

    /// 메뉴 막대 우클릭·Control 클릭 메뉴 — 패널 메뉴의 Accounts·Settings·Quit과 제목·기호·단축키 공유.
    /// `performClick` 동안만 메뉴 연결 — 이후 해제하여 좌클릭의 패널 열기·닫기 복원.
    private func showContextMenu() {
        // 패널을 먼저 닫아 강조 표시·외부 클릭 감시와 메뉴 추적의 경합 방지.
        if panel.isVisible { hidePanel() }

        let menu = NSMenu()
        menu.addItem(ClosureMenuItem(title: L10n.common("Accounts"), systemSymbol: "person.crop.circle") { [weak self] in
            self?.openScreen(.accounts)
        })
        menu.addItem(ClosureMenuItem(title: L10n.common("Settings"), systemSymbol: "gearshape", keyEquivalent: ",") { [weak self] in
            self?.openScreen(.settings)
        })
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: L10n.common("Quit egasu"), systemSymbol: "power", keyEquivalent: "q") {
            NSApplication.shared.terminate(nil)
        })

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    /// 패널 표시 전에 목적 화면을 설정하여 해당 화면 크기로 열기.
    private func openScreen(_ screen: PopoverScreen) {
        container.popover.screen = screen
        if !panel.isVisible {
            showPanel()
        }
    }

    func togglePopover() {
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// 이미 표시 중이면 닫지 않고 전면으로 — 외부 트리거(사용량 알림 클릭)용.
    func showPopover(dashboardTab: DashboardTab) {
        container.popover.screen = .dashboard
        if panel.isVisible {
            container.popover.dashboardTab = dashboardTab
            panel.makeKeyAndOrderFront(nil)
            statusItem.button?.highlight(true)
            return
        }
        showPanel(dashboardTab: dashboardTab)
    }

    private func showPanel(dashboardTab: DashboardTab? = nil) {
        guard let button = statusItem.button, let buttonWindow = button.window else {
            AppLog.error(.statusItem, "Cannot show panel: status item has no button")
            return
        }
        let buttonRectOnScreen = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        // 표시 신호가 높이 조정을 즉시 요청하므로 먼저 화면·기준 위치 기록.
        heightController.prepareForOpening(below: buttonRectOnScreen, tab: dashboardTab ?? container.popover.dashboardTab)
        container.popover.show(dashboardTab: dashboardTab)

        // 표시 전에 콘텐츠 배치를 완료하여 첫 프레임부터 정확한 크기 적용.
        host.layoutSubtreeIfNeeded()

        // 앱 활성화 없이 키 창으로 전환하여 첫 시도부터 키 입력 수신.
        panel.makeKeyAndOrderFront(nil)
        // Keyboard Navigation의 첫 컨트롤 자동 포커스로 생긴 불필요한 포커스 링 제거.
        panel.clearStrayFocus()
        button.highlight(true)
        outsideClickMonitor.start()
    }

    private func hidePanel() {
        // `orderOut` 뒤에도 SwiftUI 뷰가 유지되므로 포인터 이탈 없이 남는 툴팁·팝오버 직접 닫기.
        HoverTooltips.dismissAll()
        HoverPopoverState.dismissAll()
        panel.clearStrayFocus()
        // 닫는 화면의 높이를 저장한 뒤 SwiftUI 화면 상태 초기화.
        heightController.saveBeforeClosing()
        // `orderOut`과 동기적으로 패널 숨김 상태 반영.
        container.popover.popoverShown = false
        panel.orderOut(nil)
        outsideClickMonitor.stop()
        statusItem.button?.highlight(false)
        heightController.finishClosing()
    }
}
