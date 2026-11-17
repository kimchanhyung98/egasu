import AppKit

/// 화면별 측정 콘텐츠 높이 — Priority와 All Usage는 서로 다른 값으로 기록.
struct MeasuredPanelHeights: Equatable {
    private struct Key: Hashable {
        let screen: PopoverScreen
        let tab: DashboardTab?
    }

    private var heights: [Key: CGFloat] = [:]

    subscript(screen: PopoverScreen, tab: DashboardTab) -> CGFloat? {
        get { heights[Key(screen: screen, tab: screen == .dashboard ? tab : nil)] }
        set { heights[Key(screen: screen, tab: screen == .dashboard ? tab : nil)] = newValue }
    }
}

/// 메뉴 막대 패널의 위치와 콘텐츠 기반 높이 관리.
/// 패널 생성·표시·숨김은 상태 항목 제어기 소유 — 이 타입은 SwiftUI·AppKit 사이의 높이 조정만 담당.
@MainActor
final class PanelHeightController {
    static let defaultHeight: CGFloat = 800

    private let panel: MenuBarPanel
    private let currentScreen: () -> PopoverScreen
    private let currentTab: () -> DashboardTab
    private let defaults: UserDefaults

    private var anchorScreen: NSScreen?
    private var anchorTopLeft: NSPoint?
    private var morphSettleTask: Task<Void, Never>?
    private(set) var isMorphing = false
    private var contentHeight: CGFloat?
    private var sheetObservers: [NSObjectProtocol] = []

    init(
        panel: MenuBarPanel,
        defaults: UserDefaults = .standard,
        currentScreen: @escaping () -> PopoverScreen,
        currentTab: @escaping () -> DashboardTab
    ) {
        self.panel = panel
        self.defaults = defaults
        self.currentScreen = currentScreen
        self.currentTab = currentTab
    }

    /// SwiftUI 측정 콜백과 시트 크기 추적 설치 — 시트가 패널보다 크면 패널 확장.
    func installBridge() {
        MenuBarPopover.applyHeight = { [weak self] height in
            self?.applyMorphHeight(height)
        }
        MenuBarPopover.clampHeight = { [weak self] rawHeight in
            self?.clampedHeight(rawHeight) ?? rawHeight
        }
        let center = NotificationCenter.default
        sheetObservers = [NSWindow.willBeginSheetNotification, NSWindow.didEndSheetNotification].map { name in
            center.addObserver(forName: name, object: panel, queue: .main) { [weak self] _ in
                // `attachedSheet`는 알림 이후 갱신되므로 다음 실행 순서에서 반영.
                Task { @MainActor in self?.fitAttachedSheet() }
            }
        }
        sheetObservers.append(center.addObserver(forName: NSWindow.didResizeNotification, object: nil, queue: .main) { [weak self] note in
            let windowID = (note.object as AnyObject?).map(ObjectIdentifier.init)
            MainActor.assumeIsolated {
                guard let self, let sheet = self.panel.attachedSheet, windowID == ObjectIdentifier(sheet) else { return }
                self.fitAttachedSheet()
            }
        })
    }

    /// 이전 세션 정리 후 화면 정보와 저장된 높이로 패널 열기 준비.
    /// SwiftUI 표시 신호가 최대 높이를 즉시 요청하므로 신호 전달 전에 실행.
    func prepareForOpening(below buttonRect: NSRect, tab: DashboardTab) {
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()

        let screen = NSScreen.screens.first { $0.frame.intersects(buttonRect) } ?? NSScreen.main
        anchorScreen = screen
        let topLeft = PanelGeometry.clampedTopLeft(
            below: buttonRect,
            width: PanelMetrics.width,
            visibleFrame: screen?.visibleFrame
        )
        anchorTopLeft = topLeft

        let remembered = loadHeight(for: currentScreen(), tab: tab) ?? Self.defaultHeight
        let height = clampedHeight(remembered)
        panel.setFrame(
            PanelGeometry.frame(topLeft: topLeft, width: PanelMetrics.width, height: height),
            display: false
        )
        panel.invalidateShadow()
    }

    func saveBeforeClosing() {
        guard panel.isVisible else { return }
        saveHeight(contentHeight ?? panel.frame.height, for: currentScreen(), tab: currentTab())
    }

    func finishClosing() {
        anchorTopLeft = nil
        anchorScreen = nil
        contentHeight = nil
        morphSettleTask?.cancel()
        isMorphing = false
        PanelHeightBridge.invalidate()
    }

    private func fitAttachedSheet() {
        applyMorphHeight(contentHeight ?? panel.frame.height)
    }

    private func applyMorphHeight(_ rawHeight: CGFloat) {
        guard rawHeight > 1, panel.isVisible else { return }
        guard let anchorTopLeft else {
            AppLog.error(.statusItem, "Morph height while visible but no anchor; frame not applied")
            return
        }
        contentHeight = rawHeight
        let height = clampedHeight(PanelGeometry.height(content: rawHeight, attachedSheet: panel.attachedSheet?.frame.height))
        guard abs(panel.frame.height - height) > 1 else { return }
        panel.setFrame(
            PanelGeometry.frame(topLeft: anchorTopLeft, width: PanelMetrics.width, height: height),
            display: false
        )
        isMorphing = true
        scheduleMorphSettle()
    }

    private func scheduleMorphSettle() {
        morphSettleTask?.cancel()
        morphSettleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, let self, self.panel.isVisible else { return }
            self.isMorphing = false
            self.panel.invalidateShadow()
            self.saveHeight(self.contentHeight ?? self.panel.frame.height, for: self.currentScreen(), tab: self.currentTab())
        }
    }

    private func clampedHeight(_ rawHeight: CGFloat) -> CGFloat {
        PanelGeometry.clampedHeight(rawHeight, maximum: maximumHeight())
    }

    private func maximumHeight() -> CGFloat {
        guard let anchorTopLeft, let visibleFrame = (anchorScreen ?? NSScreen.main)?.visibleFrame else {
            return Self.defaultHeight
        }
        return PanelGeometry.maximumHeight(topLeft: anchorTopLeft, visibleFrame: visibleFrame)
    }

    private func loadHeight(for screen: PopoverScreen, tab: DashboardTab) -> CGFloat? {
        let value = defaults.double(forKey: Self.heightKey(for: screen, tab: tab))
        return value > 0 ? CGFloat(value) : nil
    }

    private func saveHeight(_ height: CGFloat, for screen: PopoverScreen, tab: DashboardTab) {
        defaults.set(Double(height), forKey: Self.heightKey(for: screen, tab: tab))
    }

    /// 탭마다 별도 높이 저장 — Priority를 열 때 All Usage 높이에서 축소되는 현상 방지.
    private static func heightKey(for screen: PopoverScreen, tab: DashboardTab) -> String {
        switch screen {
        case .dashboard: tab == .priority ? "openusage.panel.height.dashboard" : "openusage.panel.height.dashboard.allUsage"
        case .accounts: "openusage.panel.height.accounts"
        case .settings: "openusage.panel.height.settings"
        }
    }
}

/// 창 생성 없이 패널 크기·화면 경계 계산 검증.
enum PanelGeometry {
    static let topGap: CGFloat = 4
    static let screenMargin: CGFloat = 8

    static func clampedTopLeft(below buttonRect: NSRect, width: CGFloat, visibleFrame: NSRect?) -> NSPoint {
        var x = buttonRect.minX
        if let visibleFrame {
            x = min(
                max(x, visibleFrame.minX + screenMargin),
                visibleFrame.maxX - width - screenMargin
            )
        }
        return NSPoint(x: x, y: buttonRect.minY - topGap)
    }

    static func maximumHeight(topLeft: NSPoint, visibleFrame: NSRect) -> CGFloat {
        let roomBelowAnchor = topLeft.y - visibleFrame.minY - screenMargin
        let aestheticCap = floor(visibleFrame.height * 0.85)
        return max(1, min(roomBelowAnchor, aestheticCap))
    }

    /// 패널 높이 = 내용 높이를 화면 한도로 자른 값 — 최소 높이 없음.
    static func clampedHeight(_ rawHeight: CGFloat, maximum: CGFloat) -> CGFloat {
        min(rawHeight, maximum)
    }

    static let sheetMargin: CGFloat = 20

    /// 시트가 붙어 있으면 시트 높이 + 여백만큼은 확보.
    static func height(content: CGFloat, attachedSheet: CGFloat?) -> CGFloat {
        guard let attachedSheet else { return content }
        return max(content, attachedSheet + sheetMargin)
    }

    /// 위쪽 가장자리·높이를 정수 포인트로 정렬 — AppKit의 개별 반올림에 따른 높이 전환 중 흔들림 방지.
    /// 위쪽 좌표는 내림 처리하여 메뉴 막대 항목 아래 간격 유지.
    static func frame(topLeft: NSPoint, width: CGFloat, height: CGFloat) -> NSRect {
        let top = topLeft.y.rounded(.down)
        let height = height.rounded()
        return NSRect(
            origin: NSPoint(x: topLeft.x, y: top - height),
            size: NSSize(width: width, height: height)
        )
    }
}
