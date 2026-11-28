import XCTest
@testable import Egasu

@MainActor
final class GrokRefreshSafetyTests: XCTestCase {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private nonisolated static let entryKey = "https://auth.x.ai::client"
    private nonisolated static let original = #"{"https://auth.x.ai::client":{"key":"token-A","refresh_token":"refresh-A","expires_at":"2020-01-01T00:00:00Z","custom":"keep"}}"#
    private nonisolated static let replacement = #"{"https://auth.x.ai::client":{"key":"token-B","refresh_token":"refresh-B","expires_at":"2099-01-01T00:00:00Z"}}"#

    func testQuitProtectsRotatedTokensUntilSavedAfterUsageCancellation() async throws {
        defer { TokenRotationShutdownGuard.cancelTermination() }
        let files = GrokReadFailingFiles([GrokAuthStore.authPath: Self.original])
        files.beforeWrite = { XCTAssertFalse(TokenRotationShutdownGuard.isIdle) }
        let requested = expectation(description: "Synthetic service received the refresh")
        let (responses, response) = AsyncStream<Void>.makeStream()
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.url, GrokUsageClient.refreshURL)
            requested.fulfill()
            for await _ in responses { break }
            try Task.checkCancellation()
            return Self.rotationResponse
        }
        let provider = makeProvider(files: files, http: http)
        let refresh = Task { await provider.refresh() }
        defer { refresh.cancel(); response.finish() }
        await fulfillment(of: [requested], timeout: 5)
        TokenRotationShutdownGuard.beginTermination()

        XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
        refresh.cancel()
        response.yield(())
        response.finish()
        _ = await refresh.value

        let saved = try XCTUnwrap(files.backing.files[GrokAuthStore.authPath])
        XCTAssertEqual(GrokAuthStore.parseAuth(saved)?[Self.entryKey]?.refreshToken, "rotated-refresh-A")
        XCTAssertEqual(files.writeAttempts, 1)
        XCTAssertEqual(http.requests.map(\.url), [GrokUsageClient.refreshURL])
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
    }

    func testTerminationPreventsProactiveAndUnauthorizedRetryRotations() async {
        defer { TokenRotationShutdownGuard.cancelTermination() }
        TokenRotationShutdownGuard.beginTermination()
        for (year, expectedRequests) in [("2020", 0), ("2099", 1)] {
            let original = Self.original.replacingOccurrences(of: "2020", with: year)
            let files = FakeFiles([GrokAuthStore.authPath: original])
            let http = GrokSafetyHTTP { _ in HTTPResponse(statusCode: 401, headers: [:], body: Data()) }

            _ = await makeProvider(files: files, http: http).refresh()

            XCTAssertEqual(
                http.requests.map(\.url), Array(repeating: GrokUsageClient.creditsConfigURL, count: expectedRequests))
            XCTAssertEqual(files.files[GrokAuthStore.authPath], original)
            XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        }
    }

    func testCancelledRefreshDoesNotStartRotation() async {
        let files = FakeFiles([GrokAuthStore.authPath: Self.original])
        let http = GrokSafetyHTTP { _ in Self.rotationResponse }
        let provider = makeProvider(files: files, http: http)
        let refresh = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await provider.refresh()
        }

        _ = await refresh.value

        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files[GrokAuthStore.authPath], Self.original)
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
    }

    func testRotationGuardIsReleasedAfterRequestResponseAndSaveFailures() async {
        let responses: [HTTPResponse?] = [
            nil,
            HTTPResponse(statusCode: 503, headers: [:], body: Data()),
            HTTPResponse(statusCode: 200, headers: [:], body: Data("malformed".utf8)),
            Self.rotationResponse
        ]
        for response in responses {
            let files = GrokReadFailingFiles([GrokAuthStore.authPath: Self.original])
            files.beforeWrite = {
                XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
                throw CocoaError(.fileWriteNoPermission)
            }
            let http = GrokSafetyHTTP { request in
                if request.url == GrokUsageClient.refreshURL {
                    XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
                    guard let response else { throw URLError(.timedOut) }
                    return response
                }
                return Self.usageResponse
            }

            _ = await makeProvider(files: files, http: http).refresh()

            XCTAssertEqual(files.backing.files[GrokAuthStore.authPath], Self.original)
            XCTAssertEqual(files.writeAttempts, response?.body == Self.rotationResponse.body ? 1 : 0)
            XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        }
    }

    func testInitialCredentialReadSeparatesMissingMalformedAndInaccessibleFiles() async {
        let cases: [(String?, CocoaError?, ErrorCategory)] = [
            (nil, nil, .notLoggedIn), ("malformed", nil, .authInvalid),
            (Self.original, CocoaError(.fileReadNoPermission), .credentialAccess)
        ]
        for (contents, error, expected) in cases {
            let files = GrokReadFailingFiles(contents.map { [GrokAuthStore.authPath: $0] } ?? [:])
            files.readError = error
            let http = GrokSafetyHTTP { _ in throw URLError(.badURL) }
            let provider = makeProvider(files: files, http: http)

            let snapshot = await provider.refresh()
            let detected = await provider.hasLocalCredentials()

            XCTAssertEqual(snapshot.errorCategory, expected)
            XCTAssertFalse(detected)
            XCTAssertTrue(http.requests.isEmpty)
        }
    }

    func testTokenEndpointFailureReportsItsCauseForExpiredAndRejectedAccessTokens() async {
        let cases: [(Int?, String, ErrorCategory)] = [
            (nil, "", .network), (401, "", .authExpired), (403, "", .authExpired),
            (400, #"{"error":"invalid_grant"}"#, .authExpired), (400, "unknown", .http4xx),
            (429, "", .rateLimited), (503, "", .http5xx), (200, "malformed", .decoding),
            (200, #"{"access_token":" "}"#, .decoding)
        ]
        for expiryYear in ["2020", "2099"] {
            for (status, body, category) in cases {
                let events = DiagnosticEventRecorder()
                let original = Self.original.replacingOccurrences(of: "2020", with: expiryYear)
                let files = FakeFiles([GrokAuthStore.authPath: original])
                let http = GrokSafetyHTTP { request in
                    if request.url == GrokUsageClient.refreshURL {
                        guard let status else { throw URLError(.timedOut) }
                        return HTTPResponse(statusCode: status, headers: [:], body: Data(body.utf8))
                    }
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                let snapshot = await makeProvider(files: files, http: http).refresh()

                XCTAssertEqual(snapshot.errorCategory, category)
                XCTAssertEqual(snapshot.authenticationIssue, category == .authExpired ? .signInNeeded : nil)
                XCTAssertEqual(files.files[GrokAuthStore.authPath], original)
                XCTAssertEqual(
                    events.events.filter { $0.operation == .credentialRefresh },
                    [DiagnosticEvent(.credentialRefresh, result: .failure, category: category, providerID: "grok")])
                XCTAssertFalse(events.events.contains { $0.operation == .credentialSave })
            }
        }
    }

    func testUsableTokenStillRetrievesUsageAfterProactiveRefreshFails() async {
        let soon = EgasuISO8601.string(from: Self.now.addingTimeInterval(120))
        let original = Self.original.replacingOccurrences(of: "2020-01-01T00:00:00Z", with: soon)
        let files = FakeFiles([GrokAuthStore.authPath: original])
        let events = DiagnosticEventRecorder()
        let http = GrokSafetyHTTP { request in
            if request.url == GrokUsageClient.refreshURL { throw URLError(.timedOut) }
            if request.url == GrokUsageClient.creditsConfigURL { return Self.usageResponse }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.line(label: "Weekly limit"))
        XCTAssertEqual(
            http.requests.filter { $0.url == GrokUsageClient.creditsConfigURL }.first?.headers["Authorization"],
            "Bearer token-A")
        XCTAssertTrue(
            events.events.contains(
                DiagnosticEvent(.credentialRefresh, result: .failure, category: .network, providerID: "grok")))
    }

    func testDelayedRefreshPreservesReloginAndLogout() async {
        for replacement in [Self.replacement, nil, "{}",
                            Self.original.replacingOccurrences(of: "refresh-A", with: "externally-rotated"),
                            Self.original.replacingOccurrences(of: "keep", with: "changed")] as [String?] {
            let files = FakeFiles([GrokAuthStore.authPath: Self.original])
            let http = GrokSafetyHTTP { request in
                if request.url == GrokUsageClient.refreshURL {
                    files.files[GrokAuthStore.authPath] = replacement
                    return Self.rotationResponse
                }
                return Self.usageResponse
            }

            let snapshot = await makeProvider(files: files, http: http).refresh()

            XCTAssertEqual(files.files[GrokAuthStore.authPath], replacement)
            XCTAssertNotNil(snapshot.errorCategory)
            XCTAssertNil(snapshot.authenticationIssue)
            XCTAssertEqual(http.requests.map(\.url), [GrokUsageClient.refreshURL])
            XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        }
    }

    func testPersistenceFailureKeepsOriginalSignInAndUsesRotatedTokenForUsage() async {
        for expiryYear in ["2020", "2099"] {
            let events = DiagnosticEventRecorder()
            let original = Self.original.replacingOccurrences(of: "2020", with: expiryYear)
            let files = GrokWriteFailingFiles([GrokAuthStore.authPath: original])
            let http = GrokSafetyHTTP { request in
                if request.url == GrokUsageClient.refreshURL { return Self.rotationResponse }
                if request.url == GrokUsageClient.creditsConfigURL {
                    guard request.headers["Authorization"] == "Bearer rotated-A" else {
                        return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                    }
                    return Self.usageResponse
                }
                return HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
            }

            let snapshot = await makeProvider(files: files, http: http).refresh()
            XCTAssertEqual(
                events.events.filter { $0.operation == .credentialSave },
                [
                    DiagnosticEvent(.credentialSave, result: .degraded, category: .permission, providerID: "grok")
                ])

            XCTAssertNil(snapshot.errorCategory, expiryYear)
            XCTAssertNil(snapshot.authenticationIssue, expiryYear)
            XCTAssertEqual(files.backing.files[GrokAuthStore.authPath], original, expiryYear)
            XCTAssertEqual(files.writeAttempts, 1, expiryYear)
            XCTAssertEqual(http.requests.filter { $0.url == GrokUsageClient.refreshURL }.count, 1, expiryYear)
            let usageAuthorizations = http.requests
                .filter { $0.url == GrokUsageClient.creditsConfigURL }
                .map { $0.headers["Authorization"] }
            XCTAssertEqual(
                usageAuthorizations,
                expiryYear == "2020" ? ["Bearer rotated-A"] : ["Bearer token-A", "Bearer rotated-A"],
                expiryYear
            )
            XCTAssertEqual(
                http.requests.first { $0.url == GrokUsageClient.settingsURL }?.headers["Authorization"],
                "Bearer rotated-A", expiryYear
            )
        }
    }

    func testUnreadableCredentialsAfterRefreshStopUsageWithoutClaimingSignInChanged() async {
        for code in [CocoaError.Code.fileReadNoPermission, .fileReadUnknown] {
            for expiryYear in ["2020", "2099"] {
                let original = Self.original.replacingOccurrences(of: "2020", with: expiryYear)
                let files = GrokReadFailingFiles([GrokAuthStore.authPath: original])
                let http = GrokSafetyHTTP { request in
                    if request.url == GrokUsageClient.refreshURL {
                        files.readError = CocoaError(code)
                        return Self.rotationResponse
                    }
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }

                let snapshot = await makeProvider(files: files, http: http).refresh()

                XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
                XCTAssertNil(snapshot.authenticationIssue)
                XCTAssertEqual(files.backing.files[GrokAuthStore.authPath], original)
                XCTAssertEqual(files.writeAttempts, 0)
                XCTAssertEqual(http.requests.map(\.url), expiryYear == "2020"
                    ? [GrokUsageClient.refreshURL] : [GrokUsageClient.creditsConfigURL, GrokUsageClient.refreshURL])
                XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
            }
        }
    }

    func testSaveReportsCredentialAccessFailureSeparatelyFromChangedCredentials() throws {
        let files = GrokReadFailingFiles([GrokAuthStore.authPath: Self.original])
        let store = GrokAuthStore(files: files, environment: FakeEnvironment())
        var state = try XCTUnwrap(store.loadAuthCandidates().first)
        state.entry.key = "rotated-A"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sink = LogFile(directory: directory, fileName: "grok.log")
        sink.open()
        let previousSink = AppLog.sink
        AppLog.sink = sink
        defer {
            AppLog.sink = previousSink
            try? FileManager.default.removeItem(at: directory)
        }
        files.readError = CocoaError(
            .fileReadNoPermission, userInfo: [NSLocalizedDescriptionKey: "PRIVATE-file-contents"])

        XCTAssertThrowsError(try store.save(state)) { error in
            XCTAssertEqual(error as? GrokAuthError, .credentialReadFailed)
            XCTAssertEqual(ErrorCategory.classify(error), .credentialAccess)
            XCTAssertFalse(error.localizedDescription.contains("sign-in changed"))
        }

        XCTAssertEqual(files.writeAttempts, 0)
        XCTAssertEqual(files.backing.files[GrokAuthStore.authPath], Self.original)
        let log = try String(contentsOf: directory.appendingPathComponent("grok.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("[auth:grok] operation=credential_save result=failure category=credential_access"))
        XCTAssertTrue(log.contains("context=verify source before saving rotated credentials"))
        XCTAssertTrue(log.contains("error_code=\(CocoaError.Code.fileReadNoPermission.rawValue)"))
        XCTAssertFalse(log.contains("PRIVATE-file-contents"))
    }

    func testConcurrentSiblingChangesAreKeptWhenTheSelectedEntryIsUnchanged() async throws {
        let events = DiagnosticEventRecorder()
        let files = FakeFiles([GrokAuthStore.authPath: Self.original])
        let http = GrokSafetyHTTP { request in
            if request.url == GrokUsageClient.refreshURL {
                var object = try XCTUnwrap(GrokAuthStore.parseJSONObject(Self.original))
                object["sibling"] = ["key": "sibling-new-login", "nested": ["keep": true]] as [String: Any]
                files.files[GrokAuthStore.authPath] = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                return Self.rotationResponse
            }
            return Self.usageResponse
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()
        XCTAssertEqual(
            events.events.filter { $0.operation == .credentialSave },
            [
                DiagnosticEvent(.credentialSave, result: .success, providerID: "grok")
            ])

        XCTAssertNil(snapshot.errorCategory)
        let object = try XCTUnwrap(GrokAuthStore.parseJSONObject(try XCTUnwrap(files.files[GrokAuthStore.authPath])))
        let sibling = try XCTUnwrap(object["sibling"] as? [String: Any])
        XCTAssertEqual(sibling["key"] as? String, "sibling-new-login")
        XCTAssertEqual(sibling["nested"] as? [String: Bool], ["keep": true])
        let selected = try XCTUnwrap(object[Self.entryKey] as? [String: Any])
        XCTAssertEqual(selected["custom"] as? String, "keep")
        XCTAssertEqual(selected["key"] as? String, "rotated-A")
    }

    func testProactiveRotationFollowedByUnauthorizedRetryUsesTheSavedGeneration() async throws {
        let files = FakeFiles([GrokAuthStore.authPath: Self.original])
        let http = GrokSafetyHTTP { request in
            if request.url == GrokUsageClient.refreshURL {
                if String(decoding: request.body ?? Data(), as: UTF8.self).contains("rotated-refresh-A") {
                    return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                        #"{"access_token":"second-rotation","refresh_token":"second-refresh","expires_in":3600}"#.utf8
                    ))
                }
                return Self.rotationResponse
            }
            if request.url == GrokUsageClient.creditsConfigURL,
               request.headers["Authorization"] == "Bearer rotated-A" {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Self.usageResponse
        }

        let snapshot = await makeProvider(files: files, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.filter { $0.url == GrokUsageClient.refreshURL }.count, 2)
        XCTAssertEqual(GrokAuthStore.parseAuth(try XCTUnwrap(files.files[GrokAuthStore.authPath]))?[Self.entryKey]?.key,
                       "second-rotation")
    }

    private func makeProvider(files: TextFileAccessing, http: HTTPClient) -> GrokProvider {
        GrokProvider(
            authStore: GrokAuthStore(files: files, environment: FakeEnvironment(), now: { Self.now }),
            usageClient: GrokUsageClient(httpClient: http),
            logUsageScanner: GrokLogUsageScanner(files: FakeFiles(), environment: FakeEnvironment(),
                                                homeDirectory: { URL(fileURLWithPath: "/fixture") }),
            sharedUsage: .init(collectors: []),
            now: { Self.now }, pricing: { .empty }
        )
    }

    private nonisolated static var rotationResponse: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"access_token":"rotated-A","refresh_token":"rotated-refresh-A","expires_in":3600}"#.utf8
        ))
    }

    private nonisolated static var usageResponse: HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: GrokCreditsFixtures.capturedResponseBody)
    }
}

private final class GrokSafetyHTTP: HTTPClient, @unchecked Sendable {
    var requests: [HTTPRequest] = []
    let handler: @Sendable (HTTPRequest) throws -> HTTPResponse
    init(handler: @escaping @Sendable (HTTPRequest) throws -> HTTPResponse) { self.handler = handler }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        return try handler(request)
    }
}

private final class GrokWriteFailingFiles: TextFileAccessing, @unchecked Sendable {
    let backing: FakeFiles
    private(set) var writeAttempts = 0

    init(_ files: [String: String]) { backing = FakeFiles(files) }

    func exists(_ path: String) -> Bool { backing.exists(path) }
    func readText(_ path: String) throws -> String { try backing.readText(path) }
    func remove(_ path: String) throws { try backing.remove(path) }

    func writeText(_ path: String, _ text: String) throws {
        writeAttempts += 1
        throw CocoaError(.fileWriteNoPermission)
    }
}

private final class GrokReadFailingFiles: TextFileAccessing, @unchecked Sendable {
    let backing: FakeFiles
    var readError: CocoaError?
    var beforeWrite: (@Sendable () throws -> Void)?
    private(set) var writeAttempts = 0

    init(_ files: [String: String]) { backing = FakeFiles(files) }

    func exists(_ path: String) -> Bool { backing.exists(path) }
    func readText(_ path: String) throws -> String {
        if let readError { throw readError }
        return try backing.readText(path)
    }
    func remove(_ path: String) throws { try backing.remove(path) }
    func writeText(_ path: String, _ text: String) throws {
        writeAttempts += 1
        try beforeWrite?()
        try backing.writeText(path, text)
    }
}
