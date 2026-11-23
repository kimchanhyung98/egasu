import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUncollectedHistoryTests: XCTestCase {
    private enum Input {
        case activeWithMissingCache
        case deliveryAfterLoad
        case unreadableOwn
        case unreadablePeer
        case activeWithFamilyTotal
        case activeWithFailedCollection
        case activeThenEmptyCollection
        case disabled
        case activeWithAuthoritativeEmptyHistory
    }

    private struct FixedDeviceID: ICloudDeviceIDStoring {
        let id: String

        func readDeviceID() throws -> String? { id }

        func writeDeviceID(_ deviceID: String) throws {
            XCTFail("이미 읽은 기기 ID는 다시 만들 필요가 없음")
        }
    }

    func testStartupKeepsPreviousOwnHistoryForEnabledProviderBeforeFirstCollection() async throws {
        try await checkStartup(.activeWithMissingCache)
    }

    func testStartupPreservesUncollectedFamilyTotalWithoutAttributingIt() async throws {
        try await checkStartup(.activeWithFamilyTotal)
    }

    func testStartupMayRemoveExplicitlyDisabledProvider() async throws {
        try await checkStartup(.disabled)
    }

    func testStartupMayPublishAuthoritativeEmptyCollection() async throws {
        try await checkStartup(.activeWithAuthoritativeEmptyHistory)
    }

    func testFailedFirstCollectionKeepsTheLastSyncedHistory() async throws {
        try await checkStartup(.activeWithFailedCollection)
    }

    func testLaterAuthoritativeEmptyCollectionReplacesPreservedHistory() async throws {
        try await checkStartup(.activeThenEmptyCollection)
    }

    func testScheduledWriteRebuildsWithTheLatestDeliveredUncollectedHistory() async throws {
        try await checkStartup(.deliveryAfterLoad)
    }

    func testUnreadableOwnDocumentDefersReplacementUntilAccessReturns() async throws {
        try await checkStartup(.unreadableOwn)
    }

    func testUnreadablePeerDoesNotBlockOwnDocument() async throws {
        try await checkStartup(.unreadablePeer)
    }

    private func checkStartup(_ input: Input) async throws {
        let suite = "ICloudUncollectedHistoryTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let deviceID = UUID().uuidString.lowercased()
        let now = Date()
        let day = String(ISO8601DateFormatter().string(from: now).prefix(10))
        let oldHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [.init(date: day, totalTokens: 100, costUSD: 1.25)]))
        let refreshedHistory = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [.init(date: day, totalTokens: 300, costUSD: 3.75)]))
        let emptyHistory = ProviderUsageHistory(series: DailyUsageSeries(daily: []))
        let previous = UsageHistoryDocument(
            deviceID: deviceID, deviceName: "Synthetic Mac", updatedAt: now.addingTimeInterval(-3600),
            providers: ["claude": oldHistory, "codex": oldHistory],
            identities: input == .activeWithFamilyTotal ? nil : ["claude": "claude", "codex": "codex"])
        let legacy = root.appendingPathComponent("OpenUsage/History/v1/" + deviceID + ".json")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let previousBytes = try encoder.encode(previous)
        try previousBytes.write(to: legacy, options: .atomic)
        var peer = previous
        peer.deviceID = UUID().uuidString.lowercased()
        peer.deviceName = "Peer Mac"
        let peerFile = legacy.deletingLastPathComponent().appendingPathComponent(peer.deviceID + ".json")
        let peerData = try encoder.encode(peer)
        try peerData.write(to: peerFile, options: .atomic)
        let files = ICloudUsageHistoryFileStore(containerURL: { root })
        let before = try await files.loadDocuments()
        XCTAssertEqual(before.documents.first?.providers, previous.providers)

        let claude = ClaudeProvider.makeProvider()
        let codex = CodexProvider.makeProvider()
        let cache = ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(input == .disabled ? ["codex"] : ["claude", "codex"])
        let runtimes = [claude, codex].map { provider in
            let descriptor = WidgetDescriptor.usageTrend(provider: provider)
                .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "fixture")
            var snapshot = ProviderSnapshot.make(
                provider: provider, plan: nil, lines: [], refreshedAt: now,
                usageHistory: provider.id == "codex" ? refreshedHistory : emptyHistory)
            if provider.id == "claude", input == .activeWithFailedCollection {
                snapshot = .error(provider: provider, message: "Fixture collection failed", category: .network)
            }
            if provider.id == "codex" || input == .activeWithAuthoritativeEmptyHistory {
                cache.store(snapshot, producedByIdentityKey: provider.id)
            }
            return CountingProviderRuntime(provider: provider, descriptors: [descriptor], snapshot: snapshot)
        }
        let registry = WidgetRegistry.from(runtimes)
        let data = WidgetDataStore(
            registry: registry, providers: runtimes, cache: cache, defaults: defaults,
            isProviderEnabled: { enablement.isEnabled($0) },
            providerIdentityKeys: ["claude": "claude", "codex": "codex"],
            familyTotalHistoryCardIDs: input == .activeWithFamilyTotal ? ["claude", "codex"] : [])
        XCTAssertEqual(registry.historyDescriptorsByProvider["claude"]?.scope, .machineLocal)
        XCTAssertEqual(enablement.isEnabled("claude"), input != .disabled)
        XCTAssertEqual(data.localSnapshots["codex"]?.usageHistory, refreshedHistory)
        XCTAssertEqual(
            data.localSnapshots["claude"]?.usageHistory,
            input == .activeWithAuthoritativeEmptyHistory ? emptyHistory : nil)
        if input == .activeWithFailedCollection {
            let result = await data.refresh(providerID: "claude", force: true)
            XCTAssertEqual(result, .failed)
        }

        if input == .unreadableOwn || input == .unreadablePeer {
            let blocked = input == .unreadableOwn ? legacy : peerFile
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            XCTAssertThrowsError(try Data(contentsOf: blocked))
        }

        defaults.set(true, forKey: "openusage.icloudSync.enabled.v1")
        let sync = ICloudUsageSyncStore(
            dataStore: data, defaults: defaults, fileStore: files, deviceIDStore: FixedDeviceID(id: deviceID),
            writeDebounce: .milliseconds(10), observesMetadataChanges: false)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        if input == .unreadableOwn {
            while sync.isSyncing || sync.documents.isEmpty {
                guard clock.now < deadline else { return XCTFail("첫 동기화 대기 시간 초과") }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertNotNil(sync.serviceError)
            let current = root.appendingPathComponent("egasu/History/" + deviceID + ".json")
            XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
            guard FileManager.default.fileExists(atPath: legacy.path) else {
                return XCTFail("읽지 못한 기존 파일이 삭제됨")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: legacy.path)
            XCTAssertEqual(try Data(contentsOf: legacy), previousBytes)
            sync.scheduleWrite()
        }
        while sync.isSyncing
            || sync.documents.first(where: { $0.deviceID == deviceID })?.providers["codex"] != refreshedHistory
        {
            guard clock.now < deadline else { return XCTFail("정상 캐시가 있는 Codex의 첫 쓰기·재로드가 끝나지 않음") }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(sync.enabled)
        if input == .unreadablePeer {
            XCTAssertNotNil(sync.serviceError)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: peerFile.path)
        } else {
            XCTAssertNil(sync.serviceError)
        }
        XCTAssertEqual(runtimes[0].refreshCount, input == .activeWithFailedCollection ? 1 : 0)
        XCTAssertEqual(runtimes[1].refreshCount, 0)
        let result = try await files.loadDocuments()
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertEqual(result.documents.count, 2)
        XCTAssertEqual(try Data(contentsOf: peerFile), peerData)
        let own = try XCTUnwrap(result.documents.first { $0.deviceID == deviceID })
        XCTAssertEqual(own.deviceID, deviceID)
        XCTAssertEqual(own.providers["codex"], refreshedHistory)
        switch input {
        case .unreadableOwn, .unreadablePeer, .activeWithMissingCache, .activeWithFamilyTotal,
            .activeWithFailedCollection, .activeThenEmptyCollection, .deliveryAfterLoad:
            XCTAssertEqual(
                own.providers["claude"], oldHistory,
                "활성 Claude 첫 수집 전 마지막 정상 기록 100토큰·1.25달러 보존. 기존 경로 파일 존재 = \(FileManager.default.fileExists(atPath: legacy.path))"
            )
        case .disabled:
            XCTAssertNil(own.providers["claude"])
        case .activeWithAuthoritativeEmptyHistory:
            XCTAssertEqual(own.providers["claude"], emptyHistory)
        }
        if input == .deliveryAfterLoad {
            var delivered = own
            delivered.providers["claude"] = refreshedHistory
            delivered.updatedAt = own.updatedAt.addingTimeInterval(1)
            try encoder.encode(delivered).write(to: legacy, options: .atomic)
            sync.scheduleWrite()
            while FileManager.default.fileExists(atPath: legacy.path) || sync.isSyncing {
                guard clock.now < deadline else { return XCTFail("변경된 구형 이력 재조회와 게시 대기 시간 초과") }
                try await Task.sleep(for: .milliseconds(10))
            }
            let reloaded = try await files.loadDocuments()
            XCTAssertEqual(reloaded.documents.first { $0.deviceID == deviceID }?.providers["claude"], refreshedHistory)
        }
        if input == .activeWithFamilyTotal {
            XCTAssertNil(own.identities)
        }
        if input == .activeThenEmptyCollection {
            let outcome = await data.refresh(providerID: "claude", force: true)
            XCTAssertEqual(outcome, .refreshed)
            while sync.isSyncing
                || sync.documents.first(where: { $0.deviceID == deviceID })?.providers["claude"] != emptyHistory
            {
                guard clock.now < deadline else { return XCTFail("빈 수집 결과의 동기화가 끝나지 않음") }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(try Data(contentsOf: peerFile), peerData)
        }
    }
}
