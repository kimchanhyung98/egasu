import Foundation

struct ClaudeRefreshResponse: Decodable, Hashable, Sendable {
    var accessToken: String
    var refreshToken: String?
    var expiresIn: Double?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case scope
    }
}

struct ClaudeProfileResponse: Decodable, Sendable {
    struct Identity: Decodable, Sendable {
        let uuid: String
    }

    let account: Identity
    let organization: Identity

    func accountIdentityKey() throws -> String {
        let accountID = account.uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let organizationID = organization.uuid.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !accountID.isEmpty, !organizationID.isEmpty,
              !accountID.contains("|"), !organizationID.contains("|") else {
            throw ClaudeUsageError.invalidResponse
        }
        return "\(accountID)|\(organizationID)"
    }
}

enum ClaudeUsageError: Error, LocalizedError, Equatable, Codable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let statusCode):
            return ProviderUsageErrorText.requestFailed(statusCode: statusCode)
        }
    }
}

struct ClaudeUsageClient: Sendable {
    static let profileTimeout: TimeInterval = 10

    var httpClient: HTTPClient

    init(httpClient: HTTPClient = URLSessionHTTPClient()) {
        self.httpClient = httpClient
    }

    func refreshToken(
        _ refreshToken: String, scopes: [String]? = nil, config: ClaudeOAuthConfig
    ) async throws -> HTTPResponse {
        var body: [String: Any] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": config.clientID
        ]
        // 저장된 권한만 요청. 범위가 없는 기존 로그인은 최초 승인 범위를 서버에서 유지.
        if let scopes, !scopes.isEmpty { body["scope"] = scopes.joined(separator: " ") }
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await httpClient.send(
            HTTPRequest(
                method: "POST",
                url: config.refreshURL,
                headers: ["Content-Type": "application/json"],
                body: bodyData,
                timeout: 15,
                logEndpoint: "claude.oauth_refresh"
            )
        )
    }

    func fetchUsage(accessToken: String, config: ClaudeOAuthConfig) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: config.usageURL,
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Accept": "application/json",
                    "Content-Type": "application/json",
                    "anthropic-beta": "oauth-2025-04-20",
                    "User-Agent": "claude-code/2.1.69"
                ],
                timeout: 10,
                logEndpoint: "claude.usage"
            )
        )
    }

    func fetchProfile(
        accessToken: String, config: ClaudeOAuthConfig, timeout: TimeInterval = Self.profileTimeout
    ) async throws -> HTTPResponse {
        try await httpClient.send(
            HTTPRequest(
                method: "GET",
                url: config.usageURL.deletingLastPathComponent().appendingPathComponent("profile"),
                headers: [
                    "Authorization": "Bearer \(accessToken.trimmingCharacters(in: .whitespacesAndNewlines))",
                    "Content-Type": "application/json",
                    "Cache-Control": "no-cache",
                    "User-Agent": "claude-code/2.1.69"
                ],
                timeout: timeout,
                logEndpoint: "claude.profile"
            )
        )
    }
}

