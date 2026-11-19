import Foundation

/// OAuth 조회에서 HTTP 401·403을 받으면 토큰을 갱신한 뒤 요청을 한 번만 재시도.
@MainActor
enum ProviderAuthRetry {
    /// HTTP 401·403을 인증 실패로 분류. 토큰 갱신과 오류 처리는 호출부에서 결정.
    nonisolated static func isAuthFailure(_ response: HTTPResponse) -> Bool {
        response.statusCode == 401 || response.statusCode == 403
    }

    /// 인증 거절과 기타 HTTP 오류를 호출부의 오류 타입으로 구분.
    nonisolated static func requireSuccess(
        _ response: HTTPResponse,
        authExpired: Error,
        requestFailed: (Int) -> Error
    ) throws {
        guard !isAuthFailure(response) else { throw authExpired }
        guard (200..<300).contains(response.statusCode) else { throw requestFailed(response.statusCode) }
    }

    /// 취소를 인증·통신 실패로 바꾸거나 실패 로그에 포함하지 않도록 원래 오류 전파.
    nonisolated static func rethrowCancellation(_ error: Error) throws {
        if error is CancellationError || (error as? URLError)?.code == .cancelled { throw error }
        try Task.checkCancellation()
    }

    /// 최초 조회와 재조회에서 발생한 통신 오류를 구분. 토큰 갱신과 저장은 호출부에서 처리.
    static func fetch(
        provider: StaticString,
        resource: StaticString = "usage",
        token: String,
        attempt: (_ accessToken: String) async throws -> HTTPResponse,
        refreshAccessToken: () async throws -> String,
        connectionFailed: Error,
        retriedConnectionFailed: Error? = nil,
        authExpired: Error
    ) async throws -> HTTPResponse {
        let tag = LogTag.auth(String(describing: provider))
        func request(_ token: String, retry: Bool) async throws -> HTTPResponse {
            try Task.checkCancellation()
            do {
                return try await attempt(token)
            } catch {
                try rethrowCancellation(error)
                let stage = retry ? "retry" : "initial"
                AppLog.warn(tag, "OAuth resource=\(resource) stage=\(stage) \(AppLog.errorDetails(error))")
                throw retry ? (retriedConnectionFailed ?? connectionFailed) : connectionFailed
            }
        }

        let response = try await request(token, retry: false)
        guard isAuthFailure(response) else { return response }

        try Task.checkCancellation()
        AppLog.info(tag, "OAuth resource=\(resource) stage=initial status=\(response.statusCode) action=refresh")
        let refreshed = try await refreshAccessToken()
        let retried = try await request(refreshed, retry: true)
        if isAuthFailure(retried) {
            AppLog.warn(tag, "OAuth resource=\(resource) stage=retry status=\(retried.statusCode) result=rejected")
            throw authExpired
        }
        return retried
    }
}
