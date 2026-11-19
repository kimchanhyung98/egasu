import Foundation

struct ClaudeOAuth: Codable, Hashable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Double?
    var subscriptionType: String?
    var rateLimitTier: String?
    var scopes: [String]?
}

struct ClaudeCredentialsFile: Codable, Hashable, Sendable {
    var claudeAiOauth: ClaudeOAuth?
}

struct ClaudeCredentialState: Hashable, Sendable {
    enum Source: Hashable, Sendable {
        case file
        case keychainCurrentUser(service: String)
        case keychainLegacy(service: String)
        case accountSnapshot(profileID: String)
        case desktop
        case environment

        /// 로그 안전 source 종류 — keychain service 이름·토큰 노출 금지.
        var label: String {
            switch self {
            case .file: "file"
            case .keychainCurrentUser: "keychainCurrentUser"
            case .keychainLegacy: "keychainLegacy"
            case .accountSnapshot: "accountSnapshot"
            case .desktop: "desktop"
            case .environment: "environment"
            }
        }
    }

    var oauth: ClaudeOAuth
    var source: Source
    var sourceText: String?
    var inferenceOnly: Bool
    var accountIdentityKey: String? = nil
    var sharedLoginRoute: ClaudeSharedLoginRoute?

    /// 공백 아닌 access token 보유 여부 — `refresh()` 필터와 `hasLocalCredentials()`가 공유하는 단일 "usable" 정의.
    var hasUsableAccessToken: Bool {
        oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 기본(info) 로그용 진단 라벨 — source 종류 + refresh token 유무 + 만료 여부만 포함.
    /// 토큰 값·credential blob 노출 금지; `refresh=no`는 만료 자가 복구 불가의 근거(#738).
    func diagnosticsLabel(now: Date) -> String {
        let refresh = (oauth.refreshToken?.isEmpty == false) ? "yes" : "no"
        let expired: String
        if let expiresAt = oauth.expiresAt {
            expired = expiresAt <= now.timeIntervalSince1970 * 1000 ? "yes" : "no"
        } else {
            expired = "unknown"
        }
        return "\(source.label) refresh=\(refresh) expired=\(expired)"
    }
}

/// 유효 probe 순서의 토큰 보유 credential 후보 집합 — inference 전용 environment 토큰은 제외,
/// 선택에 영향 가능한 저장 후보는 전부 유지.
struct ClaudeCredentialGeneration: Equatable, Sendable {
    struct Candidate: Equatable, Sendable {
        let oauth: ClaudeOAuth
        let source: ClaudeCredentialState.Source
        let accountIdentityKey: String?
        let sharedLoginRoute: ClaudeSharedLoginRoute?

        init(_ state: ClaudeCredentialState) {
            oauth = state.oauth
            source = state.source
            accountIdentityKey = state.accountIdentityKey
            sharedLoginRoute = state.sharedLoginRoute
        }
    }

    var candidates: [Candidate]

    init(_ states: [ClaudeCredentialState]) {
        candidates =
            states
            .filter { $0.hasUsableAccessToken && !$0.inferenceOnly }
            .map(Candidate.init)
    }

    func replacing(_ state: ClaudeCredentialState) -> Self {
        var updated = self
        guard let index = updated.candidates.firstIndex(where: { $0.source == state.source }) else {
            fatalError("live usage source missing from Claude credential generation")
        }
        updated.candidates[index] = Candidate(state)
        return updated
    }
}

struct ClaudeCredentialLoad: Sendable {
    var candidates: [ClaudeCredentialState]
    var desktopStatus: ClaudeDesktopCredentialStatus
    var credentialError: Error? = nil
}

enum ClaudeAuthError: Error, LocalizedError, Equatable {
    case notLoggedIn
    case desktopPermissionRequired
    case desktopTokenExpired
    case desktopCredentialsUnavailable
    case sessionExpired
    case tokenExpired
    case credentialsChanged
    case rotationInProgress
    case invalidOAuthURL(String)

    var errorDescription: String? {
        switch self {
        case .notLoggedIn:
            return "Not logged in. Run `claude` to authenticate."
        case .desktopPermissionRequired:
            return "Claude Desktop login found. Refresh once and choose Always Allow to connect it."
        case .desktopTokenExpired:
            return "Claude Desktop login is stale. Open Claude Desktop, then refresh egasu."
        case .desktopCredentialsUnavailable:
            return "Claude Desktop login couldn't be read. Open Claude Desktop, then try again."
        case .sessionExpired:
            return
                "Claude could not renew this login. For a saved account, open Accounts and choose Sign In Again. Otherwise, run `claude auth login`."
        case .tokenExpired:
            return "Token expired. Run `claude` to log in again."
        case .credentialsChanged:
            return "Claude login changed during refresh. Refresh again."
        case .rotationInProgress:
            return "Claude is renewing a login. Try again when the refresh finishes."
        case .invalidOAuthURL(let value):
            return
                "Invalid Claude OAuth URL: \(value). Check CLAUDE_CODE_CUSTOM_OAUTH_URL / CLAUDE_LOCAL_OAUTH_API_BASE."
        }
    }

    /// source 하나의 실패가 다음 source로 폴백 가능한지 여부 — 토큰 만료/폐기 계열만 허용.
    /// 외부 `claude` 재로그인이 다른 source에 남긴 새 토큰을 stale 토큰이 가리면 안 됨.
    var allowsAuthFallback: Bool {
        switch self {
        case .sessionExpired, .tokenExpired, .desktopTokenExpired:
            return true
        case .notLoggedIn, .desktopPermissionRequired, .desktopCredentialsUnavailable,
            .credentialsChanged, .rotationInProgress, .invalidOAuthURL:
            return false
        }
    }
}

struct ClaudeOAuthConfig: Hashable, Sendable {
    var usageURL: URL
    var refreshURL: URL
    var clientID: String
}

/// `ClaudeAuthStore`가 볼 수 있는 로그인 범위. `.standard`는 기본 카드(기존 동작 그대로);
/// 나머지는 cross-account·environment 토큰·Desktop 폴백 없이 생성된 로그인 하나만 조회.
enum ClaudeCredentialScope: Hashable, Sendable {
    case standard
    /// 추가 `CLAUDE_CONFIG_DIR` home 하나. `keychainLiteral`은 keychain 항목 이름을 만드는
    /// 해시 원문 — Claude Code는 env 값을 입력된 표기 그대로 해시(`~/…` vs 절대 경로 상이).
    case configDir(path: String, keychainLiteral: String)
    /// 저장된 계정 전환 credential — 토큰 rotation은 공유 Claude home이 아닌 전용 snapshot에 기록.
    case accountSnapshot(profileID: String)
}
