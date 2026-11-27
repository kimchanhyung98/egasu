import Foundation
import XCTest
@testable import Egasu

extension CodexCredentialPreservationTests {
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
