import SwiftUI
import XCTest
@testable import Egasu

/// All Usage의 행·계정·언어·표시 방식 렌더 검증.
@MainActor
final class DashboardSnapshotTests: XCTestCase {
    private let now = Date()

    func testAllUsageCardRendersAccountSectionsAndEveryRowKind() throws {
        for appearance in [ColorScheme.light, .dark] {
            let view = DashboardProviderSection(family: codexFamily()) { account in
                DashboardAccountRows(account: account, plan: account.name == "Account 1" ? "Pro" : "Plus")
            }
            let image = try render(view, appearance: appearance, name: "allusage-\(appearance)")
            XCTAssertEqual(image.size.width, PanelMetrics.width - PanelMetrics.margin * 2)
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 6)
        }
    }

    func testLocalizedResetTextFitsItsColumnBesideTheUsageValue() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_794_470_400)
        let samples: [(Double, TimeInterval)] = [
            (65, 22 * 3_600 + 29 * 60), (72, 23 * 3_600 + 29 * 60), (100, 32 * 3_600),
            (65, 29 * 86_400 + 23 * 3_600), (65, 364 * 86_400), (65, 395 * 86_400), (65, 700 * 86_400)
        ]
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                var models: [DashboardRowModel] = []
                for (used, interval) in samples {
                    var data = WidgetData(
                        title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
                    data.resetsAt = fixedNow.addingTimeInterval(interval)
                    data.resetDisplayMode = .relative
                    models.append(data.dashboardRow(now: fixedNow))
                }
                for format in [TimeFormatSetting.twelveHour, .twentyFourHour] {
                    models.append(
                        DashboardRowModel(
                            label: L10n.metrics("Weekly"),
                            mark: .bar(
                                fill: 0.65, severity: .normal, value: "65%", reset: format.weekdayTime(fixedNow)),
                            showsClockTimes: true
                        ))
                }
                for model in models {
                    guard case .bar(_, _, _, let reset?, _) = model.mark else {
                        return XCTFail("Expected a countdown beside the usage value")
                    }
                    let text = Text(reset)
                        .font(DashboardMetricRow.resetFont)
                        .monospacedDigit()
                        .fixedSize()
                    let image = try XCTUnwrap(ShareCardRenderer.image(for: text))
                    let width = model.showsClockTimes ? DashboardGrid.clockResetWidth : DashboardGrid.resetWidth
                    XCTAssertLessThanOrEqual(image.size.width, width, "\(language.rawValue): \(reset)")
                }
                for appearance in [ColorScheme.light, .dark] {
                    let rows = VStack(spacing: 0) {
                        ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                            DashboardMetricRow(model: model, onToggleMeterStyle: {}, onToggleResetDisplay: {})
                        }
                    }
                    .padding(.horizontal, DashboardGrid.cardPadding)
                    let image = try render(
                        rows, appearance: appearance, name: "countdown-columns-\(language.rawValue)-\(appearance)")
                    XCTAssertEqual(image.size.width, PanelMetrics.width - PanelMetrics.margin * 2)
                    XCTAssertEqual(image.size.height, DashboardGrid.rowHeight * CGFloat(models.count))
                }
            }
        }
    }

    func testCardsLayoutRendersSeparateAccountsWithExpandedMeters() throws {
        for appearance in [ColorScheme.light, .dark] {
            for language in LanguageSetting.allCases {
                try L10n.withLanguage(language) {
                    var heights: [DashboardLayoutStyle: CGFloat] = [:]
                    for style in DashboardLayoutStyle.allCases {
                        let view = DashboardProviderSection(family: codexFamily(), layoutStyle: style) { account in
                            DashboardAccountRows(
                                account: account, plan: account.name == "Account 1" ? "Pro" : "Plus", layoutStyle: style
                            )
                        }
                        let variant = "\(style.rawValue)-\(language.rawValue)-\(appearance)"
                        let image = try render(view, appearance: appearance, name: "layout-\(variant)")
                        XCTAssertEqual(image.size.width, PanelMetrics.width - PanelMetrics.margin * 2)
                        heights[style] = image.size.height
                    }
                    XCTAssertGreaterThan(try XCTUnwrap(heights[.cards]), try XCTUnwrap(heights[.minimal]))
                }
            }
        }
    }

    private func codexFamily() -> DashboardFamily {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let second = Provider(id: "codex@ab12cd34", displayName: "Codex", icon: .providerMark("codex"))
        var trend = WidgetData(title: "Usage Trend", icon: provider.icon, kind: .count, used: 0, limit: nil)
        trend.isChart = true
        trend.chartPoints = (0..<30).map { MetricChartPoint(value: Double(($0 * 37) % 11), label: "d\($0)") }
        var today = WidgetData(title: "Today", icon: provider.icon, kind: .dollars, used: 0, limit: nil)
        today.isUsagePeriod = true
        today.values = [
            MetricValue(number: 4.08, kind: .dollars), MetricValue(number: 1_200_000, kind: .count, label: "tokens")
        ]
        var yesterday = WidgetData(title: "Yesterday", icon: provider.icon, kind: .dollars, used: 0, limit: nil)
        yesterday.isUsagePeriod = true
        yesterday.hasData = false
        var watch = WidgetData(title: "Reset Watch", icon: provider.icon, kind: .percent, used: 72, limit: 100)
        watch.forecast = .init(deadline: now.addingTimeInterval(2 * 86_400), communityYesPercent: 61)
        var session = meter("Session", used: 42, resetIn: 3 * 3_600, period: 5 * 3_600_000)
        session.softLimitUsedFraction = 0.8
        let first = DashboardAccount(
            provider: provider, providerName: "Codex", name: "Account 1", isInUse: true,
            lines: [
                line("codex.session", session),
                line("codex.weekly", meter("Weekly", used: 91, resetIn: 2 * 86_400)),
                line("codex.trend", trend),
                line("codex.today", today),
                line("codex.yesterday", yesterday),
                line("codex.resetWatch", watch)
            ])
        let secondAccount = DashboardAccount(
            provider: second, providerName: "Codex", name: "Account 2",
            lines: [
                line("codex@ab12cd34.session", meter("Session", used: 100, resetIn: 1_800, period: 5 * 3_600_000)),
                line("codex@ab12cd34.weekly", meter("Weekly", used: 20, resetIn: 20 * 3_600))
            ]
        )
        return DashboardFamily(id: "codex", provider: provider, displayName: "Codex", accounts: [first, secondAccount])
    }

    private func meter(_ title: String, used: Double, resetIn: TimeInterval, period: Int = 7 * 86_400_000) -> WidgetData
    {
        var data = WidgetData(title: title, icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetIn)
        data.periodDurationMs = period
        return data
    }

    private func line(_ id: String, _ data: WidgetData) -> DashboardLine {
        DashboardLine(
            descriptor: WidgetDescriptor(
                id: id, providerID: ProviderAccountID.providerID(ofMetric: id), metricLabel: data.title, sample: data),
            data: data
        )
    }

    private func render<V: View>(_ view: V, appearance: ColorScheme, name: String) throws -> NSImage {
        let framed =
            view
            .frame(width: PanelMetrics.width - PanelMetrics.margin * 2)
            .background(Theme.panelBody)
            .environment(\.colorScheme, appearance)
            .environment(\.drawsLevelsAsShapes, true)
            .environment(\.hoverTooltipsDisabled, true)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: framed))
        try export(image, name: name)
        return image
    }

    private func export(_ image: NSImage, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["EGASU_DASHBOARD_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
        try png.write(to: url.appendingPathComponent("\(name).png"))
    }
}
