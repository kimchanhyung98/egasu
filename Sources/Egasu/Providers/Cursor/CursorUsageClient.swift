import Foundation

struct CursorSession: Equatable, Sendable {
    var userID: String
    var sessionToken: String
}

struct CursorUsageClient: Sendable {
    static let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!
    static let planURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetPlanInfo")!
    static let refreshURL = URL(string: "https://api2.cursor.sh/oauth/token")!
    static let creditsURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCreditGrantsBalance")!
    static let unifiedBalanceURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetComplatCreditBalance")!
    static let usageStatusURL = URL(string: "https://cursor.com/api/dashboard/v2/usage-status?scope=user")!
    static let restUsageURL = URL(string: "https://cursor.com/api/usage")!
    static let usageSummaryURL = URL(string: "https://cursor.com/api/usage-summary")!
    static let stripeURL = URL(string: "https://cursor.com/api/auth/stripe")!
    static let usageEventsURL = URL(string: "https://cursor.com/api/dashboard/get-filtered-usage-events")!
    static let clientID = "KbZUR41cY7W6zRSdpSUJ7I7mLYBKOCmB"

    var http: any HTTPClient

    init(http: any HTTPClient = URLSessionHTTPClient()) {
        self.http = http
    }

    func refreshToken(_ refreshToken: String) async throws -> HTTPResponse {
        let body: [String: Any] = [
            "grant_type": "refresh_token",
            "client_id": Self.clientID,
            "refresh_token": refreshToken
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.refreshURL,
            headers: ["Content-Type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }

    func fetchUsage(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.usageURL, accessToken: accessToken)
    }

    func fetchPlan(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.planURL, accessToken: accessToken)
    }

    func fetchCredits(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.creditsURL, accessToken: accessToken)
    }

    func fetchUnifiedBalance(accessToken: String) async throws -> HTTPResponse {
        try await connectPost(Self.unifiedBalanceURL, accessToken: accessToken)
    }

    func fetchUsageStatus(accessToken: String) async throws -> HTTPResponse? {
        try await sessionGet(Self.usageStatusURL, accessToken: accessToken)
    }

    func fetchRequestBasedUsage(accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        var components = URLComponents(url: Self.restUsageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "user", value: session.userID)]
        guard let url = components?.url else { return nil }

        return try await http.send(HTTPRequest(
            method: "GET",
            url: url,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    func fetchUsageSummary(accessToken: String) async throws -> HTTPResponse? {
        try await sessionGet(Self.usageSummaryURL, accessToken: accessToken)
    }

    func fetchStripeBalance(accessToken: String) async throws -> HTTPResponse? {
        try await sessionGet(Self.stripeURL, accessToken: accessToken)
    }

    private func sessionGet(_ url: URL, accessToken: String) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        return try await http.send(HTTPRequest(
            method: "GET", url: url,
            headers: ["Cookie": "WorkosCursorSessionToken=\(session.sessionToken)"],
            timeout: 10
        ))
    }

    func fetchUsageEventsPage(
        accessToken: String, start: Date, end: Date, page: Int, pageSize: Int = 1_000
    ) async throws -> HTTPResponse? {
        guard let session = Self.session(from: accessToken) else { return nil }
        let body: [String: Any] = [
            "startDate": String(Int(start.timeIntervalSince1970 * 1000)),
            "endDate": String(Int(end.timeIntervalSince1970 * 1000)),
            "page": page,
            "pageSize": pageSize
        ]
        return try await http.send(HTTPRequest(
            method: "POST",
            url: Self.usageEventsURL,
            headers: [
                "Cookie": "WorkosCursorSessionToken=\(session.sessionToken)",
                "Content-Type": "application/json",
                "Origin": "https://cursor.com"
            ],
            body: try JSONSerialization.data(withJSONObject: body),
            timeout: 15
        ))
    }

    /// 총건수·기간·전체 합계를 검증한 뒤 반환. 일부 페이지만 받은 결과는 정상 이력으로 사용하지 않음.
    func fetchUsageEvents(accessToken: String, start: Date, end: Date) async throws -> [CursorUsageEvent] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        var events: [CursorUsageEvent] = []
        var expectedCount: Int?
        var seenPages: Set<Data> = []
        var totalTokens = 0
        var totalCost = 0.0
        var page = 1
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw CursorUsageError.connectionFailed }
            guard
                let response = try await fetchUsageEventsPage(
                    accessToken: accessToken, start: start, end: end, page: page)
            else {
                throw CursorAuthError.notLoggedIn
            }
            guard (200..<300).contains(response.statusCode) else {
                throw CursorHistoryError.http(response.statusCode, retryAfter: response.header("retry-after"))
            }
            let parsed = try CursorUsageEvents.parsePage(response.body)
            if let expectedCount, expectedCount != parsed.totalCount { throw CursorUsageError.invalidResponse }
            expectedCount = parsed.totalCount
            guard parsed.events.count <= 1_000,
                parsed.events.count <= parsed.totalCount - events.count,
                !parsed.events.isEmpty || parsed.totalCount == events.count
            else { throw CursorUsageError.invalidResponse }
            if let fingerprint = parsed.pageFingerprint, !seenPages.insert(fingerprint).inserted {
                throw CursorUsageError.invalidResponse
            }
            for event in parsed.events {
                guard event.date >= start, event.date <= end else { throw CursorUsageError.invalidResponse }
                let sum = totalTokens.addingReportingOverflow(event.tokens.totalTokens)
                totalCost += event.costUSD
                guard !sum.overflow, totalCost.isFinite, (totalCost * 100).isFinite else {
                    throw CursorUsageError.invalidResponse
                }
                totalTokens = sum.partialValue
            }
            events.append(contentsOf: parsed.events)
            if events.count == parsed.totalCount { return events }
            page += 1
        }
    }

    private func connectPost(_ url: URL, accessToken: String) async throws -> HTTPResponse {
        try await http.send(HTTPRequest(
            method: "POST",
            url: url,
            headers: [
                "Authorization": "Bearer \(accessToken)",
                "Content-Type": "application/json",
                "Connect-Protocol-Version": "1"
            ],
            body: Data("{}".utf8),
            timeout: 10
        ))
    }

    static func session(from accessToken: String) -> CursorSession? {
        guard let subject = CursorAuthStore.tokenSubject(accessToken) else { return nil }
        let parts = subject.split(separator: "|", omittingEmptySubsequences: false)
        let userID = String(parts.count > 1 ? parts[1] : parts[0])
        guard !userID.isEmpty else { return nil }
        return CursorSession(userID: userID, sessionToken: "\(userID)%3A%3A\(accessToken)")
    }
}
