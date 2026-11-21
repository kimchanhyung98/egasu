import XCTest
@testable import Egasu

@MainActor
final class StorageMigrationProbeTests: XCTestCase {
    func testUnreadableSourcesDoNotCompleteAndRetryAfterAccessReturns() throws {
        for path in [
            "support/OpenUsage/AccountSignIn", "support/OpenUsage/claude-usage-state",
            "config/openusage/openrouter.json"
        ] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "StorageProbe-\(UUID().uuidString)")
            let domain = "StorageMigrationProbeTests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
            defer {
                defaults.removePersistentDomain(forName: domain)
                try? FileManager.default.removeItem(at: root)
            }
            let source = root.appendingPathComponent(path)
            if path.hasSuffix(".json") {
                try FileManager.default.createDirectory(
                    at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("fixture".utf8).write(to: source)
            } else {
                try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            }
            let files = DeniedProbeFileManager(deniedPath: source.path)
            let environment = StorageMigration.Environment(
                namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
                applicationSupportRoot: root.appendingPathComponent("support"),
                configRoot: root.appendingPathComponent("config"), defaults: defaults,
                pending: PendingKeychainMigration(defaults: defaults), fileManager: files)
            XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment), path)
            XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey), path)
            if path.contains("config/") { XCTAssertFalse(defaults.bool(forKey: StorageMigration.configCompletedKey)) }
            files.denied = false
            XCTAssertTrue(try StorageMigration.runIfNeeded(environment), path)
            XCTAssertTrue(defaults.bool(forKey: StorageMigration.completedKey), path)
            let destinationPath = path.replacingOccurrences(of: "OpenUsage", with: "egasu.dev")
                .replacingOccurrences(of: "openusage", with: "egasu.dev")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: root.appendingPathComponent(destinationPath).path), path)
        }
    }

    func testExistingDestinationRemainsAuthoritativeWhenSourceCannotBeProbed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageExisting-\(UUID().uuidString)")
        let domain = "StorageMigrationProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("config/openusage/openrouter.json")
        let destination = root.appendingPathComponent("config/egasu.dev/openrouter.json")
        try FileManager.default.createDirectory(
            at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("old".utf8).write(to: source)
        try Data("winner".utf8).write(to: destination)
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
            applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: root.appendingPathComponent("config"), defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults),
            fileManager: DeniedProbeFileManager(deniedPath: source.path))
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "winner")
    }

    func testExistingStateDirectoryRemainsAuthoritativeWhenSourceCannotBeProbed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageExistingState-\(UUID().uuidString)")
        let domain = "StorageMigrationProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let source = root.appendingPathComponent("support/OpenUsage/AccountSignIn")
        let destination = root.appendingPathComponent("support/egasu.dev/AccountSignIn")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try Data("winner".utf8).write(to: destination.appendingPathComponent("fixture"))
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
            applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: root.appendingPathComponent("config"), defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults),
            fileManager: DeniedProbeFileManager(deniedPath: source.path))
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("fixture"), encoding: .utf8), "winner")
    }

    func testMissingSourcesAreNoOp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageMissing-\(UUID().uuidString)")
        let domain = "StorageMigrationProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev"),
            applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: root.appendingPathComponent("config"), defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults))
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertTrue(defaults.bool(forKey: StorageMigration.completedKey))
    }

    func testCorruptRegistryStartsWithoutCompletingAndRetriesRestoredProfiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("StorageRegistry-\(UUID().uuidString)")
        let domain = "StorageMigrationProbeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let namespace = StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev")
        let oldService = AccountCredentialVault.legacyService(family: "codex", profileID: "p1")
        let newService = AccountCredentialVault.service(family: "codex", profileID: "p1", namespace: namespace)
        let entry = AccountCredentialVault.Entry(credential: "fixture", claudeOAuthAccount: nil)
        let encoded = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        let keychain = ServiceKeychain(values: [oldService: encoded])
        let pending = PendingKeychainMigration(defaults: defaults)
        let environment = StorageMigration.Environment(
            namespace: namespace, applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: root.appendingPathComponent("config"), defaults: defaults,
            keychain: keychain, pending: pending)
        let corrupted = Data("invalid".utf8)
        let diagnostics = DiagnosticEventRecorder()
        defaults.set(corrupted, forKey: AccountProfilesStore.storageKey)
        for _ in 0..<2 {
            XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
            XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
            XCTAssertEqual(defaults.data(forKey: AccountProfilesStore.storageKey), corrupted)
            XCTAssertEqual(keychain.values[oldService], encoded)
            XCTAssertNil(keychain.currentUserValues[newService])
            XCTAssertFalse(pending.contains(family: "codex", profileID: "p1"))
        }
        XCTAssertEqual(diagnostics.events.map(\.operation), [.storageMigration, .storageMigration])
        let store = AccountProfilesStore(defaults: defaults)
        XCTAssertTrue(store.hasUnreadableRegistry)
        XCTAssertThrowsError(try store.add(family: "codex", label: "Profile", identityKey: "id"))
        let profile = AccountProfile(id: "p1", family: "codex", label: "Profile", identityKey: "id", createdAt: Date())
        defaults.set(
            try JSONEncoder().encode(AccountProfilesStore.Blob(profiles: [profile], preferredByFamily: [:])),
            forKey: AccountProfilesStore.storageKey)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertTrue(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertEqual(keychain.values[oldService], encoded)
        XCTAssertEqual(keychain.currentUserValues[newService], encoded)
    }
}

private final class DeniedProbeFileManager: FileManager, @unchecked Sendable {
    let deniedPath: String
    var denied = true
    init(deniedPath: String) { self.deniedPath = deniedPath; super.init() }
    override func fileExists(atPath path: String) -> Bool {
        if denied && path == deniedPath { return false }
        return super.fileExists(atPath: path)
    }
    override func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        if denied && path == deniedPath { throw CocoaError(.fileReadNoPermission) }
        return try super.attributesOfItem(atPath: path)
    }
}
