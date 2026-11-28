import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageHistoryDeletionCoordinationTests: XCTestCase {
    func testDeletingOwnHistoryDoesNotRequestDeletionOfPresentedPeer() async throws {
        for location in historyLocations {
            let (root, store) = try makeFixture()
            let own = document()
            let peer = document()
            let ownURL = historyURL(root, location: location, name: own.deviceID)
            let peerURL = historyURL(root, location: location, name: peer.deviceID)
            try save(own, to: ownURL)
            try save(peer, to: peerURL)
            let presenter = HistoryDeletionCoordinationPresenter(url: peerURL)
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }

            try await store.delete(deviceID: own.deviceID)

            XCTAssertFalse(FileManager.default.fileExists(atPath: ownURL.path), location)
            XCTAssertEqual(try read(peerURL), peer, location)
            XCTAssertEqual(presenter.deletionRequestCount, 0, location)
        }
    }

    func testPeerReplacementDeliveredWhileDeletionWaitsIsPreserved() async throws {
        for location in historyLocations {
            let (root, store) = try makeFixture()
            let own = document()
            let peer = document()
            let url = historyURL(root, location: location, name: own.deviceID)
            try save(own, to: url)
            let presenter = HistoryDeletionCoordinationPresenter(url: url, replacementData: try encoded(peer))
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }

            try await store.delete(deviceID: own.deviceID)

            XCTAssertGreaterThan(presenter.relinquishCount, 0, location)
            XCTAssertTrue(presenter.replacementAttempted, location)
            XCTAssertNil(presenter.replacementFailure, location)
            XCTAssertEqual(try read(url), peer, location)
            XCTAssertEqual(presenter.deletionRequestCount, 0, location)
        }
    }

    func testSameDeviceUpdateDeliveredWhileDeletionWaitsIsDeleted() async throws {
        for location in historyLocations {
            let (root, store) = try makeFixture()
            let own = document()
            var updated = own
            updated.deviceName = "Updated Mac"
            updated.updatedAt = own.updatedAt.addingTimeInterval(1)
            let url = historyURL(root, location: location, name: own.deviceID)
            try save(own, to: url)
            let presenter = HistoryDeletionCoordinationPresenter(url: url, replacementData: try encoded(updated))
            NSFileCoordinator.addFilePresenter(presenter)
            defer { NSFileCoordinator.removeFilePresenter(presenter) }

            try await store.delete(deviceID: own.deviceID)

            XCTAssertGreaterThan(presenter.relinquishCount, 0, location)
            XCTAssertTrue(presenter.replacementAttempted, location)
            XCTAssertNil(presenter.replacementFailure, location)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), location)
            XCTAssertEqual(presenter.deletionRequestCount, 0, location)
        }
    }

    private var historyLocations: [String] { ["egasu/History", "OpenUsage/History/v1"] }

    private func makeFixture() throws -> (URL, ICloudUsageHistoryFileStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ICloudHistoryDeletionCoordinationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return (root, ICloudUsageHistoryFileStore(containerURL: { root }))
    }

    private func document() -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture Mac",
            updatedAt: Date(timeIntervalSince1970: 100), providers: [:])
    }

    private func historyURL(_ root: URL, location: String, name: String) -> URL {
        root.appendingPathComponent(location).appendingPathComponent(name).appendingPathExtension("json")
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
}

private final class HistoryDeletionCoordinationPresenter: NSObject, NSFilePresenter {
    let presentedItemURL: URL?
    let presentedItemOperationQueue = OperationQueue()
    private let replacementData: Data?
    private let lock = NSLock()
    private var state = State()

    private struct State {
        var relinquishCount = 0
        var deletionRequestCount = 0
        var replacementAttempted = false
        var replacementFailure: String?
    }

    var relinquishCount: Int { lock.withLock { state.relinquishCount } }
    var deletionRequestCount: Int { lock.withLock { state.deletionRequestCount } }
    var replacementAttempted: Bool { lock.withLock { state.replacementAttempted } }
    var replacementFailure: String? { lock.withLock { state.replacementFailure } }

    init(url: URL, replacementData: Data? = nil) {
        presentedItemURL = url
        self.replacementData = replacementData
        super.init()
        presentedItemOperationQueue.maxConcurrentOperationCount = 1
    }

    func relinquishPresentedItem(toWriter writer: @escaping @Sendable ((@Sendable () -> Void)?) -> Void) {
        defer { writer(nil) }
        let shouldReplace = lock.withLock {
            state.relinquishCount += 1
            guard replacementData != nil, !state.replacementAttempted else { return false }
            state.replacementAttempted = true
            return true
        }
        guard shouldReplace, let replacementData, let presentedItemURL else { return }
        // 조정 accessor가 진입하기 전에 최신 파일 전달 — 시간 지연 없이 실제 writer 대기 경계 재현.
        do {
            try replacementData.write(to: presentedItemURL, options: .atomic)
        } catch {
            lock.withLock { state.replacementFailure = error.localizedDescription }
        }
    }

    func accommodatePresentedItemDeletion(completionHandler: @escaping @Sendable (Error?) -> Void) {
        lock.withLock { state.deletionRequestCount += 1 }
        completionHandler(CocoaError(.userCancelled))
    }
}
