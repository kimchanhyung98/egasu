import XCTest

@testable import Egasu

@MainActor
final class MenuBarTextLabelTests: XCTestCase {
    func testIndependentOptionsForTwoAccountsWithTheSameInitials() throws {
        let names = ["Research Team", "Release Team"]
        let accounts = names.enumerated().map { index, name in
            let id = "claude@account\(index)"
            let provider = Provider(id: id, displayName: "Claude", icon: .providerMark("claude"))
            let data = WidgetData(
                title: "Weekly", icon: provider.icon, kind: .percent, used: 80, limit: 100,
                periodDurationMs: MetricPeriod.weekMs
            )
            let descriptor = WidgetDescriptor(id: "\(id).weekly", providerID: id, metricLabel: "Weekly", sample: data)
            return DashboardAccount(
                provider: provider, providerName: "Claude", name: name,
                lines: [.init(descriptor: descriptor, data: data)]
            )
        }
        let board = PriorityBoard.make(
            accounts: accounts, pinned: Set(accounts.flatMap { $0.lines.map(\.id) }), now: Date()
        )
        func render(metrics: Bool, names: Bool, privacy: Bool = false) -> MenuBarContent {
            MenuBarContentBuilder.build(
                board: board, limit: .upToTwo, selection: .pinnedOnly,
                multiAccountFamilies: MenuBarContentBuilder.multiAccountFamilies(accounts), showMetricLabels: metrics,
                showAccountNames: names, hideAccountNames: privacy
            )
        }
        let metrics = render(metrics: true, names: false)
        XCTAssertEqual(metrics.items.map(\.badge), ["RT", "RT"])
        XCTAssertEqual(metrics.items.map(\.displayedLabel), Array(repeating: L10n.metrics("Weekly"), count: 2))
        let compact = render(metrics: false, names: false)
        XCTAssertEqual(compact.items.map(\.displayedLabel), ["", ""])
        XCTAssertEqual(compact.accessibilityText, metrics.accessibilityText)
        let both = render(metrics: true, names: true)
        XCTAssertEqual(both.items.map(\.displayedLabel), names)
        XCTAssertEqual(both.items.map(\.badge), ["7d", "7d"])
        let namesOnly = render(metrics: false, names: true)
        XCTAssertEqual(namesOnly.items.map(\.displayedLabel), names)
        XCTAssertEqual(namesOnly.items.map(\.badge), [nil, nil])
        for name in names {
            XCTAssertTrue(compact.accessibilityText.contains(name))
            XCTAssertFalse(render(metrics: true, names: true, privacy: true).accessibilityText.contains(name))
        }
        let privateItems = render(metrics: true, names: true, privacy: true).items
        XCTAssertEqual(privateItems.map(\.badge), [nil, nil])
        XCTAssertEqual(privateItems.map(\.displayedLabel), metrics.items.map(\.displayedLabel))
        let compactImage = try XCTUnwrap(MenuBarStripRenderer.image(for: compact))
        let bothImage = try XCTUnwrap(MenuBarStripRenderer.image(for: both))
        XCTAssertLessThan(compactImage.size.width, bothImage.size.width)
        XCTAssertEqual(compactImage.accessibilityDescription, both.accessibilityText)
        let longName = String(repeating: "International Research ", count: 10)
        var longItem = both.items[0]
        longItem.configureText(showMetric: true, accountName: longName, periodMs: MetricPeriod.weekMs)
        let capped = try XCTUnwrap(MenuBarStripRenderer.image(for: MenuBarContent(items: [longItem])))
        XCTAssertLessThan(capped.size.width, 130, "긴 계정명은 메뉴 막대 한 항목의 폭 안에서 줄임")
    }

    func testLabelSettingsPersistAndPreviewUsesTheSamePeriods() throws {
        let suite = "MenuBarTextLabelTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DisplaySettingsStore(defaults: defaults)
        XCTAssertTrue(settings.showsMenuBarMetricLabels)
        XCTAssertFalse(settings.showsMenuBarAccountNames)
        settings.showsMenuBarMetricLabels = false
        settings.showsMenuBarAccountNames = true
        let restored = DisplaySettingsStore(defaults: defaults)
        XCTAssertFalse(restored.showsMenuBarMetricLabels)
        XCTAssertTrue(restored.showsMenuBarAccountNames)
        let preview = PriorityIconsPreview.sample(limit: .upToThree, showAccountNames: true)
        XCTAssertEqual(preview.items.map(\.badge), ["7d", "5h", nil])
        XCTAssertEqual(preview.items.map(\.displayedLabel), ["Personal", "Account 1", L10n.metrics("Weekly")])
    }
}
