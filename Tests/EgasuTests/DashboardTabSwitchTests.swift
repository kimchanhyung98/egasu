import AppKit
import SwiftUI
import XCTest
@testable import Egasu

/// 대시보드 탭 전환 — 누르는 순간 선택, 패널 크기가 바뀌는 동안 아래 바가 새 행을 가림.
/// 창은 화면 밖·투명·키 창 아님 — 사용자의 입력 포커스를 가져가지 않음.
@MainActor
final class DashboardTabSwitchTests: XCTestCase {
    func testDashboardTabsPickTheSegmentOnPressBeforeTheRelease() async throws {
        let model = SegmentModel()
        let (window, host) = show(Segments(model: model, selectsOnPress: true), size: CGSize(width: 200, height: 60))

        send(.leftMouseDown, at: CGPoint(x: 150, y: 30), window, host)
        try await waitUntil { model.selection == "B" }
        send(.leftMouseUp, at: CGPoint(x: 150, y: 30), window, host)
        XCTAssertEqual(model.selection, "B")
    }

    func testOtherSegmentsStillPickOnRelease() async throws {
        let model = SegmentModel()
        let (window, host) = show(Segments(model: model, selectsOnPress: false), size: CGSize(width: 200, height: 60))

        send(.leftMouseDown, at: CGPoint(x: 150, y: 30), window, host)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.selection, "A", "누르기만 해서는 선택하지 않음")
        send(.leftMouseUp, at: CGPoint(x: 150, y: 30), window, host)
        try await waitUntil { model.selection == "B" }
    }

    func testOnlyPagesWithFooterActionsReserveBottomScrollSpace() async throws {
        let footerHeight: CGFloat = 47
        let routes: [(PopoverScreen, String?, CGFloat)] = [
            (.settings, nil, 0), (.accounts, "codex", 0), (.accounts, nil, footerHeight),
            (.dashboard, nil, footerHeight)
        ]
        for (screen, accountID, expectedInset) in routes {
            var bottomInset: CGFloat?
            _ = show(
                PopoverScrollView { Color.blue.frame(height: 500) }
                    .onScrollGeometryChange(for: EdgeInsets.self) {
                        $0.contentInsets
                    } action: { _, insets in
                        if insets.top > 0 { bottomInset = insets.bottom }
                    }
                    .panelBars {
                        Color.clear.frame(height: 30)
                    } bottom: {
                        PopoverFooter(screen: screen, accountDetailID: accountID).map { _ in
                            Color.clear.frame(height: footerHeight)
                        }
                    },
                size: CGSize(width: PanelMetrics.width, height: 200))
            try await waitUntil { bottomInset != nil }
            let inset = try XCTUnwrap(bottomInset)
            XCTAssertEqual(inset, expectedInset, accuracy: 1, "\(screen) \(accountID ?? "")")
        }
    }

    func testAccountNavigationReservesTheWholeFooterOrNone() async throws {
        let popover = PopoverState()
        popover.openAccounts(nil)
        var insets: [CGFloat] = []
        let footerHeight: CGFloat = 47
        _ = show(
            AccountInsetProbe(popover: popover, footerHeight: footerHeight) { insets.append($0) },
            size: CGSize(width: PanelMetrics.width, height: 200))
        try await waitUntil { insets.last == footerHeight }
        popover.openAccounts("codex")
        try await waitUntil { insets.last == 0 }
        popover.back()
        try await waitUntil { insets.last == footerHeight }
        XCTAssertTrue(insets.allSatisfy { $0 == 0 || $0 == footerHeight }, "푸터 여백이 따로 애니메이션됨: \(insets)")
    }

    func testHostedPanelHeightEffectDrawsIntermediateFramesAndReversesFromThePresentedHeight() async throws {
        let model = PanelMotionProbe()
        var heights: [CGFloat] = []
        PanelHeightBridge.invalidate()
        MenuBarPopover.applyHeight = { heights.append($0) }
        defer {
            MenuBarPopover.applyHeight = nil
            PanelHeightBridge.invalidate()
        }
        let (_, host) = show(PanelMotionProbeView(model: model), size: CGSize(width: PanelMetrics.width, height: 240))
        try await waitUntil { heights.last == 240 }
        withAnimation(.linear(duration: 0.6)) { model.progress = 1 }
        try await waitUntil { (heights.last ?? 0) > 265 }
        let turn = try XCTUnwrap(heights.last)
        XCTAssertLessThan(turn, 600)
        let firstReturn = heights.count
        withAnimation(nil) {
            model.motion = model.presentation.restart().motion
            model.path = PanelHeightPath(start: turn, end: 240)
            model.progress = 0
        }
        host.layoutSubtreeIfNeeded()
        await Task.yield()
        withAnimation(.linear(duration: 0.25)) { model.progress = 1 }
        try await waitUntil { heights.last == 240 }
        let returning = Array(heights.dropFirst(firstReturn))
        XCTAssertTrue(returning.contains { $0 > 240 && $0 < turn })
        XCTAssertTrue(zip([turn] + returning, returning).allSatisfy { $1 <= $0 + 1 })
    }

    /// 탭 전환은 패널이 새 높이를 받기 한 프레임 전에 새 행을 그림 — 그동안 아래 바가 패널 색으로 가림.
    func testTheBottomBarCoversContentOnlyWhileThePanelIsAtAnotherHeight() async throws {
        let barHeight: CGFloat = 30
        MenuBarPopover.clampHeight = { min($0, 300) }
        addTeardownBlock { @MainActor in MenuBarPopover.clampHeight = nil }
        let (window, host) = show(
            PopoverScrollView { Color.blue.frame(height: 1_000) }
                .panelBars {
                    Color.clear.frame(height: barHeight)
                } bottom: {
                    Color.clear.frame(height: barHeight)
                },
            size: CGSize(width: 200, height: 200)
        )
        try await Task.sleep(for: .milliseconds(150))
        let bottomBar = {
            NSRect(
                x: 0, y: host.isFlipped ? host.bounds.maxY - barHeight : 0, width: host.bounds.width, height: barHeight)
        }
        XCTAssertFalse(try showsBlue(in: bottomBar(), of: host), "패널이 페이지 높이에 맞기 전에는 아래 바가 내용을 가림")

        window.setContentSize(CGSize(width: 200, height: 300))
        try await Task.sleep(for: .milliseconds(150))
        if #available(macOS 27, *) {
            XCTAssertTrue(try showsBlue(in: bottomBar(), of: host), "패널이 맞으면 아래 바 밑 내용이 다시 보임")
        } else {
            let frost = try XCTUnwrap(
                descendants(of: host).compactMap { $0 as? NSVisualEffectView }.first {
                    $0.material == .menu && $0.blendingMode == .withinWindow
                })
            XCTAssertFalse(frost.isHiddenOrHasHiddenAncestor)
            var opacity: CGFloat = 1
            var ancestor: NSView? = frost
            while let view = ancestor {
                opacity *= view.alphaValue
                ancestor = view.superview
            }
            XCTAssertGreaterThan(opacity, 0, "이전 macOS에서는 내용이 있는 아래 바에 별도 흐림 표시")
            XCTAssertEqual(host.bounds.height, 300, accuracy: 1)
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }

    // MARK: - Fixtures

    private func show(_ content: some View, size: CGSize) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        let screens = NSScreen.screens.map(\.frame)
        window.alphaValue = 0
        window.setFrameOrigin(
            NSPoint(x: (screens.map(\.maxX).max() ?? 0) + 1_000, y: (screens.map(\.maxY).max() ?? 0) + 1_000))
        window.orderFrontRegardless()
        XCTAssertFalse(window.isKeyWindow, "테스트 창이 키 창이 되면 안 됨")
        addTeardownBlock { @MainActor in window.close() }
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// `point`는 host 기준 좌상단 좌표.
    private func send(_ type: NSEvent.EventType, at point: CGPoint, _ window: NSWindow, _ host: NSView) {
        let event = NSEvent.mouseEvent(
            with: type,
            location: NSPoint(x: point.x, y: host.bounds.height - point.y),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: type == .leftMouseDown ? 1 : 0
        )
        window.sendEvent(try! XCTUnwrap(event))
    }

    private func waitUntil(
        timeout: Duration = .seconds(2), _ condition: () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("Timed out waiting", file: file, line: line) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// `bar`(host 좌표) 가운데 세로줄에 파란 내용이 보이는지.
    private func showsBlue(in bar: NSRect, of host: NSView) throws -> Bool {
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let scale = CGFloat(rep.pixelsWide) / host.bounds.width
        return stride(from: bar.minY, to: bar.maxY, by: 1).contains { y in
            let row = host.isFlipped ? y : host.bounds.maxY - y - 1
            guard let color = rep.colorAt(x: Int(bar.midX * scale), y: Int(row * scale))?.usingColorSpace(.deviceRGB)
            else {
                return false
            }
            return color.blueComponent - max(color.redComponent, color.greenComponent) > 0.2
        }
    }
}

@MainActor
@Observable
private final class SegmentModel {
    var selection = "A"
}

private struct Segments: View {
    let model: SegmentModel
    let selectsOnPress: Bool

    var body: some View {
        CapsuleSegments(
            options: [("A", "A"), ("B", "B")],
            selection: Bindable(model).selection,
            selectsOnPress: selectsOnPress
        )
        .frame(width: 200, height: 60)
    }
}

@MainActor
@Observable
private final class PanelMotionProbe {
    var motion = 0
    var progress: CGFloat = 0
    var path = PanelHeightPath(start: 240, end: 600)
    let presentation = PanelHeightPresentation()
}

private struct PanelMotionProbeView: View {
    let model: PanelMotionProbe

    var body: some View {
        Color.blue.background {
            Color.clear
                .modifier(
                    PanelHeightModifier(
                        path: model.path, progress: model.progress, motion: model.motion,
                        presentation: model.presentation
                    )
                )
                .id(model.motion)
                .transition(.identity)
        }
    }
}

private struct AccountInsetProbe: View {
    let popover: PopoverState
    let footerHeight: CGFloat
    let record: (CGFloat) -> Void

    var body: some View {
        PopoverScrollView { Color.blue.frame(height: 500) }
            .onScrollGeometryChange(for: EdgeInsets.self) {
                $0.contentInsets
            } action: { _, insets in
                if insets.top > 0 { record(insets.bottom) }
            }
            .panelBars {
                Color.clear.frame(height: 30)
            } bottom: {
                PopoverFooter(screen: .accounts, accountDetailID: popover.accountDetailID).map { _ in
                    Color.clear.frame(height: footerHeight)
                }
            }
    }
}
