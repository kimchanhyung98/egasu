import XCTest
@testable import Egasu

/// 정상 사용 이력에서 보고되지 않은 기간만 0으로 표시.
@MainActor
final class UnreportedPeriodTests: XCTestCase {
    func testSuccessfullyReadEmptyHistoryShowsAnUnreportedPeriodAsZero() throws {
        let (store, registry) = makeStore()
        var snapshot = reading("claude")
        snapshot.usageHistory = ProviderUsageHistory(series: .init(daily: []), unknownModelsByDay: [:])
        store.snapshots["claude"] = snapshot

        let today = store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today")))

        XCTAssertTrue(today.hasData)
        XCTAssertEqual(today.selectedValues.map(\.number), [0, 0])
        XCTAssertEqual(today.selectedValues.map(\.kind), [.dollars, .count])
        XCTAssertTrue(today.isZeroUsage)
    }

    func testAReportedPeriodKeepsItsValues() throws {
        let (store, registry) = makeStore()
        var snapshot = reading("claude")
        snapshot.warning = "Some local usage files could not be read. Usage history may be incomplete."
        snapshot.isDegraded = true
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

    func testAQuotaOnlySnapshotDoesNotEstablishAnEmptyPeriod() throws {
        let (store, registry) = makeStore()
        store.snapshots["claude"] = reading("claude")

        let today = store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today")))

        XCTAssertFalse(today.hasData)
        XCTAssertTrue(today.selectedValues.isEmpty)
    }

    func testLocalReadWarningKeepsUnreportedPeriodsUnavailableDespitePartialHistory() throws {
        let (store, registry) = makeStore()
        var snapshot = reading("claude")
        snapshot.usageHistory = ProviderUsageHistory(
            series: .init(daily: [.init(date: "2026-01-02", totalTokens: 100, costUSD: 0.04)]),
            unknownModelsByDay: [:]
        )
        snapshot.warning = "Some local usage files could not be read. Usage history may be incomplete."
        store.snapshots["claude"] = snapshot

        for id in ["claude.today", "claude.yesterday", "claude.last30"] {
            let period = store.data(for: try XCTUnwrap(registry.descriptor(id: id)))
            XCTAssertFalse(period.hasData, id)
            XCTAssertTrue(period.selectedValues.isEmpty, id)
        }
    }

    func testDegradationWithoutWarningKeepsAnUnreportedPeriodUnavailable() throws {
        let (store, registry) = makeStore()
        var snapshot = reading("claude")
        snapshot.usageHistory = ProviderUsageHistory(series: .init(daily: []), unknownModelsByDay: [:])
        snapshot.isDegraded = true
        store.snapshots["claude"] = snapshot

        let today = store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today")))

        XCTAssertFalse(today.hasData)
        XCTAssertTrue(today.selectedValues.isEmpty)
    }

    func testAReportedDollarOnlyZeroIsKeptAndAnOmittedPeriodStaysUnavailable() throws {
        let (store, registry) = makeStore()
        var snapshot = reading("openrouter")
        snapshot.lines.append(.values(label: "This Week", values: [MetricValue(number: 0, kind: .dollars)]))
        store.snapshots["openrouter"] = snapshot

        let week = store.data(for: try XCTUnwrap(registry.descriptor(id: "openrouter.week")))
        let month = store.data(for: try XCTUnwrap(registry.descriptor(id: "openrouter.month")))

        XCTAssertTrue(week.hasData)
        XCTAssertEqual(week.selectedValues.map(\.number), [0])
        XCTAssertEqual(week.selectedValues.map(\.kind), [.dollars])
        XCTAssertFalse(month.hasData)
        XCTAssertTrue(month.selectedValues.isEmpty)
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
