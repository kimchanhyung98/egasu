import Foundation

struct HTTPRequest: Sendable {
    var method: String
    var url: URL
    var headers: [String: String] = [:]
    var body: Data?
    var timeout: TimeInterval = 15
    /// 사용자 설정이나 계정 ID로 만든 URL은 고정 작업명으로 기록.
    var logEndpoint: StaticString?

    var logTarget: String {
        logEndpoint.map(String.init(describing:)) ?? LogRedaction.redactURL(url.absoluteString)
    }
}

struct HTTPResponse: Sendable {
    var statusCode: Int
    var headers: [String: String]
    var body: Data

    func header(_ name: String) -> String? {
        headers[name.lowercased()]
    }
}

enum HTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
        return formatter.date(from: value)
    }
}

protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// HTTP 진단에는 메서드·작업명 또는 마스킹한 URL과 응답 상태만 기록.
struct URLSessionHTTPClient: HTTPClient {
    /// true면 `127.0.0.1` 한정 self-signed TLS cert를 수용하는 loopback 세션 사용 (`LoopbackTLSDelegate`).
    /// 로컬 language server의 self-signed HTTPS 전용 — 기본 off, 원격 호출은 전체 certificate 검증 유지.
    var allowsInsecureLoopback: Bool = false
    /// false면 cookie·공유 credential·URL cache·redirect 없는 ephemeral session 사용 — 고정 공개 endpoint 전용.
    var sendsCookies: Bool = true

    /// 모든 provider 요청 공용 세션 — 선택적 `~/.openusage/config.json` proxy 적용해 1회 생성 (`ProxyConfig`).
    /// 유효한 proxy 미설정 시 `URLSession.shared`와 동일한 cookie/cache 의미의 기본 configuration.
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        if let proxy = ProxyConfig.current {
            configuration.proxyConfigurations = [proxy.proxyConfiguration()]
            AppLog.info(.config, "proxy enabled scheme=\(proxy.scheme.rawValue) port=\(proxy.port)")
        }
        return URLSession(configuration: configuration)
    }()

    /// loopback 전용 세션 — ephemeral(공유 cookie/cache 없음), proxy 없음, `127.0.0.1` 한정 self-signed cert 신뢰 delegate. 1회 생성.
    private static let loopbackSession: URLSession = {
        URLSession(configuration: .ephemeral, delegate: LoopbackTLSDelegate(), delegateQueue: nil)
    }()

    /// 고정 공개 endpoint 전용 — 공유 인증정보 전송·URL cache·외부 응답 기반 redirect 차단.
    private static let cookieFreeSession = makeCookieFreeSession()

    static func makeCookieFreeSession(
        configuration: URLSessionConfiguration = .ephemeral
    ) -> URLSession {
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy = ProxyConfig.current {
            configuration.proxyConfigurations = [proxy.proxyConfiguration()]
        }
        return URLSession(
            configuration: configuration,
            delegate: NoRedirectURLSessionDelegate(),
            delegateQueue: nil
        )
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        let session = allowsInsecureLoopback
            ? Self.loopbackSession
            : (sendsCookies ? Self.session : Self.cookieFreeSession)
        return try await send(request, using: session)
    }

    func send(_ request: HTTPRequest, using session: URLSession) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url, timeoutInterval: request.timeout)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: urlRequest) }
        catch {
            if (error as? URLError)?.code != .cancelled {
                AppLog.debug(
                    .http, "\(request.method) \(request.logTarget) transport failed \(AppLog.errorDetails(error))")
            }
            throw error
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPClientError.invalidResponse
        }

        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            headers[String(describing: key).lowercased()] = String(describing: value)
        }

        AppLog.debug(
            .http, "\(request.method) \(request.logTarget) -> \(http.statusCode)")
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

enum HTTPClientError: Error, LocalizedError {
    case invalidResponse

    var errorDescription: String? {
        "Invalid HTTP response."
    }
}

/// 고정 공개 endpoint redirect 거부 — 외부 응답이 loopback·사설망 요청으로 전환되는 경로 차단.
final class NoRedirectURLSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// self-signed 서버 cert를 loopback(`127.0.0.1`)에만 수용 — 그 외 host·non-server-trust challenge는 기본 검증으로 통과, 원격 endpoint 신뢰 약화 없음.
/// mutable 상태 없음 — loopback 세션 간 공유 안전.
private final class LoopbackTLSDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "127.0.0.1",
              let trust = challenge.protectionSpace.serverTrust
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
