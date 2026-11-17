import XCTest
@testable import Egasu

final class CursorSpendCompletenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testOldCursorCacheRetainsEstimatedProvenanceAfterReloadAndRender() throws {
        let suite = "EgasuTests.CursorCostSource.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let history = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: DailyUsageAccumulator.dayKey(from: now), totalTokens: 100, costUSD: 5)
            ]))
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        for id in ["cursor", "cursor@12345678", "claude"] {
            cache.store(ProviderSnapshot(providerID: id, displayName: id, lines: [], usageHistory: history))
        }
        let restored = ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: [
            "cursor", "cursor@12345678", "claude"
        ])
        for id in ["cursor", "cursor@12345678"] {
            let snapshot = try XCTUnwrap(restored[id])
            let loadedHistory = try XCTUnwrap(snapshot.usageHistory)
            XCTAssertEqual(loadedHistory.estimatedCost, true)
            let rendered = UsageHistorySnapshotRenderer.render(
                local: snapshot, history: loadedHistory,
                descriptor: UsageHistoryDescriptor(
                    scope: .accountWide, estimatedCost: false, sourceNote: WidgetData.cursorUsageHistoryNote),
                now: now, combined: false
            )
            XCTAssertEqual(dollars(rendered)?.estimated, true)
            XCTAssertEqual(dollars(rendered)?.number, 5)
        }
        XCTAssertNil(restored["claude"]?.usageHistory?.estimatedCost)
    }

    func testServerReportedCostRemainsActualAfterCacheReloadAndFallbackRender() throws {
        let suite = "EgasuTests.CursorActualCost.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var lines: [MetricLine] = []
        let history = CursorUsageMapper.appendSpendLines(
            rows: [CursorUsageEvent(date: now, model: "new", tokens: TokenBreakdown(input: 100), costUSD: 0.23)],
            now: now, pricing: .empty, to: &lines
        )
        ProviderSnapshotCache(userDefaults: defaults).store(
            ProviderSnapshot(
                providerID: "cursor", displayName: "Cursor", lines: lines, usageHistory: history
            ))
        let snapshot = try XCTUnwrap(
            ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["cursor"])["cursor"])
        XCTAssertEqual(snapshot.usageHistory?.estimatedCost, false)
        let rendered = UsageHistorySnapshotRenderer.render(
            local: snapshot, history: try XCTUnwrap(snapshot.usageHistory),
            descriptor: UsageHistoryDescriptor(
                scope: .accountWide, estimatedCost: false, sourceNote: WidgetData.cursorUsageHistoryNote),
            now: now, combined: false
        )
        XCTAssertEqual(dollars(rendered)?.estimated, false)
        XCTAssertEqual(dollars(rendered)?.number, 0.23)
    }

    private func dollars(_ snapshot: ProviderSnapshot) -> MetricValue? {
        guard case .values(_, let values, _, _, _, _) = snapshot.line(label: "Today") else { return nil }
        return values.first { $0.kind == .dollars }
    }
}
