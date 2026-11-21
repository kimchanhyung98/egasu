import XCTest
@testable import Egasu

final class ClaudeReconciliationHTTPClient: HTTPClient, @unchecked Sendable {
    var identities: [String: String] = [:]
    var response: HTTPResponse?
    var beforeResponse: (() throws -> Void)?
    private(set) var requests: [HTTPRequest] = []

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        try beforeResponse?()
        if let response { return response }
        let token = String((request.headers["Authorization"] ?? "").dropFirst("Bearer ".count))
        guard let identity = identities[token] else {
            XCTFail("Unexpected profile token in test fixture")
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        let components = identity.split(separator: "|")
        return HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(#"{"account":{"uuid":"\#(components[0])"},"organization":{"uuid":"\#(components[1])"}}"#.utf8)
        )
    }
}

@MainActor
func claudeReconciliationResult(
    _ importer: AccountCredentialImporter, in store: AccountProfilesStore
) async -> Result<AccountCredentialImporter.ExternalReauthenticationResult, any Error> {
    do {
        return .success(try await importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(in: store))
    } catch {
        return .failure(error)
    }
}
