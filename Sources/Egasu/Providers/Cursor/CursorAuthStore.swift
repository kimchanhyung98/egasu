import Foundation

struct CursorAuthState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case sqlite
        case keychain
    }

    var accessToken: String?
    var refreshToken: String?
    var source: Source

    fileprivate var hasCredentials: Bool { accessToken != nil || refreshToken != nil }
}

enum CursorAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case sessionExpired
    case tokenExpired
    case credentialsChanged

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Sign in via Cursor app or run `agent login`."
        case .sessionExpired:
            return "Session expired. Sign in via Cursor app or run `agent login`."
        case .tokenExpired:
            return "Token expired. Sign in via Cursor app or run `agent login`."
        case .credentialsChanged:
            return "Cursor sign-in changed while refreshing. Refresh again to use the current account."
        }
    }
}

struct CursorAuthStore: Sendable {
    static let stateDBPath = "~/Library/Application Support/Cursor/User/globalStorage/state.vscdb"
    static let accessTokenKey = "cursorAuth/accessToken"
    static let refreshTokenKey = "cursorAuth/refreshToken"
    static let membershipTypeKey = "cursorAuth/stripeMembershipType"
    static let keychainAccessTokenService = "cursor-access-token"
    static let keychainRefreshTokenService = "cursor-refresh-token"
    static let refreshBufferSeconds: TimeInterval = 5 * 60
    // SQLite 비교도 로더와 같은 Foundation 공백 집합으로 정규화.
    private static let sqliteTrimCharacters: String = {
        let whitespace = CharacterSet.whitespacesAndNewlines
        var scalars = String.UnicodeScalarView()
        for plane in UInt8(0)...16 where whitespace.hasMember(inPlane: plane) {
            let start = UInt32(plane) << 16
            for codePoint in start..<(start + 0x10000) {
                if let scalar = UnicodeScalar(codePoint), whitespace.contains(scalar) {
                    scalars.append(scalar)
                }
            }
        }
        return String(scalars)
    }()

    var sqlite: SQLiteAccessing
    var keychain: KeychainAccessing
    var now: @Sendable () -> Date

    init(
        sqlite: SQLiteAccessing = SQLiteCLIAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.sqlite = sqlite
        self.keychain = keychain
        self.now = now
    }

    func loadAuthState(allowKeychainInteraction: Bool = true) -> CursorAuthState? {
        do {
            let sqlite = CursorAuthState(
                accessToken: try readStateValue(Self.accessTokenKey, bestEffort: allowKeychainInteraction),
                refreshToken: try readStateValue(Self.refreshTokenKey, bestEffort: allowKeychainInteraction),
                source: .sqlite
            )
            let membership = try readStateValue(Self.membershipTypeKey, bestEffort: allowKeychainInteraction)?
                .lowercased()
            if !allowKeychainInteraction, sqlite.hasCredentials, membership != "free" { return sqlite }

            let keychain = CursorAuthState(
                accessToken: try readKeychainValue(
                    Self.keychainAccessTokenService, allowInteraction: allowKeychainInteraction),
                refreshToken: try readKeychainValue(
                    Self.keychainRefreshTokenService, allowInteraction: allowKeychainInteraction),
                source: .keychain
            )
            guard sqlite.hasCredentials else { return keychain.hasCredentials ? keychain : nil }
            if membership == "free",
                let sqliteSubject = Self.tokenSubject(sqlite.accessToken),
                let keychainSubject = Self.tokenSubject(keychain.accessToken),
                sqliteSubject != keychainSubject
            {
                return keychain
            }
            return sqlite
        } catch {
            // 비대화형 검증 중 읽기 오류를 인증 부재로 처리하면 다른 계정의 캐시를 표시할 수 있음.
            return nil
        }
    }

    func needsRefresh(_ accessToken: String?) -> Bool {
        guard let accessToken,
              let expiresAt = Self.tokenExpiration(accessToken)
        else {
            return true
        }
        return expiresAt.timeIntervalSince(now()) <= Self.refreshBufferSeconds
    }

    /// 현재 선택되는 출처·토큰 쌍 재검증. SQLite 저장 성공은 true, Keychain은 쓰지 않고 false 반환.
    @discardableResult
    func saveAccessToken(_ accessToken: String, replacing original: CursorAuthState) throws -> Bool {
        guard original.refreshToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil,
              loadAuthState() == original else {
            throw CursorAuthError.credentialsChanged
        }
        switch original.source {
        case .sqlite:
            let changed: Int
            do {
                changed = try sqlite.executeChanges(
                    path: Self.stateDBPath,
                    sql: """
                    INSERT INTO ItemTable (key, value)
                    SELECT ?, ?
                    WHERE NULLIF(TRIM((SELECT value FROM ItemTable WHERE key = ? LIMIT 1), ?), '') IS ?
                      AND NULLIF(TRIM((SELECT value FROM ItemTable WHERE key = ? LIMIT 1), ?), '') IS ?
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value;
                    """,
                    bindings: [Self.accessTokenKey, accessToken,
                               Self.accessTokenKey, Self.sqliteTrimCharacters, original.accessToken,
                               Self.refreshTokenKey, Self.sqliteTrimCharacters, original.refreshToken]
                )
            } catch {
                guard loadAuthState() == original else { throw CursorAuthError.credentialsChanged }
                throw error
            }
            guard changed == 1 else { throw CursorAuthError.credentialsChanged }
            return true
        case .keychain:
            // 외부 Cursor의 변경과 조건부 쓰기를 원자화할 수 없어 호출자가 갱신 토큰을 메모리에서만 사용.
            return false
        }
    }

    private func readStateValue(_ key: String, bestEffort: Bool) throws -> String? {
        if bestEffort { return try? stateValue(key) }
        return try stateValue(key)
    }

    private func stateValue(_ key: String) throws -> String? {
        let sql = "SELECT value FROM ItemTable WHERE key = '\(Self.sqlEscaped(key))' LIMIT 1;"
        guard let value = try sqlite.queryValue(path: Self.stateDBPath, sql: sql) else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func readKeychainValue(_ service: String, allowInteraction: Bool) throws -> String? {
        let value: String?
        if allowInteraction {
            value = try? keychain.readGenericPassword(service: service)
        } else {
            value = try keychain.readGenericPassword(service: service, allowInteraction: false)
        }
        return value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func tokenExpiration(_ token: String) -> Date? {
        guard let exp = ProviderParse.jwtPayload(token)?["exp"].flatMap(ProviderParse.number) else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func tokenSubject(_ token: String?) -> String? {
        guard let token,
              let subject = ProviderParse.jwtPayload(token)?["sub"] as? String
        else {
            return nil
        }
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func sqlEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: "'", with: "''")
    }
}
