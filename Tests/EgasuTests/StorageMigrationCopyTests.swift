import XCTest
@testable import Egasu

@MainActor
final class StorageMigrationCopyTests: XCTestCase {
    func testPartialDirectoryCopyFailureRetriesAllFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageMigrationCopy-\(UUID().uuidString)")
        let domain = "StorageMigrationCopyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let support = root.appendingPathComponent("support")
        let legacy = support.appendingPathComponent("OpenUsage/AccountSignIn")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("first".utf8).write(to: legacy.appendingPathComponent("first"))
        try Data("second".utf8).write(to: legacy.appendingPathComponent("second"))
        let files = PartialCopyFileManager()
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
            applicationSupportRoot: support, configRoot: root.appendingPathComponent("config"), defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults), fileManager: files)

        XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        let target = support.appendingPathComponent("egasu.dev/AccountSignIn")
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: target.deletingLastPathComponent().path).isEmpty)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("first"), encoding: .utf8), "first")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("second"), encoding: .utf8), "second")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("second").path))
    }
    func testPartialFileCopiesRemainRetryable() throws {
        for path in ["config/openusage/openrouter.json", "support/OpenUsage/claude-usage-state/record.json"] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "StorageCopyFile-\(UUID().uuidString)")
            let domain = "StorageMigrationCopyTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer {
                defaults.removePersistentDomain(forName: domain)
                try? FileManager.default.removeItem(at: root)
            }
            let source = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("complete".utf8).write(to: source)
            let files = PartialCopyFileManager(failingName: source.lastPathComponent)
            let environment = StorageMigration.Environment(
                namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
                applicationSupportRoot: root.appendingPathComponent("support"),
                configRoot: root.appendingPathComponent("config"), defaults: defaults,
                pending: PendingKeychainMigration(defaults: defaults), fileManager: files)
            let destination =
                path.hasPrefix("config/")
                ? root.appendingPathComponent("config/egasu.dev/openrouter.json")
                : root.appendingPathComponent("support/egasu.dev/claude-usage-state/record.json")
            XCTAssertThrowsError(try StorageMigration.runForCLI(environment))
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
            let remaining = try FileManager.default.contentsOfDirectory(
                atPath: destination.deletingLastPathComponent().path)
            XCTAssertFalse(remaining.contains { $0.hasSuffix(".tmp") })
            try StorageMigration.runForCLI(environment)
            XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "complete")
            XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "complete")
        }
    }

    func testConcurrentPublisherWinsWithoutLeavingTemporaryCopy() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageCopyRace-\(UUID().uuidString)")
        let domain = "StorageMigrationCopyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let config = root.appendingPathComponent("config")
        let source = config.appendingPathComponent("openusage/openrouter.json")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("legacy".utf8).write(to: source)
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
            applicationSupportRoot: root.appendingPathComponent("support"), configRoot: config, defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults), fileManager: WinningPublisherFileManager())
        try StorageMigration.runForCLI(environment)
        let directory = config.appendingPathComponent("egasu.dev")
        XCTAssertEqual(
            try String(contentsOf: directory.appendingPathComponent("openrouter.json"), encoding: .utf8), "winner")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["openrouter.json"])
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "legacy")
    }

    func testCleanupFailureStopsMigrationWithoutRemovingOtherFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageCopyCleanup-\(UUID().uuidString)")
        let domain = "StorageMigrationCopyTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let legacy = root.appendingPathComponent("support/OpenUsage/AccountSignIn")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let files = PartialCopyFileManager(failingName: "AccountSignIn", denyCleanup: true)
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
            applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: root.appendingPathComponent("config"), defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults), fileManager: files)
        XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertTrue(files.cleanupAttempted)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
    }

}

private final class PartialCopyFileManager: FileManager, @unchecked Sendable {
    private var shouldFail = true
    private let failingName: String
    private let denyCleanup: Bool
    private(set) var cleanupAttempted = false

    init(failingName: String = "AccountSignIn", denyCleanup: Bool = false) {
        self.failingName = failingName
        self.denyCleanup = denyCleanup
        super.init()
    }

    override func copyItem(at source: URL, to destination: URL) throws {
        if shouldFail, source.lastPathComponent == failingName {
            shouldFail = false
            if failingName == "AccountSignIn" {
                try createDirectory(at: destination, withIntermediateDirectories: true)
                try Data("first".utf8).write(to: destination.appendingPathComponent("first"))
            } else {
                try Data("partial".utf8).write(to: destination)
            }
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try super.copyItem(at: source, to: destination)
    }

    override func removeItem(at url: URL) throws {
        if denyCleanup, url.lastPathComponent.hasSuffix(".tmp") {
            cleanupAttempted = true
            throw CocoaError(.fileWriteNoPermission)
        }
        try super.removeItem(at: url)
    }
}

private final class WinningPublisherFileManager: FileManager, @unchecked Sendable {
    override func moveItem(at source: URL, to destination: URL) throws {
        if destination.lastPathComponent == "openrouter.json" {
            try Data("winner".utf8).write(to: destination)
            throw CocoaError(.fileWriteFileExists)
        }
        try super.moveItem(at: source, to: destination)
    }
}
