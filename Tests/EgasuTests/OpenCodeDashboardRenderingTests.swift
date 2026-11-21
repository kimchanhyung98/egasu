import SwiftUI
import XCTest
@testable import Egasu

extension DashboardSnapshotTests {
    func testOpenCodeGoMetersUseReportedUnitsOnTheSameDashboardRows() throws {
        let now = Date()
        let runtime = OpenCodeProvider()
        let periods = [
            ("Session", 24.0, MetricPeriod.sessionMs), ("Weekly", 65.0, MetricPeriod.weekMs),
            ("Monthly", 40.0, MetricPeriod.monthMs)
        ]
        let measured = periods.map { label, used, duration in
            MetricLine.progress(
                label: label, used: used, limit: 100, format: .percent,
                resetsAt: now.addingTimeInterval(Double(duration) / 2_000), periodDurationMs: duration)
        }
        let estimated = OpenCodeUsageMapper.meterLines(
            .init(
                sessionSpend: 3, weeklySpend: 8, monthlySpend: 24, monthlyPeriodMs: MetricPeriod.monthMs))
        func rows(_ lines: [MetricLine]) -> [DashboardLine] {
            let snapshot = ProviderSnapshot.make(provider: runtime.provider, plan: "Go", lines: lines, refreshedAt: now)
            return runtime.widgetDescriptors.compactMap { descriptor in
                let data = WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
                return data.hasData ? DashboardLine(descriptor: descriptor, data: data) : nil
            }
        }
        let liveRows = rows(measured)
        XCTAssertEqual(liveRows.map(\.id), ["opencode.session", "opencode.weekly", "opencode.monthly"])
        XCTAssertEqual(liveRows.map(\.data.kind), [.percent, .percent, .percent])
        XCTAssertEqual(rows(estimated).map(\.id), liveRows.map(\.id))
        XCTAssertEqual(rows(estimated).map(\.data.kind), [.dollars, .dollars, .dollars])

        try L10n.withLanguage(.korean) {
            let account = DashboardAccount(
                provider: runtime.provider, providerName: "OpenCode", name: nil, lines: liveRows)
            let family = DashboardFamily(
                id: "opencode", provider: runtime.provider, displayName: "OpenCode", accounts: [account])
            let view = DashboardProviderSection(family: family) { DashboardAccountRows(account: $0, plan: "Go") }
            let image = try render(view, appearance: .dark, name: "opencode-go-quota")
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 3)
        }
    }
}
