import Foundation

/// 1.0.0까지의 "OpenUsage" 저장 위치를 egasu 이름으로 한 번 옮김 — 완료 표시 뒤에는 다시 확인하지 않음.
/// 운영 번들은 폴더 항목을 이동, 다른 번들(개발 빌드)은 운영 앱 데이터를 두고 상태만 복사(캐시는 새로 만듦).
/// Keychain은 복사만 — 승인 없이 읽히지 않는 항목은 `PendingKeychainMigration`에 남겨 승인 창이 허용되는 읽기에서 옮김.
enum StorageMigration {
    static let completedKey = "openusage.storageMigration.v1"
    static let configCompletedKey = "openusage.storageMigration.config.v1"
    /// 로그인 작업 공간과 상태 — 운영은 이동, 다른 번들은 복사.
    static let stateEntries = ["AccountSignIn", "antigravity", "claude-usage-state", "codex-weekly-timer-attempts.json"]
    /// 다시 만들 수 있는 캐시 — 운영만 이동(로그 캐시 재생성 시간 절약).
    static let cacheEntries = ["log-scan-cache", "pricing"]
    /// `~/.config/openusage`의 API 키 — 원본 OpenUsage 앱도 읽을 수 있어 복사만.
    static let configFiles = ["openrouter.json", "zai.json"]

    enum MigrationError: Error { case requiredFiles }

    struct Environment {
        var namespace: StorageNamespace = .current
        var applicationSupportRoot: URL = StorageNamespace.applicationSupportRoot()
        var configRoot: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
            ".config", isDirectory: true)
        var defaults: UserDefaults = .standard
        var keychain: KeychainAccessing = SecurityKeychainAccessor()
        var pending: PendingKeychainMigration = .shared
        var fileManager: FileManager = .default
    }

    /// 앱 시작 때 저장소를 쓰는 코드보다 먼저 호출. 파일 단계가 실패하면 완료 표시 없이 다음 실행에서 재시도.
    @MainActor
    @discardableResult
    static func runIfNeeded(_ environment: Environment = Environment()) throws -> Bool {
        guard !environment.defaults.bool(forKey: completedKey) else { return false }
        let filesCarried = try carryFiles(environment)
        guard let waiting = carryKeychain(environment) else { return true }
        if filesCarried { environment.defaults.set(true, forKey: completedKey) }
        AppLog.info(
            .config,
            "storage migration to \(environment.namespace.name): files \(filesCarried ? "done" : "retry next launch"), keychain waiting for approval \(waiting)"
        )
        return true
    }

    private static func carryFiles(_ environment: Environment) throws -> Bool {
        let fileManager = environment.fileManager
        let moves = environment.namespace.isProduction
        var succeeded = true
        func carry(_ source: URL, to destination: URL, move: Bool) {
            do {
                guard !fileManager.fileExists(atPath: destination.path),
                    try sourceExists(source, fileManager: fileManager)
                else { return }
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
                if move {
                    try fileManager.moveItem(at: source, to: destination)
                } else {
                    try copyComplete(source, to: destination, fileManager: fileManager)
                }
            } catch {
                succeeded = false
                AppLog.error(
                    .config,
                    "storage migration couldn't carry \(source.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let legacy = environment.applicationSupportRoot.appendingPathComponent(
            StorageNamespace.legacyName, isDirectory: true)
        let target = environment.applicationSupportRoot.appendingPathComponent(
            environment.namespace.name, isDirectory: true)
        for entry in stateEntries {
            if entry == "claude-usage-state" {
                succeeded = carryClaudeUsageState(environment) && succeeded
                continue
            }
            carry(legacy.appendingPathComponent(entry), to: target.appendingPathComponent(entry), move: moves)
        }
        guard succeeded else { throw MigrationError.requiredFiles }
        guard carryConfigFiles(environment) else { throw MigrationError.requiredFiles }
        if moves {
            for entry in cacheEntries {
                carry(legacy.appendingPathComponent(entry), to: target.appendingPathComponent(entry), move: true)
            }
        }
        return succeeded
    }

    /// CLI 조회 전에 API 키·Claude 조회 상태 이전 — 나머지 앱 상태·Keychain과 전체 완료 표시는 앱 실행에 유지.
    static func runForCLI(_ environment: Environment = Environment()) throws {
        guard carryConfigFiles(environment) else {
            throw UsageReaderError.refreshFailed(
                "Couldn't prepare the saved API key files. Check the egasu log and try again.")
        }
        guard carryClaudeUsageState(environment) else {
            throw UsageReaderError.refreshFailed(
                "Couldn't prepare the saved Claude usage state. Check the egasu log and try again.")
        }
    }

    /// 먼저 실행한 앱·CLI의 상태는 보존하고, 아직 없는 계정 파일만 이전.
    private static func carryClaudeUsageState(_ environment: Environment) -> Bool {
        guard !environment.defaults.bool(forKey: completedKey) else { return true }
        let fileManager = environment.fileManager
        let legacy = environment.applicationSupportRoot
            .appendingPathComponent("\(StorageNamespace.legacyName)/claude-usage-state", isDirectory: true)
        let target = environment.applicationSupportRoot
            .appendingPathComponent("\(environment.namespace.name)/claude-usage-state", isDirectory: true)
        do {
            guard try sourceExists(legacy, fileManager: fileManager) else { return true }
            let files = try fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
            try fileManager.createDirectory(
                at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var succeeded = true
            let names = Set(
                files.compactMap { file -> String? in
                    let name = file.lastPathComponent
                    if name.hasSuffix(".json.lock") { return String(name.dropLast(5)) }
                    return name.hasSuffix(".json") ? name : nil
                })
            for name in names {
                let source = legacy.appendingPathComponent(name)
                let destination = target.appendingPathComponent(name)
                guard !fileManager.fileExists(atPath: destination.path) else { continue }
                do {
                    let lease = try ClaudeUsageStateStore.tryAcquireForMigration(fileURL: source)
                    defer { withExtendedLifetime(lease) {} }
                    guard !fileManager.fileExists(atPath: destination.path),
                        try sourceExists(source, fileManager: fileManager)
                    else { continue }
                    if environment.namespace.isProduction {
                        try fileManager.moveItem(at: source, to: destination)
                    } else {
                        try copyComplete(source, to: destination, fileManager: fileManager)
                    }
                } catch let error as CocoaError
                    where
                    (error.code == .fileWriteFileExists || error.code == .fileNoSuchFile
                    || error.code == .fileReadNoSuchFile)
                    && fileManager.fileExists(atPath: destination.path)
                {
                    continue
                } catch {
                    succeeded = false
                    AppLog.error(
                        .config, "storage migration couldn't carry Claude usage state: \(error.localizedDescription)")
                }
            }
            return succeeded
        } catch {
            AppLog.error(.config, "storage migration couldn't open Claude usage state: \(error.localizedDescription)")
            return false
        }
    }

    private static func carryConfigFiles(_ environment: Environment) -> Bool {
        guard !environment.defaults.bool(forKey: completedKey),
            !environment.defaults.bool(forKey: configCompletedKey)
        else { return true }
        let fileManager = environment.fileManager
        let legacy = environment.configRoot.appendingPathComponent("openusage", isDirectory: true)
        let target = environment.configRoot.appendingPathComponent(environment.namespace.name, isDirectory: true)
        var succeeded = true
        for file in configFiles {
            let source = legacy.appendingPathComponent(file)
            let destination = target.appendingPathComponent(file)
            do {
                guard !fileManager.fileExists(atPath: destination.path),
                    try sourceExists(source, fileManager: fileManager)
                else { continue }
                try fileManager.createDirectory(
                    at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try copyComplete(source.resolvingSymlinksInPath(), to: destination, fileManager: fileManager)
            } catch CocoaError.fileWriteFileExists where fileManager.fileExists(atPath: destination.path) {
                // 앱과 CLI가 함께 시작해 먼저 복사한 파일은 보존.
                continue
            } catch {
                succeeded = false
                AppLog.error(.config, "storage migration couldn't carry \(file): \(error.localizedDescription)")
            }
        }
        if succeeded { environment.defaults.set(true, forKey: configCompletedKey) }
        return succeeded
    }

    private static func sourceExists(_ source: URL, fileManager: FileManager) throws -> Bool {
        do {
            _ = try fileManager.attributesOfItem(atPath: source.path)
            return true
        } catch {
            let nsError = error as NSError
            if (nsError.domain == NSCocoaErrorDomain
                && (nsError.code == CocoaError.fileNoSuchFile.rawValue
                    || nsError.code == CocoaError.fileReadNoSuchFile.rawValue))
                || (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT))
            {
                return false
            }
            throw error
        }
    }

    private static func copyComplete(_ source: URL, to destination: URL, fileManager: FileManager) throws {
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try fileManager.copyItem(at: source, to: staging)
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            if fileManager.fileExists(atPath: staging.path) {
                do {
                    try fileManager.removeItem(at: staging)
                } catch {
                    AppLog.error(
                        .config, "storage migration couldn't remove temporary copy: \(error.localizedDescription)")
                    throw error
                }
            }
            if let cocoaError = error as? CocoaError, cocoaError.code == .fileWriteFileExists,
                fileManager.fileExists(atPath: destination.path)
            {
                return
            }
            throw error
        }
    }

    /// 등록 계정 이전의 승인 대기 수 반환 — 등록 데이터를 읽지 못하면 nil.
    @MainActor
    private static func carryKeychain(_ environment: Environment) -> Int? {
        guard let data = environment.defaults.data(forKey: AccountProfilesStore.storageKey) else { return 0 }
        let registry: AccountProfilesStore.Blob
        do {
            registry = try JSONDecoder().decode(AccountProfilesStore.Blob.self, from: data)
        } catch {
            AppDiagnostics.failure(.storageMigration, error: error, localContext: "Account registry migration failed")
            return nil
        }
        let vault = AccountCredentialVault(
            keychain: environment.keychain, pendingMigration: environment.pending, namespace: environment.namespace
        )
        var waiting = 0
        for profile in registry.profiles
        where !profile.isArchived && AccountProfilesStore.isSupportedFamily(profile.family) {
            environment.pending.record(family: profile.family, profileID: profile.id)
            do {
                _ = try vault.load(profile: profile)
                environment.pending.finish(family: profile.family, profileID: profile.id)
            } catch {
                waiting += 1
                AppLog.warn(
                    .keychain,
                    "a saved \(profile.family) sign-in needs Keychain approval before it can move to the egasu name")
            }
        }
        return waiting
    }
}

/// 1.0.0 이름에서 첫 실행 때 옮기지 못한 계정 — 이 계정만 옛 이름을 다시 읽음.
final class PendingKeychainMigration: @unchecked Sendable {
    static let shared = PendingKeychainMigration(defaults: .standard)
    static let storageKey = "openusage.storageMigration.pendingKeychain.v1"

    private let defaults: UserDefaults
    private let lock = NSLock()

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    func contains(family: String, profileID: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries.contains(Self.entry(family, profileID))
    }

    func record(family: String, profileID: String) {
        lock.lock()
        defer { lock.unlock() }
        let entry = Self.entry(family, profileID)
        guard !entries.contains(entry) else { return }
        defaults.set(entries + [entry], forKey: Self.storageKey)
    }

    func finish(family: String, profileID: String) {
        lock.lock()
        defer { lock.unlock() }
        let remaining = entries.filter { $0 != Self.entry(family, profileID) }
        guard remaining.count != entries.count else { return }
        if remaining.isEmpty {
            defaults.removeObject(forKey: Self.storageKey)
        } else {
            defaults.set(remaining, forKey: Self.storageKey)
        }
    }

    private var entries: [String] { defaults.stringArray(forKey: Self.storageKey) ?? [] }

    private static func entry(_ family: String, _ profileID: String) -> String { "\(family)/\(profileID)" }
}
