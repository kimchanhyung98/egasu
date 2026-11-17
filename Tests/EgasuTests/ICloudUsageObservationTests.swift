import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageObservationTests: XCTestCase {
    func testDataScopeNotificationsReloadBothHistoryLocationsAndStopWhenDisabled() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EgasuTests.ICloudObservation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let query = RecordingMetadataQuery()
        let sync = makeSync(defaults: defaults, root: root, query: query)

        sync.enabled = true
        try await waitUntil { query.startCount == 1 && !sync.isSyncing && sync.documents.count == 1 }
        XCTAssertEqual(query.searchScopes as? [String], [NSMetadataQueryUbiquitousDataScope])

        let currentPeer = document(name: "New Mac")
        try save(currentPeer, under: root.appendingPathComponent("egasu/History"))
        NotificationCenter.default.post(name: .NSMetadataQueryDidFinishGathering, object: query)
        try await waitUntil { sync.documents.contains { $0.deviceID == currentPeer.deviceID } }
        XCTAssertEqual(query.enableUpdatesCount, 1)

        let legacyPeer = document(name: "Older Mac")
        try save(legacyPeer, under: root.appendingPathComponent("OpenUsage/History/v1"))
        NotificationCenter.default.post(name: .NSMetadataQueryDidUpdate, object: query)
        try await waitUntil { sync.documents.count == 3 }
        XCTAssertTrue(sync.documents.contains { $0.deviceID == legacyPeer.deviceID })

        sync.enabled = false
        try await waitUntil { query.stopCount == 1 && !sync.isSyncing && sync.documents.isEmpty }
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("egasu/History/\(currentPeer.deviceID).json").path
            ))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("OpenUsage/History/v1/\(legacyPeer.deviceID).json").path
            ))
    }

    func testPartialDeletionKeepsPendingRequestUntilBothLocationsAreRemovedAfterRelaunch() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "EgasuTests.ICloudPartialDeletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let deviceID = UUID().uuidString.lowercased()
        let legacyFile = root.appendingPathComponent("OpenUsage/History/v1/\(deviceID).json")
        defer {
            try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacyFile.path)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let sync = makeSync(defaults: defaults, root: root, deviceID: deviceID)
        sync.enabled = true
        try await waitUntil { !sync.isSyncing && sync.documents.count == 1 }
        try save(document(id: deviceID, name: "This Mac"), under: legacyFile.deletingLastPathComponent())
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: legacyFile.path)

        sync.enabled = false
        try await waitUntil { !sync.isSyncing && sync.deletionError != nil }
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("egasu/History/\(deviceID).json").path
            ))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertEqual(defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1"), deviceID)

        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacyFile.path)
        let relaunched = makeSync(defaults: defaults, root: root, deviceID: deviceID)
        try await waitUntil {
            !relaunched.isSyncing && defaults.string(forKey: "openusage.icloudSync.pendingDeletionDeviceID.v1") == nil
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        XCTAssertNil(relaunched.deletionError)
        XCTAssertFalse(relaunched.enabled)
    }

    private func makeSync(
        defaults: UserDefaults, root: URL, deviceID: String = UUID().uuidString.lowercased(),
        query: RecordingMetadataQuery? = nil
    ) -> ICloudUsageSyncStore {
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []), providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults
        )
        return ICloudUsageSyncStore(
            dataStore: dataStore, defaults: defaults,
            fileStore: ICloudUsageHistoryFileStore(containerURL: { root }),
            deviceIDStore: FixedDeviceIDStore(deviceID: deviceID),
            observesMetadataChanges: query != nil,
            makeMetadataQuery: { query ?? RecordingMetadataQuery() }
        )
    }

    private func document(id: String = UUID().uuidString.lowercased(), name: String) -> UsageHistoryDocument {
        UsageHistoryDocument(deviceID: id, deviceName: name, updatedAt: .now, providers: [:])
    }

    private func save(_ document: UsageHistoryDocument, under directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(
            to: directory.appendingPathComponent(document.deviceID).appendingPathExtension("json"), options: .atomic
        )
    }

    private func waitUntil(condition: @escaping () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private final class RecordingMetadataQuery: NSMetadataQuery {
    var startCount = 0
    var stopCount = 0
    var enableUpdatesCount = 0

    override func start() -> Bool { startCount += 1; return true }
    override func stop() { stopCount += 1 }
    override func enableUpdates() { enableUpdatesCount += 1 }
}

private struct FixedDeviceIDStore: ICloudDeviceIDStoring {
    let deviceID: String
    func readDeviceID() throws -> String? { deviceID }
    func writeDeviceID(_ deviceID: String) throws {}
}
