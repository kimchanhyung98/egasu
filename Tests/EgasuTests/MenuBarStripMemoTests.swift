import XCTest
@testable import Egasu

@MainActor
final class MenuBarStripMemoTests: XCTestCase {
    func testStyleSwitchRendersBarsAndCachesOnlyTheChosenStyle() throws {
        let content = makeContent(value: "42%")
        let text = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .text))
        let bars = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .bars))
        XCTAssertLessThan(bars.size.width, text.size.width)
        XCTAssertEqual(bars.size.height, 18)
        XCTAssertTrue(bars.isTemplate)
        XCTAssertEqual(bars.accessibilityDescription, content.accessibilityText)
        XCTAssertIdentical(bars, try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .bars)))
        XCTAssertNotIdentical(bars, try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .text)))
    }

    func testFractionChangeRendersNewBarsEvenWhenRoundedTextIsUnchanged() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%"), style: .bars))
        var changed = makeContent(value: "42%")
        var item = changed.items[0]
        item.fraction = 0.424
        changed = MenuBarContent(items: [item])
        XCTAssertNotIdentical(first, try XCTUnwrap(MenuBarStripRenderer.image(for: changed, style: .bars)))
    }

    func testBarsKeepOverflowAndUpdateMarkersAndEmptyFallback() throws {
        let plain = makeContent(value: "42%")
        let plainImage = try XCTUnwrap(MenuBarStripRenderer.image(for: plain, style: .bars))
        var updateOnly = plain
        updateOnly.updateAvailable = true
        let updateImage = try XCTUnwrap(MenuBarStripRenderer.image(for: updateOnly, style: .bars))
        XCTAssertGreaterThan(updateImage.size.width, plainImage.size.width)

        var decorated = updateOnly
        decorated.overflow = 3
        let image = try XCTUnwrap(MenuBarStripRenderer.image(for: decorated, style: .bars))
        XCTAssertGreaterThan(image.size.width, updateImage.size.width)
        XCTAssertLessThanOrEqual(image.size.height, 22)
        XCTAssertEqual(image.accessibilityDescription, decorated.accessibilityText)
        XCTAssertNil(MenuBarStripRenderer.image(for: MenuBarContent(items: []), style: .bars))
        XCTAssertIdentical(
            try XCTUnwrap(MenuBarStripRenderer.image(for: MenuBarContent(items: [], updateAvailable: true), style: .bars)),
            MenuBarStripRenderer.appIconWithUpdateDot
        )
    }

    func testEqualContentReturnsSameImageInstance() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%")))
        let second = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%")))
        XCTAssertIdentical(first, second)
    }

    func testChangedValueRendersFreshImage() throws {
        let first = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "42%")))
        let changed = try XCTUnwrap(MenuBarStripRenderer.image(for: makeContent(value: "43%")))
        XCTAssertNotIdentical(first, changed)
    }

    func testRerenderTimeAloneKeepsTheSameImageInstance() throws {
        // 순위 재계산 시각(now + 30초)은 매번 달라도 그림은 같음 — status item을 다시 그리지 않음.
        var first = makeContent(value: "42%")
        first.nextInvalidation = Date(timeIntervalSinceReferenceDate: 1_000)
        var second = makeContent(value: "42%")
        second.nextInvalidation = Date(timeIntervalSinceReferenceDate: 1_030)
        XCTAssertIdentical(
            try XCTUnwrap(MenuBarStripRenderer.image(for: first)),
            try XCTUnwrap(MenuBarStripRenderer.image(for: second))
        )
    }

    func testUpdateDotShowsEvenWithNothingToList() throws {
        var content = MenuBarContent(items: [])
        XCTAssertNil(MenuBarStripRenderer.image(for: content), "그릴 것이 없으면 호출자가 앱 아이콘 사용")
        content.updateAvailable = true
        XCTAssertIdentical(try XCTUnwrap(MenuBarStripRenderer.image(for: content)), MenuBarStripRenderer.appIconWithUpdateDot)
    }

    private func makeContent(value: String) -> MenuBarContent {
        MenuBarContent(items: [MenuBarContent.Item(
            id: "claude.session", icon: .providerMark("claude"), providerName: "Claude", badge: nil,
            label: "Session", shortLabel: "Session", value: value, fraction: 0.42
        )])
    }
}
