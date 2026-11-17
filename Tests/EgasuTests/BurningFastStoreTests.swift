import XCTest
@testable import Egasu

@MainActor
final class BurningFastStoreTests: XCTestCase {
    func testTimeRecoveryDoesNotRestoreAnOldLatchOnTheNextCloseReading() async throws {
        for evaluateTime in [false, true] {
            let suite = "EgasuTests.BurningFast.Time.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let start = Date(timeIntervalSince1970: 1_800_000_000)
            let period: TimeInterval = 5 * 3600
            var clock = start.addingTimeInterval(period * 0.50)
            let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
            let descriptor = WidgetDescriptor(
                id: "test.session", providerID: "test", metricLabel: "Session",
                sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 0, limit: 100))
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]), providers: [],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
                defaults: defaults, now: { clock })
            func report(_ used: Double) {
                store.snapshots[provider.id] = ProviderSnapshot(
                    providerID: provider.id, displayName: provider.displayName,
                    lines: [
                        .progress(
                            label: "Session", used: used, limit: 100, format: .percent,
                            resetsAt: start.addingTimeInterval(period), periodDurationMs: Int(period * 1000))
                    ],
                    refreshedAt: clock)
            }

            report(60)
            XCTAssertNotNil(store.burningFastWindows[descriptor.id])
            clock = start.addingTimeInterval(period * 0.65)
            report(62)
            XCTAssertNotNil(store.burningFastWindows[descriptor.id], "Close까지의 회복은 기존 빠른 소진 상태 유지")
            clock = start.addingTimeInterval(period * 0.70)
            let line = DashboardLine(descriptor: descriptor, data: store.data(for: descriptor))
            XCTAssertFalse(try XCTUnwrap(store.burningFast).contains(line, now: clock))
            if evaluateTime {
                await store.evaluateNotifications(now: clock)
                XCTAssertNil(store.burningFastWindows[descriptor.id])
            }

            clock = start.addingTimeInterval(period * 0.71)
            report(66)
            XCTAssertNil(store.burningFastWindows[descriptor.id], "회복 후 Close만으로 빠른 소진 재진입 금지")
            clock = start.addingTimeInterval(period * 0.72)
            report(80)
            XCTAssertNotNil(store.burningFastWindows[descriptor.id], "실제 빠른 소진 재진입은 다시 기록")
        }
    }
}
