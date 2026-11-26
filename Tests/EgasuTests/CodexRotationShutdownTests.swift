import XCTest
@testable import Egasu

@MainActor
final class CodexRotationShutdownTests: XCTestCase {
    private let service = CodexAuthStore.keychainService
    private let original =
        #"{"tokens":{"access_token":"old","refresh_token":"original"},"last_refresh":"2020-01-01T00:00:00Z"}"#

    func testQuitWaitsForSaveEvenWhenUsageRefreshIsCancelledDuringRequest() async throws {
        defer { TokenRotationShutdownGuard.cancelTermination() }
        let keychain = SwitchRecoveryKeychain()
        keychain.values[service] = original
        let requestStarted = expectation(description: "refresh request started")
        let saveStarted = expectation(description: "received tokens are being saved")
        let (responses, response) = AsyncStream<Void>.makeStream()
        let resumeSave = DispatchSemaphore(value: 0)
        keychain.beforeWrite = { @Sendable _, _ in
            saveStarted.fulfill()
            guard resumeSave.wait(timeout: .now() + 8) == .success else {
                throw SwitchRecoveryKeychain.Failure.injected
            }
        }
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url, CodexUsageClient.refreshURL)
            requestStarted.fulfill()
            for await _ in responses { break }
            try Task.checkCancellation()
            return Self.rotated
        }
        let provider = makeProvider(keychain, http)
        let refresh = Task { await provider.refresh() }
        await fulfillment(of: [requestStarted], timeout: 5)
        refresh.cancel()
        response.yield(())
        response.finish()
        await fulfillment(of: [saveStarted], timeout: 5)

        TokenRotationShutdownGuard.beginTermination()
        XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
        XCTAssertEqual(keychain.values[service], original)
        let stillWaiting = expectation(description: "quit is waiting for the pending save")
        let quit = Task {
            await TokenRotationShutdownGuard.waitForIdle(warnAfter: .milliseconds(10)) { stillWaiting.fulfill() }
        }
        await fulfillment(of: [stillWaiting], timeout: 5)
        resumeSave.signal()
        await quit.value

        let saved = try XCTUnwrap(keychain.values[service])
        XCTAssertEqual(CodexAuthStore.parseAuth(saved)?.tokens?.refreshToken, "rotated")
        _ = await refresh.value
    }

    func testOneShotReaderDoesNotReturnWhileItsCancelledRotationIsSaving() async throws {
        let keychain = SwitchRecoveryKeychain()
        keychain.values[service] = original
        let writing = expectation(description: "refresh reached credential persistence")
        let prematureReturn = expectation(description: "CLI returned before credential persistence")
        prematureReturn.isInverted = true
        let release = DispatchSemaphore(value: 0)
        keychain.beforeWrite = { @Sendable _, _ in
            writing.fulfill()
            guard release.wait(timeout: .now() + 8) == .success else { throw SwitchRecoveryKeychain.Failure.injected }
        }
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL { return Self.rotated }
            return HTTPResponse(statusCode: 503, headers: [:], body: Data())
        }
        let suite = "EgasuTests.CodexCLIShutdown.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reader = UsageReader(userDefaults: defaults, providers: [makeProvider(keychain, http)])
        let read = Task {
            _ = try await reader.read(providerID: "codex", force: true)
            if !TokenRotationShutdownGuard.isIdle { prematureReturn.fulfill() }
            return keychain.values[service]
        }

        await fulfillment(of: [writing], timeout: 5)
        read.cancel()
        await fulfillment(of: [prematureReturn], timeout: 0.25)
        release.signal()
        let savedAtReturn = try await read.value
        await TokenRotationShutdownGuard.waitForIdle(warnAfter: .seconds(5)) {}
        let saved = try XCTUnwrap(savedAtReturn)
        XCTAssertEqual(CodexAuthStore.parseAuth(saved)?.tokens?.refreshToken, "rotated")
    }

    func testTerminationPreventsBothProactiveAndUnauthorizedRetryRotations() async {
        defer { TokenRotationShutdownGuard.cancelTermination() }
        TokenRotationShutdownGuard.beginTermination()
        let fresh = #"{"tokens":{"access_token":"fresh","refresh_token":"original"}}"#
        for (credential, expectedRequests) in [(original, 0), (fresh, 1)] {
            let keychain = SwitchRecoveryKeychain()
            keychain.values[service] = credential
            let http = RoutingHTTPClient { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }

            _ = await makeProvider(keychain, http).refresh()

            XCTAssertEqual(
                http.requests.map(\.url), Array(repeating: CodexUsageClient.usageURL, count: expectedRequests))
            XCTAssertEqual(keychain.values[service], credential)
            XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        }
    }

    func testRefreshFailureAndSaveFailureReleaseTerminationGuard() async {
        for refreshFails in [true, false] {
            let keychain = SwitchRecoveryKeychain()
            keychain.values[service] = original
            keychain.beforeWrite = { @Sendable _, _ in throw SwitchRecoveryKeychain.Failure.injected }
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.refreshURL {
                    XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
                    return refreshFails ? HTTPResponse(statusCode: 503, headers: [:], body: Data()) : Self.rotated
                }
                let json =
                    #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#
                return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
            }

            let snapshot = await makeProvider(keychain, http).refresh()

            XCTAssertEqual(snapshot.errorCategory != nil, refreshFails)
            if !refreshFails { XCTAssertEqual(snapshot.isDegraded, true) }
            XCTAssertEqual(keychain.values[service], original)
            XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        }
    }

    private nonisolated static var rotated: HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:], body: Data(#"{"access_token":"new","refresh_token":"rotated"}"#.utf8))
    }

    private func makeProvider(_ keychain: SwitchRecoveryKeychain, _ http: RoutingHTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(
                incrementalScanner: IncrementalJSONLScanner<CodexLogUsageScanner.Event>(),
                cacheIdentityOverride: UUID().uuidString, rootsOverride: []),
            includeSharedUsage: false, pricing: { .empty }
        )
    }
}
