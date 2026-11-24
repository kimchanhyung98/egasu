import XCTest
@testable import Egasu

@MainActor
final class PanelHeightBridgeTests: XCTestCase {
    func testCoalescesBurstToNewestHeight() async {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        let firstApply = expectation(description: "applies coalesced height")
        let secondApply = expectation(description: "does not replay stale heights")
        secondApply.isInverted = true

        MenuBarPopover.applyHeight = { height in
            applied.append(height)
            if applied.count == 1 {
                firstApply.fulfill()
            } else {
                secondApply.fulfill()
            }
        }

        PanelHeightBridge.push(520)
        PanelHeightBridge.push(560)
        PanelHeightBridge.push(600)

        await fulfillment(of: [firstApply], timeout: 1)
        await fulfillment(of: [secondApply], timeout: 0.05)
        XCTAssertEqual(applied, [600])
    }

    func testInvalidateDropsQueuedHeight() async {
        resetBridge()
        defer { resetBridge() }

        let droppedApply = expectation(description: "drops queued height")
        droppedApply.isInverted = true
        MenuBarPopover.applyHeight = { _ in droppedApply.fulfill() }

        PanelHeightBridge.push(600)
        PanelHeightBridge.invalidate()

        await fulfillment(of: [droppedApply], timeout: 0.05)
    }

    func testOpeningAcceptsNewHeightAfterDroppingPreviousSession() async {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        let openingApply = expectation(description: "applies this opening's height")
        MenuBarPopover.applyHeight = { height in
            applied.append(height)
            openingApply.fulfill()
        }

        PanelHeightBridge.push(480) // 이전 session 대기값
        PanelHeightBridge.invalidate()
        PanelHeightBridge.push(760) // 현재 열린 display 측정값

        await fulfillment(of: [openingApply], timeout: 1)
        XCTAssertEqual(applied, [760])
    }

    func testEffectValuePushesEstablishedHeight() async {
        resetBridge()
        defer { resetBridge() }

        var applied: [CGFloat] = []
        let firstApply = expectation(description: "applies established height")
        MenuBarPopover.applyHeight = { height in
            applied.append(height)
            firstApply.fulfill()
        }

        let modifier = PanelHeightModifier(
            path: PanelHeightPath(start: 400, end: 700), progress: 0.8,
            motion: 0, presentation: PanelHeightPresentation()
        )
        _ = modifier.effectValue(size: CGSize(width: 320, height: 640))

        await fulfillment(of: [firstApply], timeout: 1)
        XCTAssertEqual(applied, [640])
    }

    func testCorrectedTargetFinishesOnTheSameProgressWithoutReversing() {
        let initial = PanelHeightPath(start: 240, end: 440)
        let correction = PanelHeightPath(start: initial.height(at: 0.25), end: 510, startProgress: 0.25)

        XCTAssertEqual(correction.height(at: 0.25), 290)
        let frames = [0.25, 0.4, 0.5, 0.6, 0.75, 0.9, 1].map(correction.height(at:))
        XCTAssertEqual(frames, frames.sorted())
        XCTAssertEqual(frames.last, 510)
    }

    func testBackDuringDetailTransitionDiscardsLateOutgoingFrames() async {
        resetBridge()
        defer { resetBridge() }
        let presentation = PanelHeightPresentation()
        let push = presentation.restart()
        let detail = PanelHeightPath(start: 220, end: 600)
        presentation.present(detail.height(at: 0.5), at: 0.5, motion: push.motion)
        let back = presentation.restart()
        let list = PanelHeightPath(start: back.height, end: 220)

        XCTAssertEqual(back.height, 410)
        XCTAssertEqual(back.progress, 0)
        let delivered = expectation(description: "목록으로 돌아가는 최신 프레임")
        MenuBarPopover.applyHeight = { height in
            XCTAssertEqual(height, 315)
            delivered.fulfill()
        }
        presentation.present(list.height(at: 0.5), at: 0.5, motion: back.motion)
        presentation.present(600, at: 1, motion: push.motion)
        XCTAssertEqual(presentation.current.height, 315)
        await fulfillment(of: [delivered], timeout: 1)
    }

    func testNewMeasurementReplacesUnanimatedFallbackWithoutAnotherDrawingPass() async {
        resetBridge()
        defer { resetBridge() }
        let presentation = PanelHeightPresentation()
        let initial = presentation.restart().motion
        presentation.present(220, at: 1, motion: initial)
        let delivered = expectation(description: "새로 측정한 계정 목록 높이")
        MenuBarPopover.applyHeight = { height in
            XCTAssertEqual(height, 300)
            delivered.fulfill()
        }

        let motion = presentation.settle(at: 300)
        presentation.present(220, at: 1, motion: initial)
        XCTAssertEqual(presentation.current.motion, motion)
        XCTAssertEqual(presentation.current.height, 300)
        await fulfillment(of: [delivered], timeout: 1)
    }

    private func resetBridge() {
        PanelHeightBridge.invalidate()
        MenuBarPopover.applyHeight = nil
    }
}
