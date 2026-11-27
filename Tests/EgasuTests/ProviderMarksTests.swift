import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class ProviderMarksTests: XCTestCase {
    func testFallbackSymbolIsDecorativeBesideTextAndKeepsButtonLabel() throws {
        let icon = IconSource.providerMark("qwencloud")
        let header = VStack {
            SheetHeader(icon: icon, title: "QwenCloud", message: "Status")
            Button(action: {}) { ProviderIcon(source: icon) }
                .accessibilityLabel("Open QwenCloud")
        }
        let host = NSHostingView(rootView: header.environment(\.accessibilityEnabled, true))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 160),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        window.setContentSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()

        func descendants(of element: AnyObject) -> [AnyObject] {
            (element.accessibilityChildren?() ?? []).map { $0 as AnyObject }.flatMap { [$0] + descendants(of: $0) }
        }
        let children = descendants(of: host)
        let texts: [String] = children.filter { $0.accessibilityRole?() == .staticText }.compactMap {
            $0.accessibilityValue?()
        }
        XCTAssertFalse(children.contains { $0.accessibilityRole?() == .image })
        XCTAssertTrue(texts.contains("QwenCloud"))
        let button = try XCTUnwrap(children.first { $0.accessibilityRole?() == .button })
        XCTAssertEqual(button.accessibilityLabel?(), "Open QwenCloud")
    }

    func testGrokResolvesToVectorMarkNotBoltFallback() {
        let mark = ProviderMarks.mark(for: "grok")
        XCTAssertNotNil(mark, "Grok must load a real vector mark instead of the bolt.fill fallback")
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Grok mark must carry SVG path data")
    }

    func testDevinResolvesToVectorMark() {
        let mark = ProviderMarks.mark(for: "devin")
        XCTAssertNotNil(mark)
        XCTAssertFalse(mark?.path.isEmpty ?? true, "Devin mark must carry SVG path data")
    }

    func testStandardProviderMarksLoad() {
        for id in ["claude", "codex", "cursor", "kimi", "kiro"] {
            let mark = ProviderMarks.mark(for: id)
            XCTAssertNotNil(mark, "\(id) should load")
            XCTAssertFalse(mark?.path.isEmpty ?? true, "\(id) mark must carry SVG path data")
        }
    }

    func testKimiMarkUsesSupportedCommandsAndParsesFullArtwork() throws {
        let mark = try XCTUnwrap(ProviderMarks.mark(for: "kimi"))

        XCTAssertFalse(mark.path.contains("a"))
        XCTAssertFalse(mark.path.contains("A"))
        XCTAssertGreaterThan(SVGPath.parse(mark.path).cgPath.boundingBoxOfPath.height, 15)
    }
}
