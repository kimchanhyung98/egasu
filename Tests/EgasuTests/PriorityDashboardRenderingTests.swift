import SwiftUI
import XCTest
@testable import Egasu

extension DashboardSnapshotTests {
    func testAllClearPriorityRendersAllUsageLinkWithoutPins() throws {
        let account = DashboardAccount(
            provider: MockData.codex, providerName: "Codex", name: nil,
            lines: [line("codex.weekly", meter("Weekly", used: 10, resetIn: 3 * 86_400))])
        let board = PriorityBoard.make(accounts: [account], now: now)
        XCTAssertEqual(board.summary, .allClear)
        try L10n.withLanguage(.english) {
            let content = PriorityBoardList(board: board, now: now, onShowAllUsage: {})
                .padding(PanelMetrics.margin)
                .frame(width: PanelMetrics.width - PanelMetrics.margin * 2)
                .background(Theme.panelBody)
                .environment(\.colorScheme, .light)
            let host = NSHostingView(rootView: content)
            let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: .aqua)
            window.contentView = host
            window.setContentSize(host.fittingSize)
            defer { window.close() }
            let image = NSImage(size: host.bounds.size)
            image.addRepresentation(try settingsBitmap(in: host))
            try export(image, name: "priority-all-clear-light")
            let shareImage = try render(
                PriorityBoardList(board: board, now: now).padding(PanelMetrics.margin), appearance: .light)
            XCTAssertGreaterThan(image.size.height, shareImage.size.height)
        }
    }
}
