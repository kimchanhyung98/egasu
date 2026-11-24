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

    func testLocalSuccessBehindNewerDiskResultKeepsTheLatestSessionReading() throws {
        for previous in [false, true] {
            let suite = "EgasuTests.SharedCache." + UUID().uuidString
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
            if previous {
                var old = reading("codex", used: 10)
                old.refreshedAt = now.addingTimeInterval(-3)
                app.store(old, producedByIdentityKey: "previous")
            }
            let disk = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
            let external = reading("codex", used: 80)
            disk.store(external, producedByIdentityKey: "external")
            var local = reading("codex", used: 30)
            local.refreshedAt = now.addingTimeInterval(-1)
            local.liveQuotaAccountKey = "runtime-only"
            app.store(local, producedByIdentityKey: "local")
            var delayed = reading("codex", used: 20)
            delayed.refreshedAt = now.addingTimeInterval(-2)
            app.store(delayed, producedByIdentityKey: "delayed")

            let cached = app.snapshot(providerID: "codex")
            XCTAssertEqual(cached?.lines, local.lines)
            XCTAssertEqual(cached?.refreshedAt, local.refreshedAt)
            XCTAssertEqual(cached?.liveQuotaAccountKey, local.liveQuotaAccountKey)
            XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
            let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
            XCTAssertEqual(reader.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, external.lines)
            XCTAssertEqual(reader.producedByIdentityKey(providerID: "codex"), "external")
        }
    }

    func testFutureDiskReadingDoesNotRollBackANewerSessionReading() throws {
        let suite = "EgasuTests.SharedCache." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        let external = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        var local = reading("codex", used: 30)
        local.refreshedAt = now.addingTimeInterval(-5)
        app.store(local, producedByIdentityKey: "local")
        var future = reading("codex", used: 80)
        future.refreshedAt = now.addingTimeInterval(5)
        external.store(future, producedByIdentityKey: "external")
        var delayed = reading("codex", used: 20)
        delayed.refreshedAt = now.addingTimeInterval(-6)
        app.store(delayed, producedByIdentityKey: "delayed")

        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, local.lines)
        XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(reader.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, delayed.lines)
        XCTAssertEqual(reader.producedByIdentityKey(providerID: "codex"), "delayed")
        let next = reading("codex", used: 40)
        app.store(next, producedByIdentityKey: "next")
        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, next.lines)
    }

    func testFailedSynchronizationKeepsLatestSuccessfulReadingOnlyInSession() throws {
        let suite = "EgasuTests.SharedCache." + UUID().uuidString
        let defaults = try XCTUnwrap(FailingCacheSynchronizationDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        var local = reading("codex", used: 30)
        local.liveQuotaAccountKey = "runtime"
        app.store(local, producedByIdentityKey: "local")
        var delayed = reading("codex", used: 20)
        delayed.refreshedAt = now.addingTimeInterval(-1)
        app.store(delayed, producedByIdentityKey: "delayed")
        app.store(reading("claude", used: 10), markSessionFresh: false)

        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, local.lines)
        XCTAssertEqual(app.snapshot(providerID: "codex")?.liveQuotaAccountKey, "runtime")
        XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
        XCTAssertNil(app.snapshot(providerID: "claude"))
        XCTAssertNil(defaults.data(forKey: "openusage.providerSnapshots.v10"))
        defaults.failsBeforeWrite = false
        app.store(local, producedByIdentityKey: "local", markSessionFresh: false)
        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, local.lines)
        XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
        XCTAssertNil(defaults.data(forKey: "openusage.providerSnapshots.v10"))
        app.store(reading("claude", used: 10))
        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, local.lines)
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertNil(reader.loadSnapshots(providerIDs: ["codex"])["codex"])
        app.store(delayed, producedByIdentityKey: "delayed")
        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, local.lines)
        XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
        let published = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(published.producedByIdentityKey(providerID: "codex"), "delayed")
        defaults.removeObject(forKey: "openusage.providerSnapshots.v10")
        app.store(reading("claude", used: 20))
        XCTAssertNil(app.snapshot(providerID: "codex"))
    }

    func testWriteChecksFutureTimeAfterSynchronizingWithExternalWriter() throws {
        let suite = "EgasuTests.SharedCache." + UUID().uuidString
        let defaults = try XCTUnwrap(FailingCacheSynchronizationDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.failsBeforeWrite = false
        let external = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        var newer = reading("codex", used: 80)
        newer.refreshedAt = now.addingTimeInterval(1)
        external.store(newer, producedByIdentityKey: "external")
        var clock = now
        defaults.beforeSync = { clock = self.now.addingTimeInterval(2) }
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { clock })
        app.store(reading("codex", used: 30), producedByIdentityKey: "local")
        let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
        XCTAssertEqual(reader.producedByIdentityKey(providerID: "codex"), "external")
        XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
    }

    func testFailedPostWriteSynchronizationKeepsOnePublishedReading() throws {
        let suite = "EgasuTests.SharedCache." + UUID().uuidString
        let defaults = try XCTUnwrap(FailingCacheSynchronizationDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.failsBeforeWrite = false
        defaults.failsAfterWrite = true
        let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { self.now })
        let local = reading("codex", used: 30)
        app.store(local, producedByIdentityKey: "local")
        XCTAssertEqual(defaults.blobWrites, 1)
        XCTAssertEqual(defaults.syncCalls, 2)
        XCTAssertEqual(app.snapshot(providerID: "codex")?.lines, local.lines)
        XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
    }

    func testMatchingRetainedHistoryUpdatesOnlyTheSessionWithoutExtendingQuotaFreshness() throws {
        for failsBeforeWrite in [false, true] {
            let suite = "EgasuTests.SharedCache." + UUID().uuidString
            let defaults = try XCTUnwrap(FailingCacheSynchronizationDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            defaults.failsBeforeWrite = false
            var clock = now
            let app = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, ttl: 10, now: { clock })
            var local = reading("codex", used: 30)
            local.refreshedAt = now.addingTimeInterval(-4)
            local.quotaObservedAt = now.addingTimeInterval(-6)
            local.liveQuotaObservedAt = local.quotaObservedAt
            local.codexResetClaimBinding = try XCTUnwrap(
                recommendationCodexBinding(account: "local", source: .keychain))
            app.store(local, producedByIdentityKey: "local")
            let disk = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { clock })
            let newer = reading("codex", used: 80)
            disk.store(newer, producedByIdentityKey: "external")

            var retained = local
            retained.usageHistory = ProviderUsageHistory(
                series: DailyUsageSeries(daily: [
                    DailyUsageEntry(date: "2027-01-15", totalTokens: 100, costUSD: 1)
                ]))
            retained.warning = "quota unavailable"
            retained.isDegraded = true
            retained.liveQuotaObservedAt = nil
            retained.codexResetClaimBinding = nil
            defaults.failsBeforeWrite = failsBeforeWrite
            app.store(retained, producedByIdentityKey: "local", markSessionFresh: false)
            var incompatible = retained
            incompatible.warning = "wrong reading"
            app.store(incompatible, producedByIdentityKey: "external", markSessionFresh: false)
            incompatible.refreshedAt = now.addingTimeInterval(-2)
            app.store(incompatible, producedByIdentityKey: "local", markSessionFresh: false)

            let hit = try XCTUnwrap(app.snapshot(providerID: "codex"))
            XCTAssertEqual(hit.usageHistory, retained.usageHistory)
            XCTAssertEqual(hit.warning, retained.warning)
            XCTAssertEqual(hit.isDegraded, true)
            XCTAssertNil(hit.liveQuotaObservedAt)
            XCTAssertNil(hit.codexResetClaimBinding)
            XCTAssertEqual(hit.freshnessDate, local.freshnessDate)
            XCTAssertEqual(app.producedByIdentityKey(providerID: "codex"), "local")
            let reader = ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite)
            XCTAssertEqual(reader.loadSnapshots(providerIDs: ["codex"])["codex"]?.lines, newer.lines)
            XCTAssertEqual(reader.producedByIdentityKey(providerID: "codex"), "external")
            clock = now.addingTimeInterval(5)
            XCTAssertNil(app.snapshot(providerID: "codex"))
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

private final class FailingCacheSynchronizationDefaults: UserDefaults {
    var failsBeforeWrite = true
    var failsAfterWrite = false
    var blobWrites = 0
    var syncCalls = 0
    var beforeSync: (() -> Void)?

    override func synchronize() -> Bool {
        beforeSync?()
        syncCalls += 1
        return !failsBeforeWrite && !(failsAfterWrite && blobWrites > 0) && super.synchronize()
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        if defaultName == "openusage.providerSnapshots.v10" { blobWrites += 1 }
        super.set(value, forKey: defaultName)
    }
}
