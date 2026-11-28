import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageSyncDeletionHandoffTests: XCTestCase {
    private let pendingKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"

    func testEnabledSyncDoesNotDeleteCurrentDeviceAfterPreviousDeviceDeletionFails() async throws {
        let fixture = makeFixture(enabled: true)
        let files = DeletionHandoffHistoryFileStore(
            documents: fixture.documents, failingOnce: [fixture.previousID])
        let sync = makeSync(fixture, files: files)

        try await waitUntil {
            let writes = await files.writeCount
            return writes > 0 && !sync.isSyncing
        }

        let attempts = await files.deleteAttempts
        let documents = await files.documents
        XCTAssertEqual(attempts, [fixture.previousID])
        XCTAssertTrue(documents.contains { $0.deviceID == fixture.currentID })
        XCTAssertEqual(fixture.defaults.string(forKey: pendingKey), fixture.previousID)
        XCTAssertNotNil(sync.deletionError)
        XCTAssertTrue(sync.enabled)
    }

    func testReenablingWhilePreviousDeletionFailsDoesNotDeleteCurrentDevice() async throws {
        let fixture = makeFixture(enabled: false)
        let files = DeletionHandoffHistoryFileStore(
            documents: fixture.documents, failingOnce: [fixture.previousID], holdingOnce: [fixture.previousID])
        addTeardownBlock { await files.releaseDelete() }
        let sync = makeSync(fixture, files: files)
        try await waitUntil { await files.heldDeleteID == fixture.previousID }

        sync.enabled = true
        await files.releaseDelete()
        try await waitUntil {
            let writes = await files.writeCount
            return writes > 0 && !sync.isSyncing
        }

        let attempts = await files.deleteAttempts
        let documents = await files.documents
        XCTAssertEqual(attempts, [fixture.previousID, fixture.previousID])
        XCTAssertTrue(documents.contains { $0.deviceID == fixture.currentID })
        XCTAssertNil(fixture.defaults.string(forKey: pendingKey))
        XCTAssertNil(sync.deletionError)
        XCTAssertNil(sync.serviceError)
        XCTAssertTrue(sync.enabled)
    }

    func testReenablingDuringCurrentDeviceFallbackRestoresItsDocumentWithoutStaleError() async throws {
        for fallbackFailsAfterDeletion in [false, true] {
            let fixture = makeFixture(enabled: false)
            let failingIDs: Set<String> =
                fallbackFailsAfterDeletion
                ? [fixture.previousID, fixture.currentID] : [fixture.previousID]
            let files = DeletionHandoffHistoryFileStore(
                documents: fixture.documents, failingOnce: failingIDs, holdingOnce: [fixture.currentID])
            addTeardownBlock { await files.releaseDelete() }
            let sync = makeSync(fixture, files: files)
            try await waitUntil { await files.heldDeleteID == fixture.currentID }

            XCTAssertFalse(sync.enabled)
            XCTAssertEqual(fixture.defaults.string(forKey: pendingKey), fixture.previousID)
            sync.enabled = true
            await files.releaseDelete()
            try await waitUntil {
                let writes = await files.writeCount
                return writes > 0 && !sync.isSyncing
            }

            let attempts = await files.deleteAttempts
            let documents = await files.documents
            XCTAssertEqual(attempts, [fixture.previousID, fixture.currentID, fixture.previousID])
            XCTAssertEqual(documents.filter { $0.deviceID == fixture.currentID }.count, 1)
            XCTAssertTrue(sync.documents.contains { $0.deviceID == fixture.currentID })
            XCTAssertNil(fixture.defaults.string(forKey: pendingKey))
            XCTAssertNil(sync.deletionError, "이전 OFF 작업의 오류를 새 활성화 상태에 적용하지 않음")
            XCTAssertNil(sync.serviceError)
            XCTAssertTrue(sync.enabled)
        }
    }

    private struct Fixture {
        let defaults: UserDefaults
        let previousID: String
        let currentID: String
        let documents: [UsageHistoryDocument]
    }

    private func makeFixture(enabled: Bool) -> Fixture {
        let suite = "EgasuTests.ICloudDeletionHandoff.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let previousID = UUID().uuidString.lowercased()
        let currentID = UUID().uuidString.lowercased()
        defaults.set(enabled, forKey: "openusage.icloudSync.enabled.v1")
        defaults.set(previousID, forKey: pendingKey)
        let documents = [previousID, currentID].map {
            UsageHistoryDocument(
                deviceID: $0, deviceName: "Fixture Mac", updatedAt: Date(timeIntervalSince1970: 100), providers: [:])
        }
        return Fixture(defaults: defaults, previousID: previousID, currentID: currentID, documents: documents)
    }

    private func makeSync(_ fixture: Fixture, files: DeletionHandoffHistoryFileStore) -> ICloudUsageSyncStore {
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry(providers: [], descriptors: []), providers: [],
            cache: ProviderSnapshotCache(userDefaults: fixture.defaults, storageKey: "snapshots"),
            defaults: fixture.defaults)
        return ICloudUsageSyncStore(
            dataStore: dataStore, defaults: fixture.defaults, fileStore: files,
            deviceIDStore: DeletionHandoffDeviceIDStore(deviceID: fixture.currentID),
            observesMetadataChanges: false)
    }

    private func waitUntil(
        file: StaticString = #filePath, line: UInt = #line,
        condition: @escaping () async -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
        throw WaitError.timedOut
    }

    private enum WaitError: Error { case timedOut }
}

private struct DeletionHandoffDeviceIDStore: ICloudDeviceIDStoring {
    let deviceID: String

    func readDeviceID() throws -> String? { deviceID }
    func writeDeviceID(_ deviceID: String) throws {}
}

private actor DeletionHandoffHistoryFileStore: UsageHistoryFileStoring {
    private(set) var documents: [UsageHistoryDocument]
    private(set) var deleteAttempts: [String] = []
    private(set) var writeCount = 0
    private(set) var heldDeleteID: String?
    private var failingOnce: Set<String>
    private var holdingOnce: Set<String>
    private var deleteGate: CheckedContinuation<Void, Never>?

    init(documents: [UsageHistoryDocument], failingOnce: Set<String>, holdingOnce: Set<String> = []) {
        self.documents = documents
        self.failingOnce = failingOnce
        self.holdingOnce = holdingOnce
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        UsageHistoryLoadResult(documents: documents)
    }

    func write(_ document: UsageHistoryDocument, replacing previous: UsageHistoryDocument?) async throws {
        guard documents.first(where: { $0.deviceID == document.deviceID }) == previous else {
            throw ICloudHistoryChangedDuringWrite()
        }
        documents.removeAll { $0.deviceID == document.deviceID }
        documents.append(document)
        writeCount += 1
    }

    func delete(deviceID: String) async throws {
        deleteAttempts.append(deviceID)
        if holdingOnce.remove(deviceID) != nil {
            await withCheckedContinuation { continuation in
                heldDeleteID = deviceID
                deleteGate = continuation
            }
        }
        documents.removeAll { $0.deviceID == deviceID }
        // 자기 문서 제거 뒤 다른 파일 오류가 드러나는 실제 부분 삭제 경계.
        if failingOnce.remove(deviceID) != nil { throw CocoaError(.fileWriteUnknown) }
    }

    func releaseDelete() {
        let continuation = deleteGate
        deleteGate = nil
        heldDeleteID = nil
        continuation?.resume()
    }
}
