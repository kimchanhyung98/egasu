import CryptoKit
import Foundation

/// Claude 전환의 선택 복구 기록 — 인증 원문 없이 계정 ID·신원·세대 해시만 보관.
struct AccountSwitchJournal: Sendable {
    struct Record: Codable, Equatable, Sendable {
        var id = UUID()
        var previousProfileID: String
        var previousIdentity: String
        var previousCredentialFingerprint: String?
        var previousStateFingerprint: String?
        var priorSelectionIDs: [String] = []
        var selectedProfileID: String
        var selectedIdentity: String
        var selectedCredentialFingerprint: String
        var sourceID: String?
        var retryStateFingerprints: [String]? = nil
    }

    struct SharedState: Codable, Equatable, Sendable {
        var credentials: [String?]
        var accounts: [String?]
        var identities: [String?]
        var sourceID: String?

        func fingerprint() throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return AccountSwitchJournal.fingerprint(try encoder.encode(self))
        }

        /// 공유 계정 정보가 먼저 쓰이는 두 중단 지점의 지문.
        func retryStateFingerprints(staging account: String, identity: String) throws -> [String] {
            let staged = Self(
                credentials: credentials, accounts: [try Self.canonicalAccount(account)],
                identities: [credentials[0] == nil ? nil : identity], sourceID: sourceID)
            return try [fingerprint(), staged.fingerprint()]
        }

        func matchesAccountMetadata(_ account: String) throws -> Bool {
            try accounts == [Self.canonicalAccount(account)]
        }

        private static func canonicalAccount(_ account: String) throws -> String {
            let parsed = try JSONSerialization.jsonObject(with: Data(account.utf8))
            let canonical = try JSONSerialization.data(withJSONObject: parsed, options: [.sortedKeys])
            return String(decoding: canonical, as: UTF8.self)
        }

        func containsLegacyLogin(_ state: Self) -> Bool {
            guard let credential = state.credentials[0], accounts.contains(state.accounts[0]) else { return false }
            return credentials.compactMap { $0 }.contains {
                (try? ClaudeAccountLoginCredentials.loginOnly($0)) == credential
            }
        }

        func matchesStagedAccount(of record: Record, with previousCredential: String) throws -> Bool {
            let staged = Self(
                credentials: [previousCredential], accounts: accounts, identities: identities, sourceID: sourceID)
            return try staged.fingerprint() == record.retryStateFingerprints?.last
        }

        func matches(credentialFingerprint: String, identity: String, requiresAllSources: Bool) -> Bool {
            if requiresAllSources,
               (credentials.contains(where: { $0 == nil }) || identities.contains(where: { $0 == nil })) {
                return false
            }
            let presentCredentials = credentials.compactMap { $0 }
            let presentIdentities = identities.compactMap { $0 }
            return !presentCredentials.isEmpty && !presentIdentities.isEmpty
                && presentCredentials.allSatisfy { AccountSwitchJournal.fingerprint($0) == credentialFingerprint }
                && presentIdentities.allSatisfy { $0 == identity }
                && zip(accounts, identities).allSatisfy { $0 == nil || $1 != nil }
        }

        /// 명시적 재시도는 이전·대상 인증이 섞인 부분 쓰기만 허용. 외부 로그인과 새 토큰 세대 보존.
        func permitsRetry(of record: Record) -> Bool {
            guard sourceID == record.sourceID else { return false }
            if let knownStates = record.retryStateFingerprints,
                let observed = try? fingerprint(), knownStates.contains(observed)
            {
                return true
            }
            let knownCredentials = [record.previousCredentialFingerprint, record.selectedCredentialFingerprint]
                .compactMap { $0 }
            let presentCredentials = credentials.compactMap { $0 }
            return !presentCredentials.isEmpty
                && presentCredentials.allSatisfy { knownCredentials.contains(AccountSwitchJournal.fingerprint($0)) }
                && identities.compactMap { $0 }.allSatisfy {
                    $0 == record.previousIdentity || $0 == record.selectedIdentity
                }
                && zip(accounts, identities).allSatisfy { $0 == nil || $1 != nil }
        }
    }

    let path: String
    private let files: any TextFileAccessing

    init(path: String, files: any TextFileAccessing = LocalTextFileAccessor()) {
        self.path = path
        self.files = files
    }

    func load() throws -> Record? {
        guard let text = try files.readTextIfPresent(path) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: Data(text.utf8)),
            !record.previousProfileID.isEmpty, !record.previousIdentity.isEmpty,
            !record.selectedProfileID.isEmpty, !record.selectedIdentity.isEmpty,
            record.sourceID?.isEmpty != true,
            record.priorSelectionIDs.allSatisfy({ !$0.isEmpty }),
            Self.isFingerprint(record.selectedCredentialFingerprint),
            record.previousCredentialFingerprint.map(Self.isFingerprint) ?? true,
            record.previousStateFingerprint.map(Self.isFingerprint) ?? true,
            record.retryStateFingerprints.map({
                record.sourceID != nil && $0.count == 2 && $0.allSatisfy(Self.isFingerprint)
            }) ?? true
        else {
            AppLog.error(.auth, "account switch journal is unreadable; preserving it and blocking reconciliation")
            throw AccountIdentityReplacementError.invalidTransaction
        }
        return record
    }

    func save(_ record: Record, replacing previous: Record?) throws {
        guard try load() == previous else { throw AccountIdentityReplacementError.pendingTransaction }
        let data = try JSONEncoder().encode(record)
        try files.writeText(path, String(decoding: data, as: UTF8.self))
        guard try load() == record else { throw AccountIdentityReplacementError.invalidTransaction }
    }

    func clear(_ record: Record) throws {
        guard try load() == record else { throw AccountIdentityReplacementError.pendingTransaction }
        try files.remove(path)
        guard try load() == nil else { throw AccountIdentityReplacementError.invalidTransaction }
    }

    static func fingerprint(_ text: String) -> String {
        fingerprint(Data(text.utf8))
    }

    private static func fingerprint(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func isFingerprint(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }
}
