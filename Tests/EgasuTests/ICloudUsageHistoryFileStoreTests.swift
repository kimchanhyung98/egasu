import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageHistoryFileStoreTests: XCTestCase {
    func testReadingMissingHistoryDoesNotCreateDirectories() async throws {
        let (root, store) = try makeFixture()

        let result = try await store.loadDocuments()

        XCTAssertTrue(result.documents.isEmpty)
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testReadsBothLocationsAndKeepsTheNewestDocumentForEachDevice() async throws {
        let (root, store) = try makeFixture()
        let old = document(updatedAt: 100)
        var newer = old
        newer.updatedAt = Date(timeIntervalSince1970: 200)
        newer.deviceName = "Newer Legacy Mac"
        let currentPeer = document(updatedAt: 150)
        var legacyPeer = document(updatedAt: 160)
        legacyPeer.schema = UsageHistoryDocument.legacySchemaV1
        try save(old, to: currentURL(root, old.deviceID))
        try save(newer, to: legacyURL(root, newer.deviceID))
        try save(currentPeer, to: currentURL(root, currentPeer.deviceID))
        try save(legacyPeer, to: legacyURL(root, legacyPeer.deviceID))

        let result = try await store.loadDocuments()

        XCTAssertEqual(Set(result.documents), Set([newer, currentPeer, legacyPeer]))
        XCTAssertTrue(result.invalidFileMessages.isEmpty)
        XCTAssertTrue(exists(legacyURL(root, newer.deviceID)), "읽기는 다른 Mac의 파일을 옮기지 않음")
        XCTAssertFalse(exists(currentURL(root, legacyPeer.deviceID)))
    }

    func testEqualTimestampsPreferTheCurrentLocation() async throws {
        let (root, store) = try makeFixture()
        let current = document(updatedAt: 100)
        var legacy = current
        legacy.deviceName = "Legacy Copy"
        try save(current, to: currentURL(root, current.deviceID))
        try save(legacy, to: legacyURL(root, legacy.deviceID))

        let result = try await store.loadDocuments()

        XCTAssertEqual(result.documents, [current])
    }

    func testInvalidFilesAreReportedWhileValidDocumentsFromBothLocationsRemain() async throws {
        let (root, store) = try makeFixture()
        let current = document(updatedAt: 100)
        let legacy = document(updatedAt: 200)
        try save(current, to: currentURL(root, current.deviceID))
        try save(legacy, to: legacyURL(root, legacy.deviceID))
        try Data("not json".utf8).write(to: currentURL(root, "malformed"))
        var unsupported = document(updatedAt: 300)
        unsupported.schema = "egasu.history.unsupported"
        try save(unsupported, to: legacyURL(root, "unsupported"))
        var invalid = document(updatedAt: 400)
        invalid.deviceName = ""
        try save(invalid, to: currentURL(root, "invalid"))

        let result = try await store.loadDocuments()

        XCTAssertEqual(Set(result.documents), Set([current, legacy]))
        XCTAssertEqual(result.invalidFileMessages.count, 3)
        for name in ["malformed.json", "unsupported.json", "invalid.json"] {
            XCTAssertTrue(result.invalidFileMessages.contains { $0.contains(name) }, name)
        }
    }

    func testFirstWriteUsesHistoryWithoutAVersionDirectory() async throws {
        let (root, store) = try makeFixture()
        let own = document(updatedAt: 100)

        try await store.write(own)

        XCTAssertEqual(try read(currentURL(root, own.deviceID)), own)
        XCTAssertFalse(exists(root.appendingPathComponent("egasu/History/v1")))
        XCTAssertFalse(exists(root.appendingPathComponent("OpenUsage")))
    }

    func testWriteReplacesItsCurrentDocumentAndRemovesOnlyItsLegacyFile() async throws {
        let (root, store) = try makeFixture()
        let old = document(updatedAt: 100)
        var own = old
        own.updatedAt = Date(timeIntervalSince1970: 200)
        own.deviceName = "Updated Mac"
        let peer = document(updatedAt: 150)
        try save(old, to: currentURL(root, old.deviceID))
        try save(old, to: legacyURL(root, old.deviceID))
        try save(peer, to: legacyURL(root, peer.deviceID))

        try await store.write(own)

        XCTAssertEqual(try read(currentURL(root, own.deviceID)), own)
        XCTAssertFalse(exists(legacyURL(root, own.deviceID)))
        XCTAssertEqual(try read(legacyURL(root, peer.deviceID)), peer)
        XCTAssertFalse(exists(currentURL(root, peer.deviceID)), "다른 Mac의 기록은 대신 복사하지 않음")
        let result = try await store.loadDocuments()
        XCTAssertEqual(Set(result.documents), Set([own, peer]))
    }

    func testFailedCurrentWritePreservesTheLegacyDocument() async throws {
        let (root, store) = try makeFixture()
        let old = document(updatedAt: 100)
        try save(old, to: legacyURL(root, old.deviceID))
        let blocked = root.appendingPathComponent("egasu/History")
        try FileManager.default.createDirectory(
            at: blocked.deletingLastPathComponent(), withIntermediateDirectories: true)
        let marker = Data("existing file".utf8)
        try marker.write(to: blocked)
        var updated = old
        updated.updatedAt = Date(timeIntervalSince1970: 200)

        _ = await assertFailure { try await store.write(updated) }

        XCTAssertEqual(try read(legacyURL(root, old.deviceID)), old)
        XCTAssertEqual(try Data(contentsOf: blocked), marker)
    }

    func testLegacyCleanupFailurePreservesNewDataAndRetriesOnTheNextWrite() async throws {
        let (root, store) = try makeFixture()
        let old = document(updatedAt: 100)
        let legacy = legacyURL(root, old.deviceID)
        try save(old, to: legacy)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: legacy.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacy.path) }
        var updated = old
        updated.updatedAt = Date(timeIntervalSince1970: 200)

        _ = await assertFailure { try await store.write(updated) }

        XCTAssertEqual(try read(currentURL(root, old.deviceID)), updated)
        XCTAssertEqual(try read(legacy), old)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacy.path)
        try await store.write(updated)
        XCTAssertFalse(exists(legacy))
        XCTAssertEqual(try read(currentURL(root, old.deviceID)), updated)
    }

    func testInvalidDocumentCannotReplaceOrRemoveExistingHistory() async throws {
        let (root, store) = try makeFixture()
        let old = document(updatedAt: 100)
        try save(old, to: legacyURL(root, old.deviceID))
        var invalid = old
        invalid.schema = "unsupported"

        let error = await assertFailure { try await store.write(invalid) }

        XCTAssertEqual(error as? UsageHistoryDocumentError, .unsupportedSchema)
        XCTAssertEqual(try read(legacyURL(root, old.deviceID)), old)
        XCTAssertFalse(exists(currentURL(root, old.deviceID)))
    }

    func testDeleteRemovesBothCopiesAndPreservesOtherDevices() async throws {
        let (root, store) = try makeFixture()
        let own = document(updatedAt: 100)
        let peer = document(updatedAt: 200)
        for makeURL in [currentURL, legacyURL] {
            try save(own, to: makeURL(root, own.deviceID))
            try save(peer, to: makeURL(root, peer.deviceID))
        }

        try await store.delete(deviceID: own.deviceID)

        for makeURL in [currentURL, legacyURL] {
            XCTAssertFalse(exists(makeURL(root, own.deviceID)))
            XCTAssertEqual(try read(makeURL(root, peer.deviceID)), peer)
        }
    }

    func testDeletingMissingDocumentsDoesNotCreateDirectories() async throws {
        let (root, store) = try makeFixture()

        try await store.delete(deviceID: UUID().uuidString.lowercased())

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testPartialDeleteThrowsAndCanFinishAfterRetry() async throws {
        let (root, store) = try makeFixture()
        let own = document(updatedAt: 100)
        let current = currentURL(root, own.deviceID)
        let legacy = legacyURL(root, own.deviceID)
        try save(own, to: current)
        try save(own, to: legacy)
        try FileManager.default.setAttributes([.immutable: true], ofItemAtPath: legacy.path)
        defer { try? FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacy.path) }

        _ = await assertFailure { try await store.delete(deviceID: own.deviceID) }

        XCTAssertFalse(exists(current))
        XCTAssertEqual(try read(legacy), own)
        try FileManager.default.setAttributes([.immutable: false], ofItemAtPath: legacy.path)
        try await store.delete(deviceID: own.deviceID)
        XCTAssertFalse(exists(current))
        XCTAssertFalse(exists(legacy))
    }

    func testInvalidDeletionIDIsRejectedBeforeResolvingTheContainer() async {
        let store = ICloudUsageHistoryFileStore(containerURL: {
            XCTFail("잘못된 기기 ID는 iCloud 접근 전에 거부")
            return nil
        })

        let error = await assertFailure { try await store.delete(deviceID: "../outside") }

        guard case ICloudUsageSyncError.invalidDeviceID? = error else {
            return XCTFail("Expected invalidDeviceID, got \(String(describing: error))")
        }
    }

    func testUnavailableContainerFailsReadWriteAndDelete() async {
        let store = ICloudUsageHistoryFileStore(containerURL: { nil })
        let own = document(updatedAt: 100)
        let errors = [
            await assertFailure { _ = try await store.loadDocuments() },
            await assertFailure { try await store.write(own) },
            await assertFailure { try await store.delete(deviceID: own.deviceID) }
        ]

        for error in errors {
            guard case ICloudUsageSyncError.unavailable? = error else {
                XCTFail("Expected unavailable, got \(String(describing: error))")
                continue
            }
        }
    }

    private func makeFixture() throws -> (URL, ICloudUsageHistoryFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ICloudHistoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, ICloudUsageHistoryFileStore(containerURL: { root }))
    }

    private func document(updatedAt: TimeInterval) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString.lowercased(), deviceName: "Test Mac",
            updatedAt: Date(timeIntervalSince1970: updatedAt),
            providers: [
                "claude": ProviderUsageHistory(
                    series: DailyUsageSeries(daily: [
                        DailyUsageEntry(date: "2026-11-13", totalTokens: 100, costUSD: 1.25)
                    ]))
            ]
        )
    }

    private func currentURL(_ root: URL, _ deviceID: String) -> URL {
        root.appendingPathComponent("egasu/History/\(deviceID).json")
    }

    private func legacyURL(_ root: URL, _ deviceID: String) -> URL {
        root.appendingPathComponent("OpenUsage/History/v1/\(deviceID).json")
    }

    private func save(_ document: UsageHistoryDocument, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url)
    }

    private func read(_ url: URL) throws -> UsageHistoryDocument {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(UsageHistoryDocument.self, from: Data(contentsOf: url))
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

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
}
