import XCTest
@testable import Egasu

/// 사용량을 가져온 계정의 보고 없는 기간 행은 0, 아직 못 가져온 계정은 "No data".
@MainActor
final class UnreportedPeriodTests: XCTestCase {
    func testAReadAccountShowsAnUnreportedPeriodAsZero() throws {
        let (store, registry) = makeStore()
        store.snapshots["claude"] = reading("claude")

        let today = store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today")))

        XCTAssertTrue(today.hasData)
        XCTAssertEqual(today.selectedValues.map(\.number), [0, 0])
        XCTAssertEqual(today.selectedValues.map(\.kind), [.dollars, .count])
        XCTAssertTrue(today.isZeroUsage)
    }

    func testAReportedPeriodKeepsItsValues() throws {
        let (store, registry) = makeStore()
        var snapshot = reading("claude")
        snapshot.lines.append(
            .values(
                label: "Today",
                values: [
                    MetricValue(number: 4.08, kind: .dollars),
                    MetricValue(number: 1_200_000, kind: .count, label: "tokens")
                ]))
        store.snapshots["claude"] = snapshot

        let today = store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today")))

        XCTAssertEqual(today.selectedValues.map(\.number), [4.08, 1_200_000])
    }

    func testAnAccountWithoutAReadingKeepsNoData() throws {
        let (store, registry) = makeStore()
        XCTAssertFalse(store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today"))).hasData)
    }

    func testAFailedReadingKeepsNoData() throws {
        let (store, registry) = makeStore()
        store.snapshots["claude"] = .init(
            providerID: "claude", displayName: "Claude",
            lines: [
                .badge(label: MetricLine.errorBadgeLabel, text: "Refresh failed")
            ])
        XCTAssertFalse(store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today"))).hasData)
    }

    func testADollarOnlyPeriodFillsOneZero() throws {
        let (store, registry) = makeStore()
        store.snapshots["openrouter"] = reading("openrouter")

        let week = store.data(for: try XCTUnwrap(registry.descriptor(id: "openrouter.week")))

        XCTAssertEqual(week.selectedValues.map(\.number), [0])
        XCTAssertEqual(week.selectedValues.map(\.kind), [.dollars])
    }

    func testUsageTrendStaysNoData() throws {
        let (store, registry) = makeStore()
        store.snapshots["claude"] = reading("claude")
        XCTAssertFalse(store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.trend"))).hasData)
    }

    private func makeStore() -> (WidgetDataStore, WidgetRegistry) {
        let name = "EgasuTests.UnreportedPeriod.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        let registry = WidgetRegistry.from(ProviderCatalog.make())
        return (WidgetDataStore(registry: registry, providers: [], defaults: defaults), registry)
    }

    private func reading(_ providerID: String) -> ProviderSnapshot {
        .init(
            providerID: providerID, displayName: providerID,
            lines: [
                .progress(
                    label: "Weekly", used: 30, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
            ])
    }
}
