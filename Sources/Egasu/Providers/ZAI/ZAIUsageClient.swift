import Foundation

struct ZAIUsageClient: Sendable {
    static let subscriptionURL = URL(string: "https://api.z.ai/api/biz/subscription/list")!
    static let quotaURL = URL(string: "https://api.z.ai/api/monitor/usage/quota/limit")!
    static let activityURL = URL(string: "https://api.z.ai/api/monitor/credit-usage/activity")!
    static let detailURL = URL(string: "https://api.z.ai/api/monitor/credit-usage/usage-detail")!

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    /// 요금제 이름용 활성 구독 조회. 실패해도 한도 지표 유지.
    func fetchSubscription(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.subscriptionURL, apiKey: apiKey)
    }

    /// 사용량 표시에 필요한 크레딧·토큰·웹 검색 한도 조회.
    func fetchQuota(apiKey: String) async throws -> HTTPResponse {
        try await get(Self.quotaURL, apiKey: apiKey)
    }

    func fetchActivity(apiKey: String, window: ZAIActivityWindow) async throws -> HTTPResponse {
        var components = URLComponents(url: Self.activityURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "startTime", value: window.startTime),
            URLQueryItem(name: "endTime", value: window.endTime)
        ]
        return try await get(components.url!, apiKey: apiKey)
    }

    func fetchDetails(apiKey: String, window: ZAIDetailWindow) async throws -> HTTPResponse {
        var components = URLComponents(url: Self.detailURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "usageType", value: "MODEL"),
            URLQueryItem(name: "startTime", value: window.startTime),
            URLQueryItem(name: "endTime", value: window.endTime)
        ]
        return try await get(components.url!, apiKey: apiKey)
    }

    private func get(_ url: URL, apiKey: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: [
                "Authorization": apiKey,
                "Accept": "application/json"
            ],
            timeout: 15
        ))
    }
}

enum ZAIUsageError: Error, LocalizedError, Equatable {
    case connectionFailed
    case invalidResponse
    case requestFailed(Int)
    /// 유효 키지만 GLM Coding Plan이 없는 상태. 2xx 응답의 `success:false`로 구분.
    /// 요청 실패·응답 손상과 별도로 처리.
    case noCodingPlan

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return ProviderUsageErrorText.connectionFailed
        case .invalidResponse:
            return ProviderUsageErrorText.invalidResponse
        case .requestFailed(let status):
            return ProviderUsageErrorText.requestFailed(statusCode: status)
        case .noCodingPlan:
            return "No active GLM Coding Plan. Subscribe at z.ai/subscribe to see usage."
        }
    }
}
