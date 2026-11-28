import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class OpenAIBillingScopeRenderingTests: XCTestCase {
    private let provider = Provider(id: "openai-api", displayName: "OpenAI API", icon: .providerMark("codex"))
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let projectIDs = [
        "proj_abcdefghijklmnopqrstuvwx", "proj_ABCDEFGHIJKLMNOPQRSTUVWX",
        "proj_123456789012345678901234", "proj_zyxwvutsrqponmlkjihgfedcb"
    ]

    private var scopes: [(name: String, value: String)] {
        [
            ("organization", "Organization"),
            ("one-project", projectIDs[0]),
            ("four-projects", projectIDs.joined(separator: ", "))
        ]
    }

    func testBillingScopeStaysInsideRowsAndCardsAcrossLanguagesAndLayouts() throws {
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                for style in DashboardLayoutStyle.allCases {
                    for scope in scopes {
                        let context = "\(language.rawValue)-\(style.rawValue)-\(scope.name)"
                        let line = makeLine("scope", title: "Billing Scope", value: scope.value)
                        let row = DashboardMetricRow(model: line.dashboardRow(now: now), layoutStyle: style)
                            .padding(.horizontal, PanelMetrics.margin + DashboardGrid.cardPadding)
                            .frame(width: PanelMetrics.width, height: 64)
                        try assertFitsPanel(row, name: context, inset: PanelMetrics.margin + DashboardGrid.cardPadding)

                        let account = account([
                            line,
                            makeLine("updated", title: "Last Updated", value: "2026-11-28 01:23:45 UTC"),
                            makeLine("costs", title: "Last 30 Days", value: "EUR 123.45 · USD 123.45")
                        ])
                        let family = DashboardFamily(
                            id: provider.id, provider: provider, displayName: provider.displayName,
                            accounts: [account])
                        let card = DashboardProviderSection(family: family, layoutStyle: style) { entry in
                            DashboardAccountRows(account: entry, layoutStyle: style)
                        }
                        .padding(PanelMetrics.margin)
                        .frame(width: PanelMetrics.width)
                        try assertFitsPanel(card, name: "card-\(context)")
                        _ = try render(card.background(Color.white).clipped(), export: "card-\(context)")
                    }
                }
            }
        }
    }

    func testPinnedBillingScopeStaysInsidePriorityWithoutGrowingRows() throws {
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                var expectedHeight: Int?
                for scope in scopes {
                    let line = makeLine("scope", title: "Billing Scope", value: scope.value)
                    let board = PriorityBoard.make(accounts: [account([line])], pinned: [line.id], now: now)
                    let content = PriorityBoardList(board: board, now: now)
                        .padding(PanelMetrics.margin)
                        .frame(width: PanelMetrics.width)
                    let context = "priority-\(language.rawValue)-\(scope.name)"
                    try assertFitsPanel(content, name: context)
                    let image = try render(content.background(Color.white).clipped(), export: context)
                    if let expectedHeight {
                        XCTAssertEqual(image.height, expectedHeight, context)
                    } else {
                        expectedHeight = image.height
                    }
                }
            }
        }
    }

    func testMenuBarBoundsScopeWhileKeepingItsFullAccessibleValue() throws {
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                for scope in scopes {
                    let line = makeLine("scope", title: "Billing Scope", value: scope.value)
                    let content = menuBarContent([line])
                    let item = try XCTUnwrap(content.items.first)
                    XCTAssertEqual(item.value, L10n.metrics(scope.value))
                    let image = try XCTUnwrap(MenuBarStripRenderer.textImage(for: content))
                    XCTAssertLessThanOrEqual(image.size.width, 120, scope.name)
                    XCTAssertEqual(image.accessibilityDescription, content.accessibilityText)
                    XCTAssertTrue(try XCTUnwrap(image.accessibilityDescription).contains(item.value))
                    if scope.name == "organization" {
                        let control = MenuBarContent(items: [
                            MenuBarContent.Item(
                                id: "openai-api.control", icon: item.icon, providerName: item.providerName,
                                label: item.label, shortLabel: item.shortLabel, value: item.value)
                        ])
                        XCTAssertEqual(
                            image.size, try XCTUnwrap(MenuBarStripRenderer.textImage(for: control)).size,
                            "짧은 값의 기존 크기 유지")
                    }
                    _ = try render(
                        MenuBarTextStrip(content: content).background(Color.white),
                        export: "menubar-\(language.rawValue)-\(scope.name)")
                }
            }
        }
    }

    func testScopeAndPreciseCostsRemainCompleteInDisplayAndWidgetModels() throws {
        try L10n.withLanguage(.english) {
            let fullScope = projectIDs.joined(separator: ", ")
            let scope = makeLine("scope", title: "Billing Scope", value: fullScope)
            let preciseCosts = "EUR -1.2 · USD 0.008000000000000004"
            let costs = makeLine("costs", title: "Last 30 Days", value: preciseCosts)
            XCTAssertEqual(scope.dashboardRow(now: now).mark, .value(fullScope))
            XCTAssertEqual(scope.data.amountText, fullScope)
            XCTAssertEqual(
                costs.dashboardRow(now: now).mark, .value("EUR -1.2", detail: "USD 0.008000000000000004"))
            let content = menuBarContent([scope, costs])
            XCTAssertEqual(content.items.map(\.value), [fullScope, preciseCosts])
            XCTAssertTrue(content.accessibilityText.contains(fullScope))
            XCTAssertTrue(content.accessibilityText.contains(preciseCosts))
            let costImage = try XCTUnwrap(MenuBarStripRenderer.textImage(for: menuBarContent([costs])))
            XCTAssertGreaterThan(costImage.size.width, 120, "금액을 Billing Scope처럼 말줄임하지 않음")

            let scopeMetric = DesktopWidgetProjection.metric(scope.descriptor, line: scope, now: now)
            let costMetric = DesktopWidgetProjection.metric(costs.descriptor, line: costs, now: now)
            XCTAssertEqual(scopeMetric.value, fullScope)
            XCTAssertEqual(costMetric.value, "EUR -1.2")
            XCTAssertEqual(costMetric.detail, "USD 0.008000000000000004")
            let card = account([scope, costs])
            let sources = DesktopWidgetSource.make(
                card: card, profile: nil, descriptors: [scope.descriptor, costs.descriptor], hasSharedMetrics: false)
            let board = PriorityBoard.make(accounts: [card], pinned: [scope.id, costs.id], now: now)
            let priority = DesktopWidgetProjection.priority(board, enabled: true, sources: sources, now: now)
            XCTAssertEqual(priority.rows.map(\.value), [fullScope, preciseCosts])
        }
    }

    private func makeLine(_ id: String, title: String, value: String) -> DashboardLine {
        let descriptor = WidgetDescriptor.badge(id: "openai-api.\(id)", provider: provider, title: title)
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil, lines: [.badge(label: title, text: value)], refreshedAt: now)
        let data = WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
        return DashboardLine(descriptor: descriptor, data: data)
    }

    private func account(_ lines: [DashboardLine]) -> DashboardAccount {
        DashboardAccount(provider: provider, providerName: provider.displayName, name: nil, lines: lines)
    }

    private func menuBarContent(_ lines: [DashboardLine]) -> MenuBarContent {
        let board = PriorityBoard.make(accounts: [account(lines)], pinned: Set(lines.map(\.id)), now: now)
        return MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .pinnedOnly, now: now)
    }

    private func assertFitsPanel<Content: View>(
        _ view: Content, name: String, inset: CGFloat = 0, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let canvasWidth: CGFloat = 1_400
        let image = try render(view.frame(width: canvasWidth))
        let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: image), name, file: file, line: line)
        let left = (canvasWidth - PanelMetrics.width) / 2 + inset
        let right = (canvasWidth + PanelMetrics.width) / 2 - inset
        XCTAssertGreaterThanOrEqual(bounds.minX / 2, left, name, file: file, line: line)
        XCTAssertLessThanOrEqual(bounds.maxX / 2, right, name, file: file, line: line)
    }

    private func render<Content: View>(_ view: Content, export name: String? = nil) throws -> CGImage {
        let renderer = ImageRenderer(
            content:
                view
                .environment(\.locale, L10n.locale)
                .environment(\.colorScheme, .light)
                .environment(\.hoverTooltipsDisabled, true))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        if let name {
            let size = NSSize(width: CGFloat(image.width) / 2, height: CGFloat(image.height) / 2)
            try export(NSImage(cgImage: image, size: size), name: name)
        }
        return image
    }

    private func export(_ image: NSImage, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["EGASU_BILLING_SCOPE_SCREENSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
        try png.write(to: directory.appendingPathComponent("\(name).png"))
    }
}
