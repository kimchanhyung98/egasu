import Foundation
import XCTest
@testable import Egasu

@MainActor
final class KimiRotationShutdownTests: XCTestCase {
    func testQuitWaitsForKimiRotationAfterUsageRefreshIsCancelled() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        defer { TokenRotationShutdownGuard.cancelTermination() }
        let requestStarted = expectation(description: "Kimi received the refresh request")
        let (responses, response) = AsyncStream<Void>.makeStream()
        let http = RoutingAsyncHTTPClient { request in
            if request.method == "POST" {
                requestStarted.fulfill()
                for await _ in responses { break }
                try Task.checkCancellation()
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"usages":{}}"#.utf8))
        }
        let provider = makeProvider(home: home, http: http)
        let refresh = Task { await provider.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)

        TokenRotationShutdownGuard.beginTermination()
        XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
        refresh.cancel()
        response.yield(())
        response.finish()
        await TokenRotationShutdownGuard.waitForIdle(warnAfter: .seconds(5)) {
            XCTFail("The token rotation did not finish")
        }

        _ = await refresh.value
        let saved = try XCTUnwrap(provider.authStore.loadCredentialDocument())
        XCTAssertEqual(saved.credentials.refreshToken, "new-refresh")
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth/kimi-code.lock").path))
    }

    func testPendingQuitDoesNotSendARefreshRequestBeforeOrAfterUsageRejection() async throws {
        for expiresAt in [2_060, 9_000] {
            let home = try makeHome(expiresAt: expiresAt)
            defer { try? FileManager.default.removeItem(at: home) }
            let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }
            let provider = makeProvider(home: home, http: http)
            TokenRotationShutdownGuard.beginTermination()
            defer { TokenRotationShutdownGuard.cancelTermination() }

            _ = await provider.refresh()

            XCTAssertEqual(http.requests.map(\.method), expiresAt == 2_060 ? [] : ["GET"])
            try assertUnchangedCredentialsAndReleasedLock(in: home, provider: provider)
        }
    }

    func testCancellationBeforeRotationDoesNotSendARefreshRequest() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 500, headers: [:], body: Data()) }
        let provider = makeProvider(home: home, http: http)
        let refresh = Task { await provider.refresh() }
        refresh.cancel()

        _ = await refresh.value

        XCTAssertTrue(http.requests.isEmpty)
        try assertUnchangedCredentialsAndReleasedLock(in: home, provider: provider)
    }

    func testRotationDoesNotOverwriteAnExternalLoginWrittenDuringTheRequest() async throws {
        let home = try makeHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let credential = home.appendingPathComponent("credentials/kimi-code.json")
        let replacement = #"{"access_token":"external-access","refresh_token":"external-refresh","expires_at":9000}"#
        let http = RoutingAsyncHTTPClient { _ in
            try LocalTextFileAccessor().writeText(credential.path, replacement)
            return HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#.utf8))
        }
        let provider = makeProvider(home: home, http: http)

        let snapshot = await provider.refresh()

        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(try LocalTextFileAccessor().readText(credential.path), replacement)
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth/kimi-code.lock").path))
    }

    private func assertUnchangedCredentialsAndReleasedLock(in home: URL, provider: KimiProvider) throws {
        XCTAssertEqual(try provider.authStore.loadCredentialDocument()?.credentials.refreshToken, "old-refresh")
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("oauth/kimi-code.lock").path))
    }

    private func makeHome(expiresAt: Int = 2_060) throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("kimi-quit-\(UUID())")
        let directory = home.appendingPathComponent("credentials")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let login =
            #"{"access_token":"old-access","refresh_token":"old-refresh","expires_at":\#(expiresAt),"expires_in":3600}"#
        try LocalTextFileAccessor().writeText(directory.appendingPathComponent("kimi-code.json").path, login)
        return home
    }

    private func makeProvider(home: URL, http: any HTTPClient) -> KimiProvider {
        let now = Date(timeIntervalSince1970: 2_000)
        return KimiProvider(
            authStore: KimiAuthStore(
                environment: FakeEnvironment(["KIMI_CODE_HOME": home.path]), homeDirectory: { home }),
            usageClient: KimiUsageClient(http: http, now: { now }),
            now: { now }, pricing: { .empty })
    }
}

private struct RoutingAsyncHTTPClient: HTTPClient {
    var respond: @Sendable (HTTPRequest) async throws -> HTTPResponse

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        try await respond(request)
    }
}
