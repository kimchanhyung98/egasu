import Foundation

/// GitHub REST API로 조직 목록과 조직별 월 누적 Copilot 사용량 조회.
/// 개인 할당량이 없는 조직 계정의 보조 조회. 청구 권한 부족의 403은 카드 전체 실패로 처리하지 않음.
struct CopilotOrgBillingClient: Sendable {
    static let userOrgsURL = "https://api.github.com/user/orgs?per_page=100"

    static func usageSummaryURL(org: String) -> URL? {
        // 조직 식별자를 URL 경로에 넣기 전에 인코딩.
        guard let encoded = org.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            return nil
        }
        return URL(string: "https://api.github.com/orgs/\(encoded)/settings/billing/usage/summary")
    }

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// 현재 사용자가 속한 조직의 첫 페이지 조회. 최대 100개.
    func fetchUserOrgs(token: String) async throws -> HTTPResponse {
        guard let url = URL(string: Self.userOrgsURL) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    /// 조직 하나의 월 누적 청구 사용량 요약 조회.
    func fetchUsageSummary(org: String, token: String) async throws -> HTTPResponse {
        guard let url = Self.usageSummaryURL(org: org) else {
            throw CopilotUsageError.invalidResponse
        }
        return try await send(url: url, token: token)
    }

    private func send(url: URL, token: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": "token \(token)",
                "Accept": "application/vnd.github+json",
                "User-Agent": "egasu",
                "X-GitHub-Api-Version": "2022-11-28"
            ],
            timeout: 15
        ))
    }
}
