import Foundation

/// 계정 전환에 쓰이는 인증 snapshot의 전용 Keychain 저장소 — 앱 구현 세부사항.
/// profile metadata·로그·UI 상태에 값 포함 금지.
struct AccountCredentialVault {
    struct Entry: Codable, Equatable, Sendable {
        var credential: String
        var claudeOAuthAccount: String?
        /// 연속 동기화 실패로 공유 홈에 남을 수 있는 이전 Codex 인증 후보 — 갱신된 snapshot의 역덮어쓰기 방지.
        var codexStaleSharedCredentialFingerprints: Set<String>? = nil
    }

    private let keychain: KeychainAccessing
    private let pendingMigration: PendingKeychainMigration
    private let namespace: StorageNamespace
    private static let mutationLocksLock = NSLock()
    nonisolated(unsafe) private static var mutationLocks: [String: NSRecursiveLock] = [:]

    init(
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        pendingMigration: PendingKeychainMigration = .shared,
        namespace: StorageNamespace = .current
    ) {
        self.keychain = keychain
        self.pendingMigration = pendingMigration
        self.namespace = namespace
    }

    /// 등록 계정의 snapshot은 존재 확인 실패만으로 제외하지 않음.
    func contains(profile: AccountProfile) -> Bool {
        if keychain.genericPasswordExists(service: service(for: profile)) != false { return true }
        return pendingMigration.contains(family: profile.family, profileID: profile.id)
            && keychain.genericPasswordExists(
                service: Self.legacyService(family: profile.family, profileID: profile.id)) != false
    }

    func load(profile: AccountProfile, allowInteraction: Bool = false) throws -> Entry? {
        try load(family: profile.family, profileID: profile.id, allowInteraction: allowInteraction)
    }

    /// 1.0.0에서 옮기지 못한(승인이 필요했던) 계정만 옛 이름을 읽어 새 이름으로 저장 — 옛 항목은 지우지 않음.
    func load(family: String, profileID: String, allowInteraction: Bool = false) throws -> Entry? {
        if let entry = try read(
            service: serviceName(family: family, profileID: profileID), allowInteraction: allowInteraction)
        {
            return entry
        }
        guard pendingMigration.contains(family: family, profileID: profileID) else { return nil }
        let legacy = try read(
            service: Self.legacyService(family: family, profileID: profileID), allowInteraction: allowInteraction)
        let lock = mutationLock(family: family, profileID: profileID)
        lock.lock()
        defer { lock.unlock() }
        // 승인 대기 중 완료된 저장·삭제 우선 — 계정별 잠금 안에서 이전 조건 재확인.
        if let entry = try read(
            service: serviceName(family: family, profileID: profileID), allowInteraction: allowInteraction)
        {
            return entry
        }
        guard pendingMigration.contains(family: family, profileID: profileID) else { return nil }
        if let legacy {
            try write(legacy, family: family, profileID: profileID)
            AppLog.info(.keychain, "moved a saved \(family) sign-in to the egasu Keychain name")
        }
        pendingMigration.finish(family: family, profileID: profileID)
        return legacy
    }

    private func read(service: String, allowInteraction: Bool) throws -> Entry? {
        let value: String?
        do {
            value = try keychain.readAppOwnedPassword(
                service: service, forCurrentUser: true, allowInteraction: allowInteraction
            ) ?? keychain.readAppOwnedPassword(
                service: service, forCurrentUser: false, allowInteraction: allowInteraction
            )
        } catch KeychainError.invalidData {
            throw AccountCredentialVaultError.missingEntry
        }
        guard let value else { return nil }
        // 기존 hex 인코딩 snapshot도 호환.
        guard let entry = ProviderParse.decodeJSONWithHexFallback(value, as: Entry.self) else {
            throw AccountCredentialVaultError.missingEntry
        }
        return entry
    }

    func save(_ entry: Entry, profile: AccountProfile) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        let lock = mutationLock(family: profile.family, profileID: profile.id)
        lock.lock()
        defer { lock.unlock() }
        try write(entry, family: profile.family, profileID: profile.id)
        pendingMigration.finish(family: profile.family, profileID: profile.id)
    }

    private func write(_ entry: Entry, family: String, profileID: String) throws {
        let data = try JSONEncoder().encode(entry)
        try keychain.writeGenericPasswordForCurrentUser(
            service: serviceName(family: family, profileID: profileID),
            value: String(decoding: data, as: UTF8.self)
        )
    }

    func replaceCredential(
        _ credential: String, family: String, profileID: String, allowInteraction: Bool = false,
        codexStaleSharedCredentialFingerprints: Set<String>? = nil
    ) throws {
        AccountCredentialMutationLock.acquire(family: family)
        defer { AccountCredentialMutationLock.release(family: family) }
        let lock = mutationLock(family: family, profileID: profileID)
        lock.lock()
        defer { lock.unlock() }
        guard var entry = try load(family: family, profileID: profileID, allowInteraction: allowInteraction) else {
            throw AccountCredentialVaultError.missingEntry
        }
        entry.credential = credential
        if family == "codex" {
            entry.codexStaleSharedCredentialFingerprints = codexStaleSharedCredentialFingerprints
        }
        let data = try JSONEncoder().encode(entry)
        try keychain.writeGenericPasswordForCurrentUser(
            service: serviceName(family: family, profileID: profileID),
            value: String(decoding: data, as: UTF8.self)
        )
    }

    /// 새 이름의 항목만 삭제 — 1.0.0 이름의 항목은 다른 번들(운영 앱)의 것일 수 있어 그대로 둠.
    func delete(profile: AccountProfile) throws {
        AccountCredentialMutationLock.acquire(family: profile.family)
        defer { AccountCredentialMutationLock.release(family: profile.family) }
        let lock = mutationLock(family: profile.family, profileID: profile.id)
        lock.lock()
        defer { lock.unlock() }
        try keychain.deleteGenericPassword(service: service(for: profile))
        pendingMigration.finish(family: profile.family, profileID: profile.id)
    }

    static func service(family: String, profileID: String, namespace: StorageNamespace = .current) -> String {
        "\(namespace.name) Account Authentication v1 \(family) \(profileID)"
    }

    /// 1.0.0까지의 항목 이름 — `StorageMigration`과 승인 대기 계정의 읽기에서만 사용.
    static func legacyService(family: String, profileID: String) -> String {
        "\(StorageNamespace.legacyName) Account Authentication v1 \(family) \(profileID)"
    }

    private func service(for profile: AccountProfile) -> String {
        serviceName(family: profile.family, profileID: profile.id)
    }

    private func serviceName(family: String, profileID: String) -> String {
        Self.service(family: family, profileID: profileID, namespace: namespace)
    }

    private func mutationLock(family: String, profileID: String) -> NSRecursiveLock {
        let service = serviceName(family: family, profileID: profileID)
        Self.mutationLocksLock.lock()
        defer { Self.mutationLocksLock.unlock() }
        if let lock = Self.mutationLocks[service] { return lock }
        let lock = NSRecursiveLock()
        Self.mutationLocks[service] = lock
        return lock
    }
}

/// 프로바이더별 인증 비교·쓰기와 계정 전환 직렬화 — 중첩 Vault 호출 허용, 비동기 요청 중 획득 금지.
enum AccountCredentialMutationLock {
    private static let codexLock = NSRecursiveLock()
    private static let claudeLock = NSRecursiveLock()
    nonisolated(unsafe) private static var claudeRotations = 0
    nonisolated(unsafe) private static var claudeSwitchInProgress = false
    nonisolated(unsafe) private static var codexGeneration: UInt64 = 0
    nonisolated(unsafe) private static var claudeGeneration: UInt64 = 0

    static func revision(for family: String) -> UInt64 {
        if family == "claude" { return claudeLock.withLock { claudeGeneration } }
        return codexLock.withLock { codexGeneration }
    }

    static func acquire(family: String = "codex") {
        switch family {
        case "claude":
            claudeLock.lock()
            claudeGeneration &+= 1
        case "codex":
            codexLock.lock()
            codexGeneration &+= 1
        default:
            break
        }
    }

    static func release(family: String = "codex") {
        switch family {
        case "claude": claudeLock.unlock()
        case "codex": codexLock.unlock()
        default: break
        }
    }

    /// 서버가 토큰을 소비할 수 있는 동안 전환을 보류. HTTP 대기 중에는 락을 잡지 않음.
    static func beginClaudeRotation(validating check: () throws -> Void) throws {
        try claudeLock.withLock {
            guard !claudeSwitchInProgress else { throw ClaudeAuthError.credentialsChanged }
            try check()
            claudeRotations += 1
        }
    }

    static func endClaudeRotation() {
        claudeLock.withLock { claudeRotations -= 1 }
    }

    /// 선택 확정까지 새 갱신을 보류. 비동기 최종 검증 중에도 소유한 락은 없음.
    static func beginClaudeSwitch() throws {
        try claudeLock.withLock {
            try requireIdleClaudeRotation()
            guard !claudeSwitchInProgress else { throw ClaudeAuthError.credentialsChanged }
            claudeSwitchInProgress = true
        }
    }

    static func endClaudeSwitch() {
        claudeLock.withLock { claudeSwitchInProgress = false }
    }

    static func requireIdleClaudeRotation() throws {
        try claudeLock.withLock {
            guard claudeRotations == 0 else { throw ClaudeAuthError.rotationInProgress }
        }
    }

    static func withUnchangedRevision(
        _ expected: UInt64, family: String = "codex", _ operation: () throws -> Void
    ) rethrows -> Bool {
        let lock = family == "claude" ? claudeLock : codexLock
        lock.lock()
        defer { lock.unlock() }
        guard revision(for: family) == expected else { return false }
        if family == "claude" {
            claudeGeneration &+= 1
        } else {
            codexGeneration &+= 1
        }
        try operation()
        return true
    }
}

public struct AccountCredentialSnapshotRemover: Sendable {
    private let keychain: any KeychainAccessing

    public init() {
        self.keychain = SecurityKeychainAccessor()
    }

    init(keychain: any KeychainAccessing) {
        self.keychain = keychain
    }

    public func remove(profile: AccountProfile) throws {
        try AccountCredentialVault(keychain: keychain).delete(profile: profile)
    }
}

enum AccountCredentialVaultError: Error, LocalizedError {
    case missingEntry

    var errorDescription: String? {
        "The saved sign-in is missing or invalid. Sign in again and retry."
    }
}
