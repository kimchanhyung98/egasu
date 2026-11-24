import AppKit
import XCTest
@testable import Egasu

final class PanelGeometryTests: XCTestCase {
    @MainActor
    func testSheetExpansionRestoresAndRemembersTheContentHeight() async throws {
        let name = "EgasuTests.PanelHeight.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let panel = MenuBarPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 120))
        panel.isReleasedWhenClosed = false
        panel.alphaValue = 0
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 320),
                             styleMask: .borderless, backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        sheet.alphaValue = 0
        let controller = PanelHeightController(
            panel: panel, defaults: defaults, currentScreen: { .accounts }, currentTab: { .allUsage })
        controller.installBridge()
        defer {
            if panel.attachedSheet != nil { panel.endSheet(sheet) }
            controller.finishClosing()
            MenuBarPopover.applyHeight = nil
            MenuBarPopover.clampHeight = nil
            MenuBarPopover.presentedHeight = nil
            panel.close()
            sheet.close()
        }
        let visible = try XCTUnwrap(NSScreen.main).visibleFrame
        let anchor = NSRect(x: visible.midX, y: visible.maxY - 30, width: 25, height: 25)
        controller.prepareForOpening(below: anchor, tab: .allUsage)
        panel.orderFrontRegardless()
        MenuBarPopover.applyHeight?(120)
        panel.beginSheet(sheet, completionHandler: nil)
        try await waitForHeight {
            panel.attachedSheet != nil && panel.frame.height > 120 && !controller.isMorphing
        }

        XCTAssertEqual(defaults.double(forKey: "openusage.panel.height.accounts"), 120)
        controller.saveBeforeClosing()
        XCTAssertEqual(defaults.double(forKey: "openusage.panel.height.accounts"), 120,
                       "시트 확장 중 닫아도 콘텐츠 높이만 저장")

        panel.endSheet(sheet)
        try await waitForHeight { panel.attachedSheet == nil && panel.frame.height == 120 }
        panel.orderOut(nil)
        controller.finishClosing()
        controller.prepareForOpening(below: anchor, tab: .allUsage)
        XCTAssertEqual(panel.frame.height, 120, "다시 열 때 시트로 확대한 높이 재사용 금지")
    }

    @MainActor
    private func waitForHeight(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(6)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("패널·시트 높이 반영 대기 시간 초과")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    func testHorizontalPlacementStaysInsideVisibleFrame() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 900)
        let left = PanelGeometry.clampedTopLeft(
            below: NSRect(x: -40, y: 850, width: 20, height: 20),
            width: 320,
            visibleFrame: visible
        )
        let right = PanelGeometry.clampedTopLeft(
            below: NSRect(x: 490, y: 850, width: 20, height: 20),
            width: 320,
            visibleFrame: visible
        )

        XCTAssertEqual(left.x, 8)
        XCTAssertEqual(right.x, 172)
        XCTAssertEqual(left.y, 846)
    }

    func testMaximumHeightUsesAvailableRoomAndDisplayCap() {
        let visible = NSRect(x: 0, y: 0, width: 1200, height: 1000)

        XCTAssertEqual(
            PanelGeometry.maximumHeight(topLeft: NSPoint(x: 100, y: 900), visibleFrame: visible),
            850
        )
    }

    func testShortDisplayMayShrinkBelowNormalMinimum() {
        let visible = NSRect(x: 0, y: 0, width: 500, height: 200)
        let maximum = PanelGeometry.maximumHeight(
            topLeft: NSPoint(x: 100, y: 190),
            visibleFrame: visible
        )

        XCTAssertEqual(maximum, 170)
        XCTAssertEqual(PanelGeometry.clampedHeight(600, maximum: maximum), 170)
    }

    func testHeightClampsOnlyToDisplayMaximum() {
        XCTAssertEqual(PanelGeometry.clampedHeight(50, maximum: 700), 50)
        XCTAssertEqual(PanelGeometry.clampedHeight(900, maximum: 700), 700)
        XCTAssertEqual(PanelGeometry.clampedHeight(520, maximum: 700), 520)
    }

    func testAttachedSheetHeightIncludesMarginWithoutChangingContentHeight() {
        XCTAssertEqual(PanelGeometry.height(content: 120, attachedSheet: 320), 340)
        XCTAssertEqual(PanelGeometry.height(content: 550, attachedSheet: 320), 550)
        XCTAssertEqual(PanelGeometry.height(content: 120, attachedSheet: nil), 120)
        XCTAssertEqual(PanelGeometry.clampedHeight(
            PanelGeometry.height(content: 120, attachedSheet: 320), maximum: 200
        ), 200)
    }

    func testMeasuredHeightsKeepScreensIndependentOfDashboardTabs() {
        var heights = MeasuredPanelHeights()
        heights[.dashboard, .allUsage] = 600
        heights[.dashboard, .priority] = 250
        heights[.accounts, .allUsage] = 400
        heights[.settings, .priority] = 700
        heights[.accounts, .priority, "codex"] = 310
        heights[.accounts, .priority, "claude"] = 525
        XCTAssertEqual(heights[.accounts, .allUsage, "codex"], 310)
        XCTAssertEqual(heights[.accounts, .priority, "claude"], 525)
        XCTAssertEqual(heights[.dashboard, .allUsage], 600)
        XCTAssertEqual(heights[.dashboard, .priority], 250)
        XCTAssertEqual(heights[.accounts, .priority], 400)
        XCTAssertEqual(heights[.settings, .allUsage], 700)
    }

    func testChangingHeightKeepsTopEdgeFixed() {
        let topLeft = NSPoint(x: 120, y: 800)
        let short = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 300)
        let tall = PanelGeometry.frame(topLeft: topLeft, width: 320, height: 650)

        XCTAssertEqual(short.maxY, topLeft.y)
        XCTAssertEqual(tall.maxY, topLeft.y)
        XCTAssertEqual(short.minX, tall.minX)
        XCTAssertEqual(short.width, tall.width)
    }
}
