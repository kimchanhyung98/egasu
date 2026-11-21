import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class DashboardLiveRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPopulatedTrendKeepsItsDetailAndSource() {
        var data = sample(title: "Usage Trend")
        data.isChart = true
        data.chartPoints = [.init(value: 120, label: "2026-11-18")]
        data.chartNote = "Local session history"
        for style in DashboardLayoutStyle.allCases {
            let row = liveRow(data, style: style)
            XCTAssertTrue(row.hasDetail)
            XCTAssertEqual(row.valueTooltip(data, now: now), data.chartNote)
            var empty = data
            empty.hasData = false
            XCTAssertFalse(liveRow(empty, style: style).hasDetail)
            empty.hasData = true
            empty.chartPoints = []
            XCTAssertFalse(liveRow(empty, style: style).hasDetail)
        }
    }

    func testSoftLimitTooltipConfirmsCrossingAndKeepsTheUsedQualifierInLeftMode() {
        L10n.withLanguage(.english) {
            for mode in [WidgetDisplayMode.used, .remaining] {
                var data = sample()
                data.displayMode = mode
                data.softLimitUsedFraction = 0.95
                data.softLimitReadingExpiresAt = now.addingTimeInterval(15)
                data.used = 94
                XCTAssertEqual(liveRow(data).paceTooltip(data, now: now), "Soft limit at 95% used")
                data.used = 95
                XCTAssertEqual(liveRow(data).paceTooltip(data, now: now), "Soft limit reached at 95% used")
            }
        }
    }

    func testOnlyReachedRowsScheduleAOneOffUpdateAtTheReadingExpiry() throws {
        let expiry = now.addingTimeInterval(15)
        var data = sample()
        data.softLimitUsedFraction = 0.9
        data.softLimitReadingExpiresAt = expiry
        XCTAssertNil(liveRow(data).schedule)
        data.used = 95
        let oneOff = try XCTUnwrap(liveRow(data).schedule)
        XCTAssertEqual(Array(oneOff.entries(from: now, mode: .normal).prefix(4)), [now, expiry])
        data.resetsAt = now.addingTimeInterval(300)
        let countdown = try XCTUnwrap(liveRow(data).schedule)
        XCTAssertEqual(
            Array(countdown.entries(from: now, mode: .normal).prefix(4)),
            [now, expiry, now.addingTimeInterval(30), now.addingTimeInterval(60)]
        )
    }

    func testExpiredForecastTooltipDropsTheOldVoteAndDeadline() {
        var data = sample(title: "Reset Watch")
        data.forecast = .init(deadline: now.addingTimeInterval(60), communityYesPercent: 79)
        L10n.withLanguage(.english) {
            let row = liveRow(data)
            XCTAssertTrue(row.valueTooltip(data, now: now)?.contains("79%") == true)
            XCTAssertNil(row.valueTooltip(data, now: now.addingTimeInterval(61)))
            XCTAssertNil(data.forecastTooltip(now: now.addingTimeInterval(61)))
            data.forecast?.refreshFailed = true
            XCTAssertEqual(
                liveRow(data).valueTooltip(data, now: now.addingTimeInterval(61)), "Unavailable · Retry later")
        }
    }

    func testCachedForecastFailureStaysVisibleInMinimalAndCards() throws {
        var data = sample(title: "Reset Watch")
        data.forecast = .init(deadline: now.addingTimeInterval(3600), refreshFailed: true)
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                let model = data.dashboardRow(now: now)
                guard case .bar(_, _, _, let reset, _) = model.mark else {
                    return XCTFail("Expected cached forecast")
                }
                XCTAssertEqual(reset, L10n.metrics("Failed"))
                XCTAssertEqual(model.cardReset, L10n.metrics("Cached forecast · Refresh failed"))
                let image = try XCTUnwrap(
                    ShareCardRenderer.image(
                        for: Text(try XCTUnwrap(reset)).font(DashboardMetricRow.resetFont).fixedSize()))
                XCTAssertLessThanOrEqual(image.size.width, DashboardGrid.resetWidth)
            }
        }
    }

    func testBothLayoutsRenderTheTrendAndCachedRefreshFailure() throws {
        try L10n.withLanguage(.english) {
            var trend = sample(title: "Usage Trend")
            trend.isChart = true
            trend.chartPoints = [.init(value: 20, label: "Day 1"), .init(value: 120, label: "Day 2")]
            var forecast = sample(title: "Reset Watch")
            forecast.forecast = .init(deadline: now.addingTimeInterval(3600), refreshFailed: true)
            var chartHeights: [DashboardLayoutStyle: Int] = [:]

            for style in DashboardLayoutStyle.allCases {
                let chart = try render(trend, style: style)
                chartHeights[style] = chart.height
                let pixels = try XCTUnwrap(chart.dataProvider?.data) as Data
                let bytes = [UInt8](pixels)
                var hasBluePixel = false
                for offset in stride(from: 0, to: bytes.count - 3, by: 4) {
                    let red = Int(bytes[offset])
                    let green = Int(bytes[offset + 1])
                    let blue = Int(bytes[offset + 2])
                    if blue > red + 30 && blue > green + 10 {
                        hasBluePixel = true
                        break
                    }
                }
                XCTAssertTrue(hasBluePixel, "\(style): Usage Trend 막대 표시")

                let failure = try render(forecast, style: style)
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.recognitionLanguages = ["en-US"]
                request.usesLanguageCorrection = false
                try VNImageRequestHandler(cgImage: failure).perform([request])
                let text =
                    request.results?.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") ?? ""
                XCTAssertTrue(text.lowercased().contains("failed"), "\(style): \(text)")
            }
            XCTAssertGreaterThan(try XCTUnwrap(chartHeights[.cards]), try XCTUnwrap(chartHeights[.minimal]))
        }
    }

    func testTrendSummaryLocalizesDayCountRangeAndMiddlePeak() {
        let points = [
            MetricChartPoint(value: 120, label: "Day 1", valueLabel: "120"),
            MetricChartPoint(value: 240, label: "Day 2", valueLabel: "240"),
            MetricChartPoint(value: 10, label: "Day 3", valueLabel: "10")
        ]
        let summaries: [(LanguageSetting, String)] = [
            (.english, "3 days, Day 1 to Day 3, peak 240 tokens."),
            (.korean, "Day 1부터 Day 3까지 3일, 최대 240 토큰."),
            (.japanese, "Day 1からDay 3までの3日間、最大240 トークン。")
        ]
        for (language, expected) in summaries {
            L10n.withLanguage(language) {
                for style in DashboardLayoutStyle.allCases {
                    let row = DashboardMetricRow(
                        model: .init(label: "Usage Trend", mark: .chart),
                        chartPoints: points, layoutStyle: style)
                    XCTAssertEqual(row.chartAccessibilitySummary, expected)
                }
                let empty = DashboardMetricRow(model: .init(label: "Usage Trend", mark: .chart))
                XCTAssertEqual(empty.chartAccessibilitySummary, "")
            }
        }
    }

    private func render(_ data: WidgetData, style: DashboardLayoutStyle) throws -> CGImage {
        let row = DashboardMetricRow(
            model: data.dashboardRow(now: now), chartPoints: data.chartPoints, layoutStyle: style
        )
        .frame(width: PanelMetrics.width - PanelMetrics.margin * 2)
        .padding(8)
        .background(Color.white)
        .environment(\.colorScheme, .light)
        .environment(\.hoverTooltipsDisabled, true)
        .environment(\.drawsLevelsAsShapes, true)
        let renderer = ImageRenderer(content: row)
        renderer.scale = 2
        let rendered = try XCTUnwrap(renderer.cgImage)
        let context = try XCTUnwrap(
            CGContext(
                data: nil, width: rendered.width, height: rendered.height, bitsPerComponent: 8,
                bytesPerRow: rendered.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ))
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height))
        return try XCTUnwrap(context.makeImage())
    }

    func testDashboardColorsUseTheSharedRemainingLimitsEvenWhenPacingDiffers() {
        var data = sample()
        data.priorityLimits = PriorityLimits(warning: 60, critical: 20)
        data.resetsAt = now.addingTimeInterval(4 * 3600)
        data.periodDurationMs = 5 * 3600 * 1000
        for (used, expected) in [(30.0, WidgetData.MeterSeverity.normal), (40, .warning), (80, .critical)] {
            data.used = used
            guard case .bar(_, let severity, _, _, _) = data.dashboardRow(now: now).mark else {
                return XCTFail("Expected a quota meter")
            }
            XCTAssertEqual(severity, expected)
        }
    }

    func testEmptyAccountsHideWithoutRemovingWaitingOrFailedAccounts() {
        let provider = MockData.codex
        var account = DashboardAccount(provider: provider, providerName: "Codex", name: "Work", lines: [])
        XCTAssertFalse(account.isVisible(headerNotice: { _ in nil }))
        XCTAssertTrue(account.isVisible(headerNotice: { _ in "Sign in again" }))
        account.waitingMetricIDs = ["codex.weekly"]
        XCTAssertTrue(account.isVisible(headerNotice: { _ in nil }))
    }

    private func sample(title: String = "Weekly") -> WidgetData {
        WidgetData(title: title, icon: .providerMark("codex"), kind: .percent, used: 50, limit: 100)
    }

    private func liveRow(_ data: WidgetData, style: DashboardLayoutStyle = .minimal) -> DashboardLiveRow {
        let descriptor = WidgetDescriptor(id: "codex.test", providerID: "codex", metricLabel: data.title, sample: data)
        return DashboardLiveRow(line: .init(descriptor: descriptor, data: data), layoutStyle: style)
    }
}
