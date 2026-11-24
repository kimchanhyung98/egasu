import Foundation
import XCTest
@testable import Egasu

final class ProviderSnapshotCachePersistenceBoundaryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.75)

    private func reading(_ id: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id, displayName: id,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now, quotaObservedAt: now.addingTimeInterval(-2))
    }

    private func fixture() throws -> (UserDefaults, String) {
        let suite = "EgasuTests.CacheWriteBoundary." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        return (defaults, suite)
    }

    func testRetainedEditCannotReplaceDifferentStoredQuotaForSameAccount() throws {
        for difference in ["quota", "time", "observation"] {
            let (defaults, suite) = try fixture()
            let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
            let cli = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
            let original = reading("codex", used: 10)
            app.store(original, producedByIdentityKey: "account")
            var other = difference == "quota" ? reading("codex", used: 80) : original
            if difference == "time" { other.refreshedAt = now.addingTimeInterval(-5) }
            if difference == "observation" { other.quotaObservedAt = now.addingTimeInterval(-4) }
            if difference == "time" { defaults.removeObject(forKey: "openusage.providerSnapshots.v10") }
            cli.store(other, producedByIdentityKey: "account")
            var retained = original
            retained.warning = "new history"
            app.store(retained, producedByIdentityKey: "account", markSessionFresh: false)

            XCTAssertEqual(app.snapshot(providerID: "codex")?.warning, retained.warning, difference)
            let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
            let persisted = try XCTUnwrap(reader.loadSnapshots(providerIDs: ["codex"])["codex"])
            XCTAssertEqual(persisted.lines, other.lines, difference)
            XCTAssertEqual(persisted.refreshedAt, other.refreshedAt, difference)
            XCTAssertNil(persisted.warning, difference)
        }
    }

    func testChangedHistoryRowsPublishForMatchingQuotaWithFractionalDates() throws {
        let (defaults, suite) = try fixture()
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        var original = reading("codex", used: 10)
        original.lines = [
            .progress(label: "Session", used: 10, limit: 100, format: .percent, resetsAt: now.addingTimeInterval(150)),
            .text(label: "Today", value: "first")
        ]
        app.store(original, producedByIdentityKey: "account")
        var retained = original
        retained.usageHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        retained.lines[1] = .text(label: "Today", value: "updated")
        retained.warning = "history updated"
        app.store(retained, producedByIdentityKey: "account", markSessionFresh: false)
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        let result = try XCTUnwrap(reader.loadSnapshots(providerIDs: ["codex"])["codex"])
        XCTAssertEqual(result.line(label: "Today"), retained.line(label: "Today"))
        XCTAssertEqual(result.warning, retained.warning)
        XCTAssertEqual(result.refreshedAt, original.refreshedAt)
    }

    func testFailedEncodingKeepsFirstSessionReadingAfterAnotherCardIsPublished() throws {
        let (defaults, suite) = try fixture()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        let local = reading("codex", used: .infinity)
        cache.store(local, producedByIdentityKey: "local")
        cache.store(reading("claude", used: 25))
        XCTAssertEqual(cache.snapshot(providerID: "codex")?.lines, local.lines)
        XCTAssertEqual(cache.producedByIdentityKey(providerID: "codex"), "local")
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertNil(reader.loadSnapshots(providerIDs: ["codex"])["codex"])
        XCTAssertNotNil(reader.loadSnapshots(providerIDs: ["claude"])["claude"])
    }

}

final class HoldingCacheDefaults: UserDefaults {
    var directory: URL?

    override func synchronize() -> Bool {
        if let directory {
            self.directory = nil
            do {
                try Data().write(to: directory.appendingPathComponent("ready"))
            } catch {
                XCTFail("Could not signal that the cache lock was acquired: \(error)")
                return false
            }
            let deadline = ContinuousClock.now + .seconds(3)
            while !FileManager.default.fileExists(atPath: directory.appendingPathComponent("continue").path),
                ContinuousClock.now < deadline
            {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return super.synchronize()
    }
}
