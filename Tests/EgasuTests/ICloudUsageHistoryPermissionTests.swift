import Darwin
import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageHistoryPermissionTests: XCTestCase {
    func testInaccessibleHistoryReportsErrorsAndKeepsReadableDocuments() async throws {
        for blockedName in ["egasu", "OpenUsage"] {
            let root = try makeRoot()
            let blocked = root.appendingPathComponent(blockedName)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
                try? FileManager.default.removeItem(at: root)
            }
            let current = root.appendingPathComponent("egasu/History")
            let legacy = root.appendingPathComponent("OpenUsage/History/v1")
            let blockedDirectory = blockedName == "egasu" ? current : legacy
            let readableDirectory = blockedName == "egasu" ? legacy : current
            try save(document(), under: blockedDirectory)
            let readable = document()
            try save(readable, under: readableDirectory)
            try Data("invalid".utf8).write(to: readableDirectory.appendingPathComponent("invalid.json"))
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: blockedDirectory.path))
            assertPermissionDenied(blockedDirectory)

            let result = try await ICloudUsageHistoryFileStore(containerURL: { root }).loadDocuments()

            XCTAssertEqual(result.documents, [readable])
            XCTAssertFalse(result.canReplaceDocument(for: readable.deviceID))
            XCTAssertEqual(result.invalidFileMessages.count, 2)
            XCTAssertTrue(
                result.invalidFileMessages.contains { $0.hasPrefix("\(blockedDirectory.lastPathComponent):") })
            XCTAssertTrue(result.invalidFileMessages.contains { $0.hasPrefix("invalid.json:") })
            XCTAssertFalse(result.failureCategories.isEmpty)
        }
    }

    func testInaccessibleOwnHistoryKeepsPendingDeletionUntilAccessReturns() async throws {
        for blockedName in ["egasu", "OpenUsage"] {
            let root = try makeRoot()
            let blocked = root.appendingPathComponent(blockedName)
            let suite = "EgasuTests.ICloudPermission.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
                defaults.removePersistentDomain(forName: suite)
                try? FileManager.default.removeItem(at: root)
            }
            let own = document()
            let current = root.appendingPathComponent("egasu/History")
            let legacy = root.appendingPathComponent("OpenUsage/History/v1")
            try save(own, under: current)
            try save(own, under: legacy)
            let pendingKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"
            defaults.set(own.deviceID, forKey: pendingKey)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
            let sync = makeSync(defaults: defaults, root: root, deviceID: own.deviceID)
            try await waitUntil {
                !sync.isSyncing && (sync.deletionError != nil || defaults.string(forKey: pendingKey) == nil)
            }

            XCTAssertEqual(defaults.string(forKey: pendingKey), own.deviceID)
            XCTAssertNotNil(sync.deletionError)
            XCTAssertFalse(sync.enabled)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            let retained = (blockedName == "egasu" ? current : legacy).appendingPathComponent(own.deviceID + ".json")
            XCTAssertTrue(FileManager.default.fileExists(atPath: retained.path))
            let relaunched = makeSync(defaults: defaults, root: root, deviceID: own.deviceID)
            try await waitUntil { !relaunched.isSyncing && defaults.string(forKey: pendingKey) == nil }
            XCTAssertNil(relaunched.deletionError)
            for directory in [current, legacy] {
                XCTAssertFalse(
                    FileManager.default.fileExists(
                        atPath: directory.appendingPathComponent(own.deviceID + ".json").path))
            }
        }
    }

    func testInaccessibleLegacyCleanupKeepsNewWriteAndReportsFailure() async throws {
        let root = try makeRoot()
        let blocked = root.appendingPathComponent("OpenUsage")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
            try? FileManager.default.removeItem(at: root)
        }
        let own = document()
        try save(own, under: root.appendingPathComponent("OpenUsage/History/v1"))
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: blocked.path)
        let fileStore = ICloudUsageHistoryFileStore(containerURL: { root })
        var writeError: Error?
        do { try await fileStore.write(own) } catch { writeError = error }
        XCTAssertNotNil(writeError, "Legacy cleanup must report inaccessible history")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("egasu/History/\(own.deviceID).json").path))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: blocked.path)
        try await fileStore.write(own)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("OpenUsage/History/v1/\(own.deviceID).json").path))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ICloudPermission-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func document() -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture",
            updatedAt: Date(timeIntervalSince1970: 100), providers: [:])
    }

    private func save(_ document: UsageHistoryDocument, under directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: directory.appendingPathComponent(document.deviceID + ".json"))
    }

    private func assertPermissionDenied(_ directory: URL) {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY)
        let failure = errno
        if descriptor >= 0 { Darwin.close(descriptor) }
        XCTAssertEqual(descriptor, -1)
        XCTAssertEqual(failure, EACCES)
        XCTAssertThrowsError(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    }

    private func makeSync(defaults: UserDefaults, root: URL, deviceID: String) -> ICloudUsageSyncStore {
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []), providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"), defaults: defaults)
        return ICloudUsageSyncStore(
            dataStore: dataStore, defaults: defaults, fileStore: ICloudUsageHistoryFileStore(containerURL: { root }),
            deviceIDStore: PermissionDeviceIDStore(deviceID: deviceID), observesMetadataChanges: false)
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

private struct PermissionDeviceIDStore: ICloudDeviceIDStoring {
    let deviceID: String
    func readDeviceID() throws -> String? { deviceID }
    func writeDeviceID(_ deviceID: String) throws {}
}
