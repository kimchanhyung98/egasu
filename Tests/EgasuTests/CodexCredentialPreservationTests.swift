import XCTest
@testable import Egasu

@MainActor
final class CodexCredentialPreservationTests: XCTestCase {
    private nonisolated static let path = "/credential-preservation/auth.json"
    private nonisolated static let original = #"{"auth_mode":"chatgpt","root_sentinel":{"keep":true},"tokens":{"access_token":"old","refresh_token":"refresh-A","account_id":"A","token_sentinel":[1,2]},"last_refresh":"2020-01-01T00:00:00Z"}"#
    private nonisolated static let replacement = #"{"auth_mode":"chatgpt","tokens":{"access_token":"new-login","refresh_token":"refresh-B","account_id":"B"}}"#

    func testDelayedRefreshDoesNotOverwriteANewFileLogin() async throws {
        let files = FakeFiles([Self.path: Self.original])
        let http = PreservationHTTP {
            files.files[Self.path] = Self.replacement
        }
        let provider = makeProvider(
            store: CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                                  scope: .home(path: "/credential-preservation")), http: http
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(files.files[Self.path], Self.replacement)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.authenticationIssue)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testDelayedRefreshDoesNotOverwriteANewKeychainLogin() async {
        let keychain = FakeKeychain(Self.original)
        let http = PreservationHTTP { keychain.value = Self.replacement }
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(keychain.value, Self.replacement)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testDelayedRefreshDoesNotOverwriteANewSavedSnapshot() async throws {
        let service = AccountCredentialVault.service(family: "codex", profileID: "saved")
        let originalEntry = try entry(Self.original)
        let replacementEntry = try entry(Self.replacement)
        let keychain = ServiceKeychain(currentUserValues: [service: originalEntry])
        let http = PreservationHTTP { keychain.currentUserValues[service] = replacementEntry }
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: "saved")
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(keychain.currentUserValues[service], replacementEntry)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
    }

    func testSourceRemovalOrUnknownFieldChangeDuringRefreshIsPreserved() async {
        for replacement in [nil, Self.original.replacingOccurrences(of: "true", with: "false"), "invalid-json"] as [String?] {
            let files = FakeFiles([Self.path: Self.original])
            let http = PreservationHTTP { files.files[Self.path] = replacement }
            let provider = makeProvider(store: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                scope: .home(path: "/credential-preservation")
            ), http: http)

            let snapshot = await provider.refresh()

            XCTAssertEqual(files.files[Self.path], replacement)
            XCTAssertNotNil(snapshot.errorCategory)
            XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL])
        }
    }

    func testUnauthorizedRetryCannotOverwriteANewLogin() async {
        let fresh = Self.original.replacingOccurrences(of: "2020-01-01T00:00:00Z", with: EgasuISO8601.string(from: Date()))
        let files = FakeFiles([Self.path: fresh])
        let http = PreservationHTTP(rejectFirstUsage: true) { files.files[Self.path] = Self.replacement }
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: "/credential-preservation")
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(files.files[Self.path], Self.replacement)
        XCTAssertNotNil(snapshot.errorCategory)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL, CodexUsageClient.refreshURL])
    }

    func testUnauthorizedUsageRetryReusesAnExternalRotation() async throws {
        let original = try retryCredential(version: 1)
        let rotated = try retryCredential(version: 2)

        for status in [401, 403] {
            let files = FakeFiles([Self.path: original.text])
            let store = CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                scope: .home(path: "/credential-preservation"), now: { Self.retryInstant }
            )
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.usageURL,
                    request.headers["Authorization"] == "Bearer \(original.token)"
                {
                    files.files[Self.path] = rotated.text
                    return HTTPResponse(statusCode: status, headers: [:], body: Data())
                }
                if request.url == CodexUsageClient.refreshURL { return Self.reusedTokenResponse }
                return Self.retryUsageResponse(request)
            }

            let snapshot = await makeProvider(store: store, http: http).refresh()

            XCTAssertNil(snapshot.errorCategory, "HTTP \(status)")
            XCTAssertNotNil(snapshot.line(label: "Session"), "HTTP \(status)")
            XCTAssertEqual(
                http.requests.filter { $0.url == CodexUsageClient.usageURL }.map { $0.headers["Authorization"] },
                ["Bearer \(original.token)", "Bearer \(rotated.token)"], "HTTP \(status)"
            )
            XCTAssertFalse(http.requests.contains { $0.method == "POST" }, "HTTP \(status)")
            XCTAssertEqual(files.files[Self.path].map { Data($0.utf8) }, Data(rotated.text.utf8))
        }
    }

    func testUnauthorizedUsageRetryStopsWhenTheOriginalLoginIsGoneOrChangedAccounts() async throws {
        let original = try retryCredential(version: 1)
        let rotated = try retryCredential(version: 2)
        let otherUser = try retryCredential(version: 2, subject: "other-user")
        let otherWorkspace = try retryCredential(version: 2, workspace: "other-workspace")
        let cases: [(name: String, replacement: String?, moved: String?)] = [
            ("different user in the same workspace", otherUser.text, nil),
            ("same user in a different workspace", otherWorkspace.text, nil),
            ("deleted login", nil, nil),
            ("login moved to a different source", nil, rotated.text)
        ]
        for scenario in cases {
            let files = FakeFiles()
            let store = CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), now: { Self.retryInstant }
            )
            let originalPath = try XCTUnwrap(store.authPaths().first)
            let alternatePath = try XCTUnwrap(store.authPaths().dropFirst().first)
            files.files[originalPath] = original.text
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.usageURL,
                    request.headers["Authorization"] == "Bearer \(original.token)"
                {
                    files.files[originalPath] = scenario.replacement
                    files.files[alternatePath] = scenario.moved
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
                if request.url == CodexUsageClient.refreshURL { return Self.reusedTokenResponse }
                return Self.retryUsageResponse(request)
            }

            let snapshot = await makeProvider(store: store, http: http).refresh()

            XCTAssertNotNil(snapshot.errorCategory, scenario.name)
            XCTAssertNil(snapshot.liveQuotaObservedAt, scenario.name)
            XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL], scenario.name)
            XCTAssertEqual(files.files[originalPath], scenario.replacement, scenario.name)
            XCTAssertEqual(files.files[alternatePath], scenario.moved, scenario.name)
        }
    }

    func testUnauthorizedUsageRetryStillRefreshesAnUnchangedLogin() async throws {
        let original = try retryCredential(version: 1)
        let rotated = try retryCredential(version: 2)
        let files = FakeFiles([Self.path: original.text])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: "/credential-preservation"), now: { Self.retryInstant }
        )
        let rotatedResponse = try JSONEncoder().encode([
            "access_token": rotated.token, "refresh_token": "refresh-2"
        ])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL,
                request.headers["Authorization"] == "Bearer \(original.token)"
            {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if request.url == CodexUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: rotatedResponse)
            }
            return Self.retryUsageResponse(request)
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(
            http.requests.map(\.url),
            [
                CodexUsageClient.usageURL, CodexUsageClient.refreshURL,
                CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL
            ]
        )
        XCTAssertEqual(
            http.requests.filter { $0.url == CodexUsageClient.usageURL }.map { $0.headers["Authorization"] },
            ["Bearer \(original.token)", "Bearer \(rotated.token)"]
        )
        let saved = try XCTUnwrap(CodexAuthStore.parseAuth(try XCTUnwrap(files.files[Self.path])))
        XCTAssertEqual(saved.tokens?.accessToken, rotated.token)
        XCTAssertEqual(saved.tokens?.refreshToken, "refresh-2")
    }

    func testUnauthorizedUsageRetryKeepsTheInMemoryRotationAfterAWriteFailure() async throws {
        let original = try retryCredential(version: 0, expiresIn: 60)
        let firstRotation = try retryCredential(version: 1)
        let secondRotation = try retryCredential(version: 2)
        let firstResponse = try JSONEncoder().encode([
            "access_token": firstRotation.token, "refresh_token": "refresh-1"
        ])
        let secondResponse = try JSONEncoder().encode([
            "access_token": secondRotation.token, "refresh_token": "refresh-2"
        ])
        let keychain = SwitchRecoveryKeychain()
        let service = CodexAuthStore.keychainService
        keychain.values[service] = original.text
        keychain.beforeWrite = { @Sendable _, text in
            if CodexAuthStore.parseAuth(text)?.tokens?.refreshToken == "refresh-1" {
                throw SwitchRecoveryKeychain.Failure.injected
            }
        }
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, now: { Self.retryInstant }
        )
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL {
                let body = String(decoding: request.body ?? Data(), as: UTF8.self)
                if body.hasSuffix("&refresh_token=refresh-0") {
                    return HTTPResponse(statusCode: 200, headers: [:], body: firstResponse)
                }
                if body.hasSuffix("&refresh_token=refresh-1") {
                    return HTTPResponse(statusCode: 200, headers: [:], body: secondResponse)
                }
                return Self.reusedTokenResponse
            }
            if request.url == CodexUsageClient.usageURL,
                request.headers["Authorization"] != "Bearer \(secondRotation.token)"
            {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            return Self.retryUsageResponse(request)
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.isDegraded, true)
        XCTAssertEqual(
            http.requests.filter { $0.url != CodexUsageClient.resetCreditsURL }.map(\.url),
            [
                CodexUsageClient.refreshURL, CodexUsageClient.usageURL,
                CodexUsageClient.refreshURL, CodexUsageClient.usageURL
            ]
        )
        XCTAssertEqual(
            http.requests.filter { $0.url == CodexUsageClient.usageURL }.map { $0.headers["Authorization"] },
            ["Bearer \(firstRotation.token)", "Bearer \(secondRotation.token)"]
        )
        let saved = try XCTUnwrap(CodexAuthStore.parseAuth(try XCTUnwrap(keychain.values[service])))
        XCTAssertEqual(saved.tokens?.accessToken, secondRotation.token)
        XCTAssertEqual(saved.tokens?.refreshToken, "refresh-2")
    }

    func testSavePreservesUnknownRootAndTokenFields() throws {
        for input in [Self.original, Self.original.utf8.map { String(format: "%02x", $0) }.joined()] {
            let files = FakeFiles([Self.path: input])
            let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
            var state = try XCTUnwrap(store.loadAuth(at: Self.path))
            state.auth.tokens?.accessToken = "rotated"
            state.auth.tokens?.refreshToken = "rotated-refresh"
            state.auth.lastRefresh = "2026-10-05T00:00:00Z"

            try store.save(state)

            let saved = try XCTUnwrap(files.files[Self.path])
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
            XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
            XCTAssertEqual(object["root_sentinel"] as? [String: Bool], ["keep": true])
            let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["token_sentinel"] as? [Int], [1, 2])
            XCTAssertEqual(tokens["access_token"] as? String, "rotated")
            XCTAssertEqual(tokens["refresh_token"] as? String, "rotated-refresh")
        }
    }

    func testKeychainAndSnapshotSavePreserveCredentialEnvelope() throws {
        let service = AccountCredentialVault.service(family: "codex", profileID: "saved")
        let keychain = ServiceKeychain(values: [CodexAuthStore.keychainService: Self.original],
                                      currentUserValues: [service: try entry(Self.original)])
        let standard = CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain)
        let snapshot = CodexAuthStore(environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
                                      scope: .accountSnapshot(profileID: "saved"))
        for (store, loaded) in [(standard, standard.loadKeychainAuth()),
                               (snapshot, try snapshot.loadAccountSnapshot(profileID: "saved"))] {
            var state = try XCTUnwrap(loaded)
            state.auth.tokens?.accessToken = "rotated"
            try store.save(state)
        }
        let savedSnapshot = try XCTUnwrap(AccountCredentialVault(keychain: keychain).load(family: "codex", profileID: "saved"))
        XCTAssertEqual(savedSnapshot.claudeOAuthAccount, "wrapper-sentinel")
        for text in [try XCTUnwrap(keychain.values[CodexAuthStore.keychainService]), savedSnapshot.credential] {
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
            XCTAssertEqual(object["root_sentinel"] as? [String: Bool], ["keep": true])
            let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
            XCTAssertEqual(tokens["token_sentinel"] as? [Int], [1, 2])
            XCTAssertEqual(tokens["access_token"] as? String, "rotated")
        }
    }

    func testSaveWithoutALoadedSourceRevisionCannotWrite() throws {
        let files = FakeFiles([Self.path: Self.replacement])
        let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
        let state = CodexAuthState(auth: try XCTUnwrap(CodexAuthStore.parseAuth(Self.original)),
                                  source: .file(path: Self.path))

        XCTAssertThrowsError(try store.save(state))

        XCTAssertEqual(files.files[Self.path], Self.replacement)
    }

    func testReformattedCredentialKeepsModelEqualityButRejectsStaleWriteback() throws {
        let files = FakeFiles([Self.path: Self.original])
        let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
        let original = try XCTUnwrap(store.loadAuth(at: Self.path))
        let reformatted = Self.original + "\n"
        files.files[Self.path] = reformatted
        let reloaded = try XCTUnwrap(store.loadAuth(at: Self.path))

        XCTAssertEqual(original, reloaded)
        XCTAssertEqual(Set([original, reloaded]).count, 1)
        var rotated = original
        rotated.auth.tokens?.accessToken = "rotated"
        XCTAssertNotEqual(original, rotated)
        XCTAssertThrowsError(try store.save(rotated)) { error in
            XCTAssertEqual(error as? CodexAuthError, .credentialsChanged)
        }
        XCTAssertEqual(files.files[Self.path], reformatted)
    }

    func testUnchangedNullFieldsRemainInTheDocument() throws {
        let raw = #"{"OPENAI_API_KEY":null,"tokens":{"access_token":"old","refresh_token":null,"id_token":null,"account_id":"A","extra":null},"future":{"list":[true,null,{"nested":"keep"}]}}"#
        let files = FakeFiles([Self.path: raw])
        let store = CodexAuthStore(environment: FakeEnvironment(), files: files, keychain: FakeKeychain())
        var state = try XCTUnwrap(store.loadAuth(at: Self.path))
        state.auth.tokens?.accessToken = "rotated"

        try store.save(state)

        let saved = try XCTUnwrap(files.files[Self.path])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(saved.utf8)) as? [String: Any])
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertTrue(object["OPENAI_API_KEY"] is NSNull)
        XCTAssertEqual(object["future"] as? NSDictionary, original["future"] as? NSDictionary)
        let tokens = try XCTUnwrap(object["tokens"] as? [String: Any])
        XCTAssertTrue(tokens["refresh_token"] is NSNull)
        XCTAssertTrue(tokens["id_token"] is NSNull)
        XCTAssertTrue(tokens["extra"] is NSNull)
        XCTAssertEqual(tokens["account_id"] as? String, "A")
    }

    func testUnchangedRefreshPersistsTokensAndRetainsEnvelope() async throws {
        let files = FakeFiles([Self.path: Self.original])
        let http = PreservationHTTP {}
        let provider = makeProvider(store: CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: "/credential-preservation")
        ), http: http)

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        let text = try XCTUnwrap(files.files[Self.path])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["auth_mode"] as? String, "chatgpt")
        XCTAssertEqual(object["root_sentinel"] as? [String: Bool], ["keep": true])
        XCTAssertEqual(CodexAuthStore.parseAuth(text)?.tokens?.accessToken, "rotated-A")
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.refreshURL, CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL])
    }

    private func entry(_ credential: String) throws -> String {
        String(decoding: try JSONEncoder().encode(AccountCredentialVault.Entry(
            credential: credential, claudeOAuthAccount: "wrapper-sentinel"
        )), as: UTF8.self)
    }

    nonisolated static let retryInstant = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated static var reusedTokenResponse: HTTPResponse {
        HTTPResponse(statusCode: 400, headers: [:], body: Data(#"{"error":"refresh_token_reused"}"#.utf8))
    }

    nonisolated static func retryUsageResponse(_ request: HTTPRequest) -> HTTPResponse {
        let body =
            request.url == CodexUsageClient.resetCreditsURL
            ? #"{"available_count":0}"#
            : #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}}}"#
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }

    func retryCredential(
        version: Int, subject: String = "user", workspace: String = "workspace", expiresIn: TimeInterval = 7_200
    ) throws -> (token: String, text: String) {
        let payload = try JSONSerialization.data(withJSONObject: [
            "sub": subject, "exp": Self.retryInstant.addingTimeInterval(expiresIn).timeIntervalSince1970,
            "version": version,
            "https://api.openai.com/auth": ["chatgpt_account_id": workspace]
        ]).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let token = "e30.\(payload).signature"
        let tokens = CodexTokens(accessToken: token, refreshToken: "refresh-\(version)", accountID: workspace)
        let text = String(decoding: try JSONEncoder().encode(CodexAuth(tokens: tokens)), as: UTF8.self)
        return (token, text + "\n")
    }

    func makeProvider(store: CodexAuthStore, http: any HTTPClient) -> CodexProvider {
        CodexProvider(
            authStore: store, usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(environment: FakeEnvironment(),
                cacheIdentityOverride: "credential-preservation", rootsOverride: []), includeSharedUsage: false,
            pricing: { .empty }
        )
    }
}

private final class PreservationHTTP: HTTPClient, @unchecked Sendable {
    let onRefresh: @Sendable () -> Void
    let rejectFirstUsage: Bool
    var requests: [HTTPRequest] = []
    init(rejectFirstUsage: Bool = false, onRefresh: @escaping @Sendable () -> Void) {
        self.rejectFirstUsage = rejectFirstUsage
        self.onRefresh = onRefresh
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if rejectFirstUsage, requests.count == 1 {
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }
        if request.method == "POST" {
            onRefresh()
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(
                #"{"access_token":"rotated-A","refresh_token":"rotated-refresh-A"}"#.utf8
            ))
        }
        return HTTPResponse(statusCode: 200, headers: [:], body: Data(
            #"{"rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},"credits":[]}"#.utf8
        ))
    }
}
