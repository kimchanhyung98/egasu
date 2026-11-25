import Foundation

struct DeepSeekUsageClient: Sendable {
    static let url = URL(string: "https://api.deepseek.com/user/balance")!
    var http: any HTTPClient = URLSessionHTTPClient(sendsCookies: false)

    func balance(apiKey: String) async throws -> DeepSeekBalance {
        let response: HTTPResponse
        do {
            response = try await http.send(
                HTTPRequest(
                    method: "GET", url: Self.url,
                    headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"]
                ))
        } catch is CancellationError { throw CancellationError() } catch let error as URLError
            where error.code == .cancelled
        { throw error } catch { throw DeepSeekError.connection }

        switch response.statusCode {
        case 200:
            do {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                return try decoder.decode(DeepSeekBalance.self, from: response.body)
            } catch { throw DeepSeekError.invalidResponse }
        case 401, 403: throw DeepSeekError.invalidKey
        default: throw DeepSeekError.http(response.statusCode)
        }
    }
}

enum DeepSeekError: LocalizedError, UserPresentableError, CategorizedError {
    case keyStorage(UserAPIKeyStore.Failure)
    case invalidKey, connection, invalidResponse, credentialsChanged
    case http(Int)

    var presentationMessage: LocalizedMessage {
        switch self {
        case .keyStorage(.missingKey): .init("Add a DeepSeek API key in Accounts or set DEEPSEEK_API_KEY.")
        case .keyStorage(.saveFailed): .init("Couldn't save the DeepSeek API key.")
        case .keyStorage(.deleteFailed): .init("Couldn't remove the saved DeepSeek API key.")
        case .credentialsChanged: .init("The DeepSeek API key changed. Refresh again to use the current key.")
        case .invalidKey: .init("DeepSeek rejected the API key. Check your key in Accounts.")
        case .connection: .init("Couldn't reach DeepSeek. Check your connection.")
        case .invalidResponse: .init("DeepSeek returned invalid balance data.")
        case .http(let status): .init("DeepSeek request failed (HTTP %@).", [String(status)])
        }
    }

    var errorDescription: String? {
        let message = presentationMessage
        return String(format: message.key, arguments: message.arguments)
    }

    var errorCategory: ErrorCategory {
        switch self {
        case .keyStorage(.missingKey): .notLoggedIn
        case .keyStorage: .storage
        case .invalidKey, .credentialsChanged: .authInvalid
        case .connection: .network
        case .invalidResponse: .decoding
        case .http(let status): .http(status)
        }
    }
}
