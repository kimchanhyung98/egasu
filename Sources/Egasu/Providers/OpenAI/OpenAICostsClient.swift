import Foundation

struct OpenAICostsClient: Sendable {
    var http: any HTTPClient = URLSessionHTTPClient(sendsCookies: false)

    private struct Page: Decodable {
        struct Bucket: Decodable {
            struct Result: Decodable {
                struct Amount: Decodable {
                    let currency: String
                    let value: Decimal
                }
                let amount: Amount
            }
            let results: [Result]
        }
        let data: [Bucket]
        let hasMore: Bool
        let nextPage: String?
    }

    func totals(
        key: String, projects: [String], start: Int, end: Int,
        isCurrentConnection: @MainActor @Sendable () async -> Bool
    ) async throws -> [String: Decimal] {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "api.openai.com"
        components.path = "/v1/organization/costs"
        let filters =
            [
                URLQueryItem(name: "start_time", value: String(start)),
                URLQueryItem(name: "end_time", value: String(end)),
                URLQueryItem(name: "bucket_width", value: "1d"),
                URLQueryItem(name: "limit", value: "30")
            ] + projects.map { URLQueryItem(name: "project_ids[]", value: $0) }

        var totals: [String: Decimal] = [:]
        var cursor: String?
        var seen = Set<String>()
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        repeat {
            try Task.checkCancellation()
            components.queryItems = filters + (cursor.map { [URLQueryItem(name: "page", value: $0)] } ?? [])
            // URL 쿼리에서 +를 공백으로 해석하는 서버에도 페이지 커서를 그대로 전달.
            components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
            guard let url = components.url else { throw OpenAICostsError.invalidResponse }
            guard await isCurrentConnection() else { throw OpenAICostsError.connectionChanged }
            let response: HTTPResponse
            do {
                response = try await http.send(
                    HTTPRequest(
                        method: "GET", url: url,
                        headers: ["Authorization": "Bearer \(key)", "Accept": "application/json"],
                        logEndpoint: "OpenAI organization costs"))
            } catch {
                try Task.checkCancellation()
                throw OpenAICostsError.connectionFailed
            }
            guard (200..<300).contains(response.statusCode) else { throw OpenAICostsError.http(response.statusCode) }
            guard let page = try? decoder.decode(Page.self, from: response.body) else {
                throw OpenAICostsError.invalidResponse
            }
            for bucket in page.data {
                for result in bucket.results {
                    let amount = result.amount
                    let code = amount.currency.uppercased()
                    guard code.utf8.count == 3, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
                        throw OpenAICostsError.invalidResponse
                    }
                    var previous = totals[code, default: 0]
                    var value = amount.value
                    var total = Decimal()
                    guard NSDecimalAdd(&total, &previous, &value, .plain) == .noError else {
                        throw OpenAICostsError.invalidResponse
                    }
                    totals[code] = total
                }
            }
            guard page.hasMore else { return totals }
            guard let next = page.nextPage, !next.isEmpty, seen.insert(next).inserted else {
                throw OpenAICostsError.invalidResponse
            }
            cursor = next
        } while true
    }
}

enum OpenAICostsError: LocalizedError, UserPresentableError, CategorizedError {
    case missingKey, invalidResponse, connectionFailed, connectionChanged, invalidProjects
    case http(Int)

    var errorCategory: ErrorCategory {
        switch self {
        case .invalidProjects, .connectionChanged: .other
        case .missingKey: .notLoggedIn
        case .invalidResponse: .decoding
        case .connectionFailed: .network
        case .http(401): .authInvalid
        case .http(403): .permission
        case .http(let status): .http(status)
        }
    }

    var presentationMessage: LocalizedMessage {
        switch self {
        case .invalidProjects: .init("Enter project IDs or leave the field empty for the whole organization.")
        case .missingKey: .init("Add an OpenAI organization Admin API key in Accounts.")
        case .http(401): .init("OpenAI rejected the Admin API key. Replace it in Accounts.")
        case .http(403): .init("The OpenAI Admin API key needs permission to read organization costs.")
        case .http(let status): .init("Usage request failed (HTTP %@). Try again later.", [String(status)])
        case .connectionFailed: .init("Usage request failed. Check your connection.")
        case .connectionChanged: .init("The OpenAI billing connection changed during refresh. Refresh again.")
        case .invalidResponse: .init("Usage response invalid. Try again later.")
        }
    }

    var errorDescription: String? {
        String(format: presentationMessage.key, arguments: presentationMessage.arguments)
    }
}
