import Foundation
import XCTest
@testable import Egasu

final class ProviderSnapshotCacheSharedWriteTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ id: String, used: Double) -> ProviderSnapshot {
        ProviderSnapshot(
            providerID: id, displayName: id,
            lines: [.progress(label: "Session", used: used, limit: 100, format: .percent)],
            refreshedAt: now)
    }

    func testAnotherWriterDoesNotRestoreOtherCardsFromItsOldMirror() throws {
        let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        app.store(reading("codex", used: 10), producedByIdentityKey: "codex-account")
        let cli = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        cli.store(reading("codex", used: 80), producedByIdentityKey: "new-codex-account")

        app.store(reading("claude", used: 35), producedByIdentityKey: "claude-account")

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, reading("codex", used: 80).lines)
        XCTAssertEqual(reloaded.producedByIdentityKey(providerID: "codex"), "new-codex-account")
    }

    func testClearingTheStoredCacheDoesNotResurrectOtherCardsFromAnOldMirror() throws {
        let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        app.store(reading("codex", used: 10))
        defaults.removeObject(forKey: "openusage.providerSnapshots.v10")

        app.store(reading("claude", used: 35))

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertNil(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"])
    }

    func testOtherCardWriteKeepsThisSessionsReadingSeparateFromExternalUpdates() throws {
        for providerID in ["opencode", "codex"] {
            let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
            var local = reading(providerID, used: 10)
            local.liveQuotaAccountKey = "this-session-account"
            app.store(local)
            ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
                .store(reading(providerID, used: 80))

            app.store(reading("claude", used: 35))

            XCTAssertEqual(app.snapshot(providerID: providerID)?.lines, local.lines)
            XCTAssertEqual(app.snapshot(providerID: providerID)?.liveQuotaAccountKey, local.liveQuotaAccountKey)
            let reloaded = ProviderSnapshotCache(
                userDefaults: defaults, storageDomainName: suite, ignoresPersistedSnapshotsFor: [])
            XCTAssertEqual(
                reloaded.loadSnapshots(providerIDs: [providerID])[providerID]?.lines,
                reading(providerID, used: 80).lines)
        }
    }

    func testHistoryOnlyWriteDoesNotReviveACardRemovedFromStorage() throws {
        let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        var retained = reading("codex", used: 10)
        app.store(retained, producedByIdentityKey: "account")
        retained.usageHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2027-01-15", totalTokens: 100, costUSD: 1)
            ]))
        defaults.removeObject(forKey: "openusage.providerSnapshots.v10")

        app.store(retained, producedByIdentityKey: "account", markSessionFresh: false)

        XCTAssertNil(defaults.object(forKey: "openusage.providerSnapshots.v10"))
        XCTAssertNil(app.snapshot(providerID: "codex"))
        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertNil(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"])
    }

    func testMemoryOnlyPreflightDoesNotPublishItsReading() throws {
        let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite).store(reading("codex", used: 10))
        let preflight = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, persistsWrites: false)
        preflight.store(reading("codex", used: 80))
        XCTAssertEqual(
            preflight.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, reading("codex", used: 80).lines)
        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, reading("codex", used: 10).lines)
    }

    func testOlderQuotaOrHistoryWriteDoesNotReplaceANewerSameSecondReading() throws {
        for markFresh in [false, true] {
            for changedIdentity in [false, true] {
                let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
                let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
                defer { defaults.removePersistentDomain(forName: suite) }
                let app = ProviderSnapshotCache(
                    userDefaults: defaults, storageDomainName: suite, now: { self.now.addingTimeInterval(1) })
                var old = reading("codex", used: 10)
                old.refreshedAt = now.addingTimeInterval(0.1001)
                app.store(old, producedByIdentityKey: "old-account")
                var latest = reading("codex", used: 80)
                latest.refreshedAt = now.addingTimeInterval(0.1002)
                latest.liveQuotaObservedAt = latest.refreshedAt
                let identity = changedIdentity ? "new-account" : "old-account"
                ProviderSnapshotCache(
                    userDefaults: defaults, storageDomainName: suite, now: { self.now.addingTimeInterval(1) }
                ).store(latest, producedByIdentityKey: identity)
                old.usageHistory = ProviderUsageHistory(
                    series: DailyUsageSeries(daily: [
                        DailyUsageEntry(date: "2027-01-15", totalTokens: 100, costUSD: 1)
                    ]))

                app.store(old, producedByIdentityKey: "old-account", markSessionFresh: markFresh)

                let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
                let restored = try XCTUnwrap(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"])
                XCTAssertEqual(restored.lines, latest.lines)
                XCTAssertEqual(restored.refreshedAt, latest.refreshedAt)
                XCTAssertEqual(restored.liveQuotaObservedAt, latest.liveQuotaObservedAt)
                XCTAssertNil(restored.usageHistory)
                XCTAssertEqual(reloaded.producedByIdentityKey(providerID: "codex"), identity)
            }
        }
    }

    func testHistoryOnlyWriteCannotReplaceAnotherAccountAtTheSameTimestamp() throws {
        let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        app.store(reading("codex", used: 10), producedByIdentityKey: "old-account")
        ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
            .store(reading("codex", used: 80), producedByIdentityKey: "new-account")

        app.store(reading("codex", used: 10), producedByIdentityKey: "old-account", markSessionFresh: false)

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, reading("codex", used: 80).lines)
        XCTAssertEqual(reloaded.producedByIdentityKey(providerID: "codex"), "new-account")
    }

    func testNewLiveReadingCanReplaceFutureCacheAfterTheClockMovesBack() throws {
        let suite = "EgasuTests.SharedCache.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        var future = reading("codex", used: 80)
        future.refreshedAt = now.addingTimeInterval(600)
        cache.store(future, producedByIdentityKey: "account")

        cache.store(reading("codex", used: 10), producedByIdentityKey: "account")

        let reloaded = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(reloaded.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, reading("codex", used: 10).lines)
    }

    func testIndependentWritersAndFreshReaderKeepBothCards() throws {
        let suite = "EgasuTests.SharedCache.Process.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try fixtureProcess("app", suite: suite, directory: directory)
        defer { if app.isRunning { app.terminate() } }
        try waitForFile(directory.appendingPathComponent("ready"))
        let cli = try fixtureProcess("cli", suite: suite, directory: directory)
        cli.waitUntilExit()
        XCTAssertEqual(cli.terminationStatus, 0, output(of: cli))
        try Data().write(to: directory.appendingPathComponent("continue"))
        app.waitUntilExit()
        XCTAssertEqual(app.terminationStatus, 0, output(of: app))
        let reader = try fixtureProcess("reader", suite: suite, directory: directory)
        reader.waitUntilExit()
        XCTAssertEqual(reader.terminationStatus, 0, output(of: reader))
    }

    func testConcurrentWriterProcessesPublishBothCardsBeforeExiting() throws {
        let suite = "EgasuTests.SharedCache.Process.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let codex = try fixtureProcess("parallel-codex", suite: suite, directory: directory)
        let claude = try fixtureProcess("parallel-claude", suite: suite, directory: directory)
        defer {
            if codex.isRunning { codex.terminate() }
            if claude.isRunning { claude.terminate() }
        }
        try waitForFile(directory.appendingPathComponent("parallel-codex"))
        try waitForFile(directory.appendingPathComponent("parallel-claude"))
        try Data().write(to: directory.appendingPathComponent("continue"))
        codex.waitUntilExit()
        claude.waitUntilExit()
        XCTAssertEqual(codex.terminationStatus, 0, output(of: codex))
        XCTAssertEqual(claude.terminationStatus, 0, output(of: claude))
        let reader = try fixtureProcess("reader", suite: suite, directory: directory)
        reader.waitUntilExit()
        XCTAssertEqual(reader.terminationStatus, 0, output(of: reader))
    }

    func testChildProcessFixture() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let action = environment["EGASU_CACHE_FIXTURE_ACTION"],
            let suite = environment["EGASU_CACHE_FIXTURE_SUITE"],
            let path = environment["EGASU_CACHE_FIXTURE_DIRECTORY"]
        else { return }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = URL(fileURLWithPath: path)
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        switch action {
        case "app":
            cache.store(reading("codex", used: 10), producedByIdentityKey: "old-account")
            XCTAssertTrue(defaults.synchronize())
            try Data().write(to: directory.appendingPathComponent("ready"))
            try waitForFile(directory.appendingPathComponent("continue"))
            cache.store(reading("claude", used: 35), producedByIdentityKey: "claude-account")
        case "cli":
            cache.store(reading("codex", used: 80), producedByIdentityKey: "new-account")
        case "reader":
            XCTAssertEqual(
                cache.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, reading("codex", used: 80).lines)
            XCTAssertEqual(
                cache.loadSnapshots(providerIDs: ["claude"])["claude"]?.lines, reading("claude", used: 35).lines)
            XCTAssertEqual(cache.producedByIdentityKey(providerID: "codex"), "new-account")
            XCTAssertEqual(cache.producedByIdentityKey(providerID: "claude"), "claude-account")
        case "parallel-codex", "parallel-claude":
            _ = cache.loadSnapshots(providerIDs: ["codex", "claude"])
            try Data().write(to: directory.appendingPathComponent(action))
            try waitForFile(directory.appendingPathComponent("continue"))
            let isCodex = action == "parallel-codex"
            for _ in 0..<20 {
                cache.store(
                    reading(isCodex ? "codex" : "claude", used: isCodex ? 80 : 35),
                    producedByIdentityKey: isCodex ? "new-account" : "claude-account")
            }
        default:
            XCTFail("Unknown cache fixture action")
        }
    }

    private func fixtureProcess(_ action: String, suite: String, directory: URL) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = [
            "xctest", "-XCTest", "EgasuTests.ProviderSnapshotCacheSharedWriteTests/testChildProcessFixture",
            Bundle(for: Self.self).bundleURL.path
        ]
        var environment = ProcessInfo.processInfo.environment
        environment["EGASU_CACHE_FIXTURE_ACTION"] = action
        environment["EGASU_CACHE_FIXTURE_SUITE"] = suite
        environment["EGASU_CACHE_FIXTURE_DIRECTORY"] = directory.path
        let temporaryDirectory = directory.appendingPathComponent(action + "-tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        environment["TMPDIR"] = temporaryDirectory.path
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return process
    }

    private func output(of process: Process) -> String {
        guard let pipe = process.standardOutput as? Pipe else { return "Fixture output unavailable" }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    private func waitForFile(_ file: URL) throws {
        let deadline = Date().addingTimeInterval(20)
        while !FileManager.default.fileExists(atPath: file.path), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
    }
}
