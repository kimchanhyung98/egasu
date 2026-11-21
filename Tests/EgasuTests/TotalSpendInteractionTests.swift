import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class TotalSpendInteractionTests: XCTestCase {
    func testCenterButtonCoversTheWholeCircularHole() async throws {
        let counter = CycleCounter()
        let (window, host) = showRing(counter: counter)
        try await Task.sleep(for: .milliseconds(100))

        for point in [CGPoint(x: 52, y: 52), CGPoint(x: 52, y: 24), CGPoint(x: 52, y: 80)] {
            let expected = counter.value + 1
            click(at: point, window: window, host: host)
            try await waitUntil { counter.value == expected }
        }
        XCTAssertEqual(counter.value, 3)
    }

    func testHoleCornersAndColoredRingDoNotCycleTheMetric() async throws {
        let counter = CycleCounter()
        let (window, host) = showRing(counter: counter)
        try await Task.sleep(for: .milliseconds(100))

        let outside = [
            CGPoint(x: 24, y: 24), CGPoint(x: 78, y: 26),
            CGPoint(x: 52, y: 10), CGPoint(x: 10, y: 52)
        ]
        for point in outside {
            let expected = counter.value
            click(at: point, window: window, host: host)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertEqual(counter.value, expected, "도넛 구멍 바깥 클릭은 무시: \(point)")

            click(at: CGPoint(x: 52, y: 52), window: window, host: host)
            try await waitUntil { counter.value == expected + 1 }
        }
        XCTAssertEqual(counter.value, outside.count)
    }

    func testLegendValueStillCyclesTheMetric() async throws {
        let counter = CycleCounter()
        let (window, host) = showRing(counter: counter)
        try await Task.sleep(for: .milliseconds(100))

        click(at: CGPoint(x: 300, y: 52), window: window, host: host)
        try await waitUntil { counter.value == 1 }
        XCTAssertEqual(counter.value, 1)
    }

    // MARK: - Fixtures

    private func showRing(counter: CycleCounter) -> (NSWindow, NSView) {
        let total = TotalSpend(
            period: .today,
            slices: [
                TotalSpendSlice(
                    provider: MockData.codex, title: "Codex", amountUSD: 12,
                    tokenCount: 433_269_936, estimated: false)
            ])
        let content = TotalSpendRingContent(projection: total.projection(for: .tokens)) { counter.value += 1 }
            .frame(width: 320, height: 104)
            .background(Theme.panelBody)
            .environment(\.colorScheme, .dark)
            .environment(\.hoverTooltipsDisabled, true)
        let host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 320, height: 104)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.appearance = NSAppearance(named: .darkAqua)
        window.alphaValue = 0
        let screens = NSScreen.screens.map(\.frame)
        window.setFrameOrigin(
            NSPoint(
                x: (screens.map(\.maxX).max() ?? 0) + 1_000,
                y: (screens.map(\.maxY).max() ?? 0) + 1_000))
        window.orderFrontRegardless()
        XCTAssertFalse(window.isKeyWindow, "테스트 창이 키 창이 되면 안 됨")
        addTeardownBlock { @MainActor in
            window.contentView = nil
            window.close()
        }
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    /// host 좌상단 기준 좌표로 실제 버튼의 누름·해제 이벤트 전달.
    private func click(at point: CGPoint, window: NSWindow, host: NSView) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(
                with: type, location: NSPoint(x: point.x, y: host.bounds.height - point.y),
                modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: type == .leftMouseDown ? 1 : 0
            )
            window.sendEvent(try! XCTUnwrap(event))
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting for metric switch", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class CycleCounter {
    var value = 0
}
