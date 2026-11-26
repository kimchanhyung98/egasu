import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class ServerIssueIconTests: XCTestCase {
    func testServerIssueIconPathHasVisibleBounds() {
        for size in [CGFloat(14), CGFloat(16)] {
            let path = ServerIssueIconShape().path(in: CGRect(x: 0, y: 0, width: size, height: size))

            XCTAssertFalse(path.isEmpty)
            XCTAssertGreaterThan(path.boundingRect.width, 0)
            XCTAssertGreaterThan(path.boundingRect.height, 0)
        }
    }

    func testServiceIssueAccessibilityValueNamesProviderSeverityAndComponent() {
        let issue = ProviderServiceIssue(
            severity: .partial,
            componentName: "Claude API (api.anthropic.com)",
            checkedAt: .distantPast
        )

        XCTAssertEqual(
            L10n.withLanguage(.english) { issue.accessibilityValue(providerName: "Claude") },
            "Claude reports a partial outage for Claude API (api.anthropic.com)."
        )
    }

    func testServiceIssueWithoutStatusLinkExposesItsSummaryAsText() throws {
        let provider = Provider(
            id: "test", displayName: "Test", icon: .providerMark("codex"),
            links: [.init(label: "Dashboard", url: "https://example.invalid/dashboard")])
        let issue = ProviderServiceIssue(severity: .partial, componentName: "CLI", checkedAt: .distantPast)
        let family = DashboardFamily(
            id: provider.id, provider: provider, displayName: provider.displayName, accounts: [])
        let host = NSHostingView(rootView: DashboardProviderHeader(family: family, serviceIssue: issue))
        let panel = MenuBarPanel(contentRect: .init(x: 0, y: 0, width: 320, height: DashboardGrid.headerHeight))
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.host(host)
        host.layoutSubtreeIfNeeded()

        try withAccessibilityChildren(of: host) { children in
            let element = try XCTUnwrap(children.first { $0.accessibilityLabel?() == L10n.dashboard("Service Issue") })
            XCTAssertEqual(element.accessibilityRole?(), .staticText)
            let value: String? = element.accessibilityValue?()
            XCTAssertEqual(value, issue.accessibilityValue(providerName: family.displayName))
            XCTAssertTrue((element.accessibilityHelp?() ?? "").isEmpty)
        }
    }

    func testHeaderRoutesTheSkullCopyAndDragIndependently() async throws {
        let provider = CodexProvider.makeProvider()
        let family = DashboardFamily(
            id: provider.id, provider: provider, displayName: provider.displayName, accounts: [])
        let issue = ProviderServiceIssue(severity: .partial, componentName: "CLI", checkedAt: .distantPast)
        var urls: [URL] = []
        var copies = 0
        let didCopy = expectation(description: "Copy action received")
        var order = [family.id, "other"]
        let size = CGSize(width: 320, height: DashboardGrid.headerHeight)
        let panelSize = CGSize(width: size.width, height: 2 * size.height)
        let nextRow = CGRect(x: 0, y: size.height, width: size.width, height: size.height)
        let reorder = reorderDragGesture(
            id: family.id, coordinateSpaceName: "section", rowFrames: ["other": nextRow],
            active: .constant(nil), lift: .constant(nil), makeLift: { _ in nil },
            orderedIDs: { order },
            reorder: { target in
                guard target == "other", order.first == family.id else { return false }
                order.swapAt(0, 1)
                return true
            }
        )
        let header = DashboardProviderHeader(
            family: family, serviceIssue: issue, isRevealed: true,
            onCopyScreenshot: {
                copies += 1
                didCopy.fulfill()
                return true
            },
            reorderGesture: AnyGesture(reorder.map { _ in () })
        )
        .environment(
            \.openURL,
            OpenURLAction {
                urls.append($0)
                return .handled
            })
        let laidOut = expectation(description: "Header laid out at panel size")
        let host = NSHostingView(
            rootView: VStack(spacing: 0) {
                header.frame(height: size.height)
                Color.clear.frame(height: size.height).accessibilityHidden(true)
            }
            .frame(width: panelSize.width, height: panelSize.height)
            .coordinateSpace(name: "section")
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: { value in
                if value == panelSize { laidOut.fulfill() }
            })
        let panel = MenuBarPanel(contentRect: CGRect(origin: .zero, size: panelSize))
        panel.isReleasedWhenClosed = false
        panel.host(host)
        panel.setFrameOrigin(CGPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1000, y: 0))
        panel.orderBack(nil)
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        await fulfillment(of: [laidOut], timeout: 2)

        let (skull, copy) = try withAccessibilityChildren(of: host) { children in
            @MainActor func frame(for label: String) throws -> CGRect {
                let element = try XCTUnwrap(children.first { $0.accessibilityLabel?() == label }, label)
                let frame = try XCTUnwrap(element.accessibilityFrame?(), label)
                XCTAssertGreaterThan(frame.width, 0, label)
                return host.convert(panel.convertFromScreen(frame), from: nil)
            }
            return try (
                frame(for: L10n.dashboard("Service Issue")),
                frame(for: L10n.dashboard("Copy %@ Screenshot", family.displayName))
            )
        }
        func send(_ type: NSEvent.EventType, at x: CGFloat, y: CGFloat = DashboardGrid.headerHeight / 2) throws {
            let event = try XCTUnwrap(
                NSEvent.mouseEvent(
                    with: type, location: host.convert(CGPoint(x: x, y: y), to: nil),
                    modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                    pressure: type == .leftMouseUp ? 0 : 1
                ))
            panel.sendEvent(event)
        }

        let statusURL = try XCTUnwrap(URL(string: "https://status.openai.com/"))
        for (index, y) in [size.height - 2, size.height / 2].enumerated() {
            try send(.leftMouseDown, at: skull.midX, y: y)
            try send(.leftMouseUp, at: skull.midX, y: y)
            XCTAssertEqual(urls, Array(repeating: statusURL, count: index + 1))
        }
        try send(.leftMouseDown, at: copy.midX)
        try send(.leftMouseUp, at: copy.midX)
        let halfGap = Theme.Spacing.s / 2
        for x in [CGFloat(20), skull.minX - halfGap, skull.maxX + halfGap, size.width / 2] {
            order = [family.id, "other"]
            try send(.leftMouseDown, at: x)
            try send(.leftMouseDragged, at: x, y: nextRow.midY)
            try send(.leftMouseUp, at: x, y: nextRow.midY)
            XCTAssertEqual(order, ["other", family.id], "드래그 시작 위치 x=\(x)")
        }
        await fulfillment(of: [didCopy], timeout: 2)
        XCTAssertEqual(urls, [statusURL, statusURL])
        XCTAssertEqual(copies, 1)
    }

    private func withAccessibilityChildren<T>(of view: NSView, _ inspect: ([AnyObject]) throws -> T) rethrows -> T {
        // VoiceOver가 실행되지 않은 테스트 프로세스에서도 SwiftUI 접근성 트리를 구성.
        let enhanced = NSAccessibility.Attribute(rawValue: "AXEnhancedUserInterface")
        let previous = NSApp.accessibilityAttributeValue(enhanced)
        NSApp.accessibilitySetValue(true, forAttribute: enhanced)
        defer { NSApp.accessibilitySetValue(previous, forAttribute: enhanced) }
        return try inspect((view.accessibilityChildren() ?? []).map { $0 as AnyObject })
    }
}
