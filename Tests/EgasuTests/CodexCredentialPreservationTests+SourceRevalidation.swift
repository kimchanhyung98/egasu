import Foundation
import XCTest
@testable import Egasu

extension CodexCredentialPreservationTests {
    func testSuccessfulUsageRejectsAReplacedUserInTheSameWorkspace() async throws {
        let home = "/successful-usage-revalidation"
        let path = "\(home)/auth.json"
        let original = try retryCredential(version: 0, subject: "alice", workspace: "team")
        let originalKey = try XCTUnwrap(CodexResetClaimBinding.verifiedAccountKey(for: original.text))
        for expectedIdentity in ["team", nil] as [String?] {
            for subject in ["alice", "bob"] {
                let replacement = try retryCredential(version: 1, subject: subject, workspace: "team")
                let replacementKey = try XCTUnwrap(CodexResetClaimBinding.verifiedAccountKey(for: replacement.text))
                let sameUser = subject == "alice"
                XCTAssertEqual(originalKey == replacementKey, sameUser)
                let files = FakeFiles([path: original.text])
                let store = CodexAuthStore(
                    environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                    scope: .home(path: home), expectedIdentityKey: expectedIdentity, now: { Self.retryInstant })
                let http = RoutingHTTPClient { request in
                    if request.url == CodexUsageClient.usageURL { files.files[path] = replacement.text }
                    XCTAssertEqual(request.headers["Authorization"], "Bearer \(original.token)")
                    return Self.retryUsageResponse(request)
                }
                let provider = makeProvider(store: store, http: http)

                let snapshot = await provider.refresh()

                XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.usageURL }.count, 1)
                XCTAssertEqual(files.files[path], replacement.text)
                if sameUser {
                    XCTAssertNil(snapshot.errorCategory)
                    XCTAssertEqual(snapshot.liveQuotaAccountKey, originalKey)
                    XCTAssertNotNil(snapshot.line(label: "Session"))
                } else {
                    XCTAssertEqual(snapshot.errorCategory, .other)
                    XCTAssertNil(snapshot.liveQuotaAccountKey)
                    XCTAssertNil(snapshot.liveQuotaObservedAt)
                    XCTAssertNil(snapshot.codexResetClaimBinding)
                    XCTAssertNil(snapshot.line(label: "Session"))
                    XCTAssertTrue(provider.usageTimerObservations.isEmpty)
                }
            }
        }
    }

    func testSuccessfulUsageRejectsLostOrConflictingVerifiedIdentity() async throws {
        let original = try retryCredential(version: 0)
        let otherWorkspace = try retryCredential(version: 1, workspace: "other-workspace")
        let otherUser = try retryCredential(version: 1, subject: "other-user")
        var conflicting = try XCTUnwrap(CodexAuthStore.parseAuth(original.text))
        conflicting.tokens?.idToken = otherUser.token
        let conflict = String(decoding: try JSONEncoder().encode(conflicting), as: UTF8.self)
        let replacements: [String?] = [
            nil, "invalid-json", #"{"OPENAI_API_KEY":"fixture-key"}"#,
            #"{"tokens":{"access_token":"opaque","account_id":"workspace"}}"#,
            #"{"tokens":{"access_token":"","account_id":"workspace"}}"#,
            conflict, otherWorkspace.text
        ]
        let home = "/successful-usage-revalidation"
        let path = "\(home)/auth.json"
        for replacement in replacements {
            let files = FakeFiles([path: original.text])
            let store = CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                scope: .home(path: home), now: { Self.retryInstant })
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.usageURL { files.files[path] = replacement }
                return Self.retryUsageResponse(request)
            }

            let snapshot = await makeProvider(store: store, http: http).refresh()

            XCTAssertEqual(snapshot.errorCategory, .other)
            XCTAssertNil(snapshot.liveQuotaAccountKey)
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.usageURL }.count, 1)
            XCTAssertEqual(files.files[path], replacement)
        }
    }

    func testSuccessfulUsageRejectsRemovalOfAnUnverifiedCredential() async {
        let home = "/successful-usage-revalidation"
        let path = "\(home)/auth.json"
        let files = FakeFiles([path: #"{"tokens":{"access_token":"opaque"}}"#])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), scope: .home(path: home))
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL { files.files[path] = nil }
            return Self.retryUsageResponse(request)
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertEqual(http.requests.filter { $0.url == CodexUsageClient.usageURL }.count, 1)
        XCTAssertNil(files.files[path])
    }

    func testSuccessfulUsagePreservesTheOriginalSourceReadFailure() async throws {
        let original = try retryCredential(version: 0)
        let home = "/successful-usage-revalidation"
        let path = "\(home)/auth.json"
        let files = FakeFiles([path: original.text])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: home), now: { Self.retryInstant })
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL { files.unreadablePaths.insert(path) }
            return Self.retryUsageResponse(request)
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .permission)
        XCTAssertEqual(snapshot.errorPresentation, UserFacingErrors.presentation(CocoaError(.fileReadNoPermission)))
        XCTAssertNil(snapshot.liveQuotaObservedAt)
        XCTAssertEqual(files.files[path], original.text)
    }

    func testSuccessfulUsagePreservesAnInMemoryRotationAfterAWriteFailure() async throws {
        let verified = try retryCredential(version: 0, expiresIn: 60)
        let rotated = try retryCredential(version: 1)
        let opaque =
            #"{"tokens":{"access_token":"old","refresh_token":"refresh-0"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        let scenarios = [(verified.text, rotated.token), (opaque, "rotated-opaque"), (opaque, rotated.token)]
        for (original, token) in scenarios {
            let keychain = SwitchRecoveryKeychain()
            let service = CodexAuthStore.keychainService
            keychain.values[service] = original
            keychain.beforeWrite = { _, _ in throw SwitchRecoveryKeychain.Failure.injected }
            let store = CodexAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, now: { Self.retryInstant })
            let response = try JSONEncoder().encode(["access_token": token, "refresh_token": "refresh-1"])
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.refreshURL {
                    return HTTPResponse(statusCode: 200, headers: [:], body: response)
                }
                XCTAssertEqual(request.headers["Authorization"], "Bearer \(token)")
                return Self.retryUsageResponse(request)
            }

            let snapshot = await makeProvider(store: store, http: http).refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.isDegraded, true)
            XCTAssertNotNil(snapshot.line(label: "Session"))
            XCTAssertEqual(keychain.values[service], original)
        }
    }

    func testSuccessfulUsageRejectsChangedIdentityAfterAnInMemoryRotation() async throws {
        let verified = try retryCredential(version: 0, expiresIn: 60)
        let rotated = try retryCredential(version: 1)
        let otherUser = try retryCredential(version: 1, subject: "other-user")
        let opaque =
            #"{"tokens":{"access_token":"old","refresh_token":"refresh-0"},"last_refresh":"2020-01-01T00:00:00Z"}"#
        var conflicting = try XCTUnwrap(CodexAuthStore.parseAuth(verified.text))
        conflicting.tokens?.idToken = otherUser.token
        let conflict = String(decoding: try JSONEncoder().encode(conflicting), as: UTF8.self)
        let scenarios: [(original: String, token: String, replacement: String?)] = [
            (verified.text, otherUser.token, nil),
            (opaque, rotated.token, opaque.replacingOccurrences(of: "old", with: "other-login")),
            (conflict, rotated.token, nil)
        ]
        for (original, token, replacement) in scenarios {
            let keychain = SwitchRecoveryKeychain()
            let service = CodexAuthStore.keychainService
            keychain.values[service] = original
            keychain.beforeWrite = { _, _ in throw SwitchRecoveryKeychain.Failure.injected }
            let store = CodexAuthStore(
                environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, now: { Self.retryInstant })
            let response = try JSONEncoder().encode([
                "access_token": token, "refresh_token": "refresh-1", "id_token": token
            ])
            let http = RoutingHTTPClient { request in
                if request.url == CodexUsageClient.refreshURL {
                    return HTTPResponse(statusCode: 200, headers: [:], body: response)
                }
                if request.url == CodexUsageClient.usageURL, let replacement {
                    keychain.values[service] = replacement
                }
                return Self.retryUsageResponse(request)
            }

            let snapshot = await makeProvider(store: store, http: http).refresh()

            XCTAssertEqual(snapshot.errorCategory, .other)
            XCTAssertNil(snapshot.liveQuotaAccountKey)
            XCTAssertNil(snapshot.line(label: "Session"))
            XCTAssertEqual(keychain.values[service], replacement ?? original)
            XCTAssertEqual(
                http.requests.map(\.url),
                [CodexUsageClient.refreshURL, CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL]
            )
        }
    }

    func testSuccessfulUsageRejectsConflictingTokensAfterAnInMemoryRotation() async throws {
        let original = try retryCredential(version: 0, expiresIn: 60)
        var originalAuth = try XCTUnwrap(CodexAuthStore.parseAuth(original.text))
        originalAuth.tokens?.idToken = original.token
        let credential = String(decoding: try JSONEncoder().encode(originalAuth), as: UTF8.self)
        let rotated = try retryCredential(version: 1, subject: "other-user")
        let keychain = SwitchRecoveryKeychain()
        let service = CodexAuthStore.keychainService
        keychain.values[service] = credential
        keychain.beforeWrite = { _, _ in throw SwitchRecoveryKeychain.Failure.injected }
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            expectedIdentityKey: "workspace", now: { Self.retryInstant })
        let response = try JSONEncoder().encode(["access_token": rotated.token, "refresh_token": "refresh-1"])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL {
                return HTTPResponse(statusCode: 200, headers: [:], body: response)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer \(rotated.token)")
            return Self.retryUsageResponse(request)
        }
        let provider = makeProvider(store: store, http: http)

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.errorCategory, .other)
        XCTAssertNil(snapshot.liveQuotaAccountKey)
        XCTAssertNil(snapshot.liveQuotaObservedAt)
        XCTAssertNil(snapshot.codexResetClaimBinding)
        XCTAssertNil(snapshot.line(label: "Session"))
        XCTAssertTrue(provider.usageTimerObservations.isEmpty)
        XCTAssertEqual(keychain.values[service], credential)
        XCTAssertEqual(
            http.requests.map(\.url),
            [CodexUsageClient.refreshURL, CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL]
        )
    }

    func testProactiveRefreshUsesAnExternalRotationFromTheOriginalSource() async throws {
        let original = try retryCredential(version: 0, expiresIn: 60)
        let rotated = try retryCredential(version: 1)
        let home = "/proactive-auth-revalidation"
        let path = "\(home)/auth.json"
        let files = FakeFiles([path: original.text])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), scope: .home(path: home),
            now: {
                files.files[path] = rotated.text
                return Self.retryInstant
            }
        )
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.refreshURL { return Self.reusedTokenResponse }
            return Self.retryUsageResponse(request)
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNotNil(snapshot.liveQuotaObservedAt)
        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL])
        XCTAssertEqual(http.requests.first?.headers["Authorization"], "Bearer \(rotated.token)")
        XCTAssertEqual(files.files[path], rotated.text)
    }

    func testProactiveRefreshPreservesTheOriginalSourceReadFailure() async throws {
        let original = try retryCredential(version: 0, expiresIn: 60)
        let home = "/proactive-auth-revalidation"
        let path = "\(home)/auth.json"
        let files = FakeFiles([path: original.text])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(), scope: .home(path: home),
            now: {
                files.unreadablePaths.insert(path)
                return Self.retryInstant
            }
        )
        let http = RoutingHTTPClient { _ in Self.reusedTokenResponse }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertEqual(snapshot.errorCategory, .permission)
        XCTAssertEqual(snapshot.errorPresentation, UserFacingErrors.presentation(CocoaError(.fileReadNoPermission)))
        XCTAssertTrue(http.requests.isEmpty)
        XCTAssertEqual(files.files[path], original.text)
    }

    func testUnauthorizedUsageRetryPreservesUpdatedFieldsInTheOriginalCredential() async throws {
        let original = try retryCredential(version: 0)
        let rotated = try retryCredential(version: 1)
        let home = "/credential-revalidation"
        let path = "\(home)/auth.json"
        let edited = #"{"fixture_field":"edited","# + String(original.text.dropFirst())
        let files = FakeFiles([path: original.text])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: home), now: { Self.retryInstant }
        )
        let rotatedResponse = try JSONEncoder().encode([
            "access_token": rotated.token, "refresh_token": "refresh-1"
        ])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL,
                request.headers["Authorization"] == "Bearer \(original.token)"
            {
                files.files[path] = edited
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
        let saved = try XCTUnwrap(files.files[path])
        XCTAssertEqual(CodexAuthStore.parseAuth(saved)?.tokens?.refreshToken, "refresh-1")
        let document = try XCTUnwrap(ProviderParse.jsonObject(Data(saved.utf8)))
        XCTAssertEqual(document["fixture_field"] as? String, "edited")
    }

    func testUnauthorizedUsageRetryKeepsTheInMemoryRotationWhenTheOldCredentialIsReformatted() async throws {
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
            if request.url == CodexUsageClient.usageURL {
                if request.headers["Authorization"] == "Bearer \(firstRotation.token)" {
                    keychain.values[service] = original.text + "\n"
                }
                if request.headers["Authorization"] != "Bearer \(secondRotation.token)" {
                    return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                }
            }
            return Self.retryUsageResponse(request)
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertNil(snapshot.errorCategory)
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

    func testUnauthorizedUsageRetryReportsCredentialFileReadFailure() async throws {
        let original = try retryCredential(version: 0)
        let home = "/credential-revalidation"
        let path = "\(home)/auth.json"
        let files = FakeFiles([path: original.text])
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
            scope: .home(path: home), now: { Self.retryInstant }
        )

        await assertUnauthorizedUsageReadFailure(store: store, error: CocoaError(.fileReadNoPermission)) {
            files.unreadablePaths.insert(path)
        }

        XCTAssertEqual(files.files[path], original.text)
    }

    func testUnauthorizedUsageRetryReportsSharedKeychainReadFailure() async throws {
        let original = try retryCredential(version: 0)
        let service = CodexAuthStore.keychainService
        let keychain = SwitchRecoveryKeychain()
        keychain.values[service] = original.text
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, now: { Self.retryInstant }
        )
        let readError = KeychainError.readFailed("Fixture Keychain read was denied.")

        await assertUnauthorizedUsageReadFailure(store: store, error: readError) {
            keychain.beforeRead = { _ in throw readError }
        }

        XCTAssertEqual(keychain.values[service], original.text)
        XCTAssertEqual(keychain.writeCount, 0)
    }

    private func assertUnauthorizedUsageReadFailure(
        store: CodexAuthStore, error: any Error, denyRead: @escaping @Sendable () -> Void
    ) async {
        let http = RoutingHTTPClient { request in
            guard request.url == CodexUsageClient.usageURL else { return Self.reusedTokenResponse }
            denyRead()
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL])
        XCTAssertEqual(snapshot.errorCategory, ErrorCategory.classify(error))
        XCTAssertEqual(snapshot.errorPresentation, UserFacingErrors.presentation(error))
        XCTAssertNil(snapshot.liveQuotaObservedAt)
    }

    func testUnauthorizedUsageRetryReportsManagedKeychainReadFailure() async throws {
        let original = try retryCredential(version: 0)
        let profileID = "credential-revalidation"
        let service = AccountCredentialVault.service(family: "codex", profileID: profileID)
        let keychain = SwitchRecoveryKeychain()
        let entry = AccountCredentialVault.Entry(credential: original.text)
        keychain.currentUserValues[service] = String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        let store = CodexAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profileID), now: { Self.retryInstant }
        )
        let readError = KeychainError.readFailed("Fixture Keychain read was denied.")
        let http = RoutingHTTPClient { request in
            guard request.url == CodexUsageClient.usageURL else { return Self.reusedTokenResponse }
            keychain.beforeRead = { _ in throw readError }
            return HTTPResponse(statusCode: 401, headers: [:], body: Data())
        }

        let snapshot = await makeProvider(store: store, http: http).refresh()

        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL])
        XCTAssertEqual(snapshot.errorCategory, .credentialAccess)
        XCTAssertEqual(snapshot.errorPresentation, UserFacingErrors.presentation(readError))
        XCTAssertNil(snapshot.liveQuotaObservedAt)
    }
}
