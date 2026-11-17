import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class DashboardLiveRowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testPopulatedTrendKeepsItsDetailAndSourceInBothLayouts() {
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
                data.used = 94
                XCTAssertEqual(liveRow(data).paceTooltip(data, now: now), "Soft limit at 95% used")
                data.used = 95
                XCTAssertEqual(liveRow(data).paceTooltip(data, now: now), "Soft limit reached at 95% used")
            }
        }
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
