import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ICloudUsageHistoryDirectoryFailureTests: XCTestCase {
    func testUnreadableCurrentDirectoryStillLoadsLegacy() async throws {
        try await assertPartialRead(blocked: "egasu/History", valid: "OpenUsage/History/v1", blockedName: "History")
    }

    func testUnreadableLegacyDirectoryPreservesCurrentResults() async throws {
        try await assertPartialRead(blocked: "OpenUsage/History/v1", valid: "egasu/History", blockedName: "v1")
    }

    private func assertPartialRead(blocked: String, valid: String, blockedName: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "HistoryDirectory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let blockedURL = root.appendingPathComponent(blocked)
        try FileManager.default.createDirectory(
            at: blockedURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a directory".utf8).write(to: blockedURL)
        let directory = root.appendingPathComponent(valid)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = UsageHistoryDocument(
            deviceID: UUID().uuidString.lowercased(), deviceName: "Fixture",
            updatedAt: Date(timeIntervalSince1970: 100),
            providers: [
                "claude": ProviderUsageHistory(
                    series: DailyUsageSeries(daily: [
                        DailyUsageEntry(date: "2026-11-13", totalTokens: 100, costUSD: 1.25)
                    ]))
            ])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: directory.appendingPathComponent("valid.json"))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("invalid.json"))

        let result = try await ICloudUsageHistoryFileStore(containerURL: { root }).loadDocuments()

        XCTAssertEqual(result.documents, [document])
        XCTAssertEqual(result.invalidFileMessages.count, 2)
        XCTAssertTrue(result.invalidFileMessages.contains { $0.hasPrefix("\(blockedName):") })
        XCTAssertTrue(result.invalidFileMessages.contains { $0.hasPrefix("invalid.json:") })
        XCTAssertFalse(result.failureCategories.isEmpty)
    }
}
