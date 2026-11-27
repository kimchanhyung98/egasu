import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageHistoryDeletionTests: XCTestCase {
    func testDeleteRemovesNamedCopiesAndPreservesOtherDevices() async throws {
        let (root, store) = try makeFixture()
        let own = document()
        let peer = document()
        var newer = own
        newer.updatedAt = own.updatedAt.addingTimeInterval(100)
        newer.deviceID = own.deviceID.uppercased()
        for directory in directories(root) {
            try save(own, to: directory.appendingPathComponent(own.deviceID + ".json"))
            try save(own, to: directory.appendingPathComponent(own.deviceID + "-copy.json"))
            try save(newer, to: directory.appendingPathComponent("latest-copy.json"))
            try save(peer, to: directory.appendingPathComponent("peer-copy.json"))
        }

        try await store.delete(deviceID: own.deviceID)

        for directory in directories(root) {
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["peer-copy.json"])
            XCTAssertEqual(try read(directory.appendingPathComponent("peer-copy.json")), peer)
        }
    }

    func testDeleteUsesDocumentIdentityInsteadOfCanonicalFilename() async throws {
        let (root, store) = try makeFixture()
        let own = document()
        let peer = document()
        for directory in directories(root) {
            try save(peer, to: directory.appendingPathComponent(own.deviceID + ".json"))
            try save(own, to: directory.appendingPathComponent(peer.deviceID + ".json"))
        }

        try await store.delete(deviceID: own.deviceID)

        for directory in directories(root) {
            XCTAssertEqual(try read(directory.appendingPathComponent(own.deviceID + ".json")), peer)
            XCTAssertFalse(exists(directory.appendingPathComponent(peer.deviceID + ".json")))
        }
    }

    func testInvalidFilesArePreservedWhileValidOwnCopiesAreDeleted() async throws {
        var unsupported = document()
        unsupported.schema = "unsupported"
        var invalid = document()
        invalid.deviceName = ""
        let invalidFiles = [Data("not json".utf8), try encoded(unsupported), try encoded(invalid)]
        for invalidData in invalidFiles {
            let (root, store) = try makeFixture()
            let own = document()
            let peer = document()
            let locations = directories(root)
            for directory in locations {
                try save(own, to: directory.appendingPathComponent(own.deviceID + ".json"))
                try save(own, to: directory.appendingPathComponent("own-copy.json"))
                try save(peer, to: directory.appendingPathComponent("peer.json"))
            }
            let damaged = locations[0].appendingPathComponent("damaged.json")
            try invalidData.write(to: damaged)

            _ = await assertFailure { try await store.delete(deviceID: own.deviceID) }

            XCTAssertEqual(try Data(contentsOf: damaged), invalidData)
            for directory in locations {
                XCTAssertFalse(exists(directory.appendingPathComponent(own.deviceID + ".json")))
                XCTAssertFalse(exists(directory.appendingPathComponent("own-copy.json")))
                XCTAssertEqual(try read(directory.appendingPathComponent("peer.json")), peer)
            }
        }
    }

    func testDeletionFailureStillRemovesOtherOwnCopiesAndCanRetry() async throws {
        let (root, store) = try makeFixture()
        let own = document()
        let locations = directories(root)
        let blocked = locations[0].appendingPathComponent(own.deviceID + ".json")
        try save(own, to: blocked)
        try save(own, to: locations[0].appendingPathComponent("own-copy.json"))
        try save(own, to: locations[1].appendingPathComponent("own-copy.json"))
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path) }

        _ = await assertFailure { try await store.delete(deviceID: own.deviceID) }

        XCTAssertEqual(try read(blocked), own)
        for directory in locations {
            XCTAssertFalse(exists(directory.appendingPathComponent("own-copy.json")))
        }
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: blocked.path)
        try await store.delete(deviceID: own.deviceID)
        XCTAssertFalse(exists(blocked))
    }

    func testReadFailurePreservesUnreadableFileAndDeletesReadableOwnCopies() async throws {
        let (root, store) = try makeFixture()
        let own = document()
        let locations = directories(root)
        let blocked = locations[0].appendingPathComponent("unreadable-copy.json")
        try save(own, to: blocked)
        for directory in locations {
            try save(own, to: directory.appendingPathComponent(own.deviceID + ".json"))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path) }
        XCTAssertThrowsError(try Data(contentsOf: blocked))

        _ = await assertFailure { try await store.delete(deviceID: own.deviceID) }

        XCTAssertTrue(exists(blocked))
        for directory in locations {
            XCTAssertFalse(exists(directory.appendingPathComponent(own.deviceID + ".json")))
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: blocked.path)
        try await store.delete(deviceID: own.deviceID)
        XCTAssertFalse(exists(blocked))
    }

    func testUnreadableDirectoryDoesNotPreventDeletingOtherLocation() async throws {
        for blockedIndex in [0, 1] {
            let (root, store) = try makeFixture()
            let own = document()
            let locations = directories(root)
            let blocked = locations[blockedIndex]
            try FileManager.default.createDirectory(
                at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
            let marker = Data("not a directory".utf8)
            try marker.write(to: blocked)
            let readable = locations[1 - blockedIndex].appendingPathComponent("own-copy.json")
            try save(own, to: readable)

            _ = await assertFailure { try await store.delete(deviceID: own.deviceID) }

            XCTAssertEqual(try Data(contentsOf: blocked), marker)
            XCTAssertFalse(exists(readable))
        }
    }

    func testUnidentifiedDamagedFileKeepsPendingDeletionUntilRepaired() async throws {
        let (root, fileStore) = try makeFixture()
        let own = document()
        let peer = document()
        let directory = directories(root)[0]
        let ownURL = directory.appendingPathComponent("own-copy.json")
        let damaged = directory.appendingPathComponent("unidentified.json")
        try save(own, to: ownURL)
        try Data("not json".utf8).write(to: damaged)
        let suite = "EgasuTests.HistoryDeletion.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pendingKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"
        defaults.set(own.deviceID, forKey: pendingKey)
        let sync = makeSync(defaults: defaults, fileStore: fileStore, deviceID: own.deviceID)
        try await waitUntil { !sync.isSyncing && sync.deletionError != nil }

        XCTAssertEqual(defaults.string(forKey: pendingKey), own.deviceID)
        XCTAssertFalse(exists(ownURL))
        XCTAssertEqual(try Data(contentsOf: damaged), Data("not json".utf8))
        try save(peer, to: damaged)

        let relaunched = makeSync(defaults: defaults, fileStore: fileStore, deviceID: own.deviceID)
        try await waitUntil { !relaunched.isSyncing && defaults.string(forKey: pendingKey) == nil }
        XCTAssertNil(relaunched.deletionError)
        XCTAssertEqual(try read(damaged), peer)
    }

    func testPreviousPendingFailureStillDeletesCurrentDeviceWhileDisabled() async throws {
        let (root, fileStore) = try makeFixture()
        let previous = document()
        let current = document()
        let directory = directories(root)[0]
        let previousURL = directory.appendingPathComponent("previous-copy.json")
        let currentURL = directory.appendingPathComponent("current-copy.json")
        let damaged = directory.appendingPathComponent("unidentified.json")
        try save(previous, to: previousURL)
        try save(current, to: currentURL)
        try Data("not json".utf8).write(to: damaged)
        let suite = "EgasuTests.HistoryDeletionHandoff.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let pendingKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"
        defaults.set(previous.deviceID, forKey: pendingKey)
        let sync = makeSync(defaults: defaults, fileStore: fileStore, deviceID: current.deviceID)
        try await waitUntil { !sync.isSyncing && sync.deletionError != nil }

        XCTAssertFalse(sync.enabled)
        XCTAssertFalse(exists(previousURL))
        XCTAssertFalse(exists(currentURL))
        XCTAssertEqual(defaults.string(forKey: pendingKey), previous.deviceID)
        XCTAssertEqual(try Data(contentsOf: damaged), Data("not json".utf8))
    }

    private func makeFixture() throws -> (URL, ICloudUsageHistoryFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ICloudHistoryDeletionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, ICloudUsageHistoryFileStore(containerURL: { root }))
    }

    private func document() -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString.lowercased(), deviceName: "Test Mac",
            updatedAt: Date(timeIntervalSince1970: 100), providers: [:])
    }

    private func directories(_ root: URL) -> [URL] {
        [root.appendingPathComponent("egasu/History"), root.appendingPathComponent("OpenUsage/History/v1")]
    }

    private func encoded(_ document: UsageHistoryDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(document)
    }

    private func save(_ document: UsageHistoryDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded(document).write(to: url)
    }

    private func read(_ url: URL) throws -> UsageHistoryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageHistoryDocument.self, from: Data(contentsOf: url))
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func assertFailure(
        _ operation: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line
    ) async -> Error? {
        do {
            try await operation()
            XCTFail("Expected operation to fail", file: file, line: line)
            return nil
        } catch {
            return error
        }
    }

    private func makeSync(
        defaults: UserDefaults, fileStore: ICloudUsageHistoryFileStore, deviceID: String
    ) -> ICloudUsageSyncStore {
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []), providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults)
        return ICloudUsageSyncStore(
            dataStore: dataStore, defaults: defaults, fileStore: fileStore,
            deviceIDStore: DeletionDeviceIDStore(deviceID: deviceID), observesMetadataChanges: false)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Condition was not met before timeout")
    }
}

private struct DeletionDeviceIDStore: ICloudDeviceIDStoring {
    let deviceID: String
    func readDeviceID() throws -> String? { deviceID }
    func writeDeviceID(_ deviceID: String) throws {}
}
