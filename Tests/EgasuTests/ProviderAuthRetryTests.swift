import XCTest
@testable import Egasu

final class ProviderAuthRetryTests: XCTestCase {
    private enum SampleError: Error, Equatable {
        case authExpired
        case requestFailed(Int)
    }

    private func requireSuccess(status: Int) throws {
        let response = HTTPResponse(statusCode: status, headers: [:], body: Data())
        try ProviderAuthRetry.requireSuccess(
            response,
            authExpired: SampleError.authExpired,
            requestFailed: { SampleError.requestFailed($0) }
        )
    }

    @MainActor
    func testCancellationDuringEitherRequestKeepsItsOriginalCause() async {
        for duringRetry in [false, true] {
            for cause: any Error in [CancellationError(), URLError(.cancelled)] {
                var attempts = 0
                var refreshes = 0
                do {
                    _ = try await ProviderAuthRetry.fetch(
                        provider: "claude", resource: "profile", token: "original",
                        attempt: { _ in
                            attempts += 1
                            if duringRetry && attempts == 1 {
                                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
                            }
                            throw cause
                        },
                        refreshAccessToken: {
                            refreshes += 1
                            return "refreshed"
                        },
                        connectionFailed: SampleError.requestFailed(1),
                        retriedConnectionFailed: SampleError.requestFailed(2), authExpired: SampleError.authExpired
                    )
                    XCTFail("Cancelled request succeeded")
                } catch {
                    if cause is CancellationError {
                        XCTAssertTrue(error is CancellationError)
                    } else {
                        XCTAssertEqual((error as? URLError)?.code, .cancelled)
                    }
                }
                XCTAssertEqual(attempts, duringRetry ? 2 : 1)
                XCTAssertEqual(refreshes, duringRetry ? 1 : 0)
            }
        }
    }

    @MainActor
    func testTransportLogIdentifiesTheResourceAndAttemptWithoutRecordingRawErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sink = LogFile(directory: directory, fileName: "retry.log")
        sink.open()
        let previous = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.info)
        defer {
            AppLog.sink = previous
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }

        for duringRetry in [false, true] {
            var attempts = 0
            do {
                _ = try await ProviderAuthRetry.fetch(
                    provider: "claude", resource: "profile", token: "secret-original",
                    attempt: { _ in
                        attempts += 1
                        if duringRetry && attempts == 1 {
                            return HTTPResponse(statusCode: 403, headers: [:], body: Data())
                        }
                        throw URLError(.timedOut, userInfo: [NSLocalizedDescriptionKey: "secret-error"])
                    },
                    refreshAccessToken: { "secret-rotated" },
                    connectionFailed: SampleError.requestFailed(1),
                    retriedConnectionFailed: SampleError.requestFailed(2), authExpired: SampleError.authExpired
                )
                XCTFail("Failed request succeeded")
            } catch {
                XCTAssertEqual(error as? SampleError, .requestFailed(duringRetry ? 2 : 1))
            }
        }
        let log = try String(contentsOf: directory.appendingPathComponent("retry.log"), encoding: .utf8)
        XCTAssertTrue(log.contains("[auth:claude] OAuth resource=profile stage=initial category=network"))
        XCTAssertTrue(log.contains("[auth:claude] OAuth resource=profile stage=retry category=network"))
        XCTAssertTrue(log.contains("status=403 action=refresh"))
        XCTAssertFalse(log.contains("secret-"))
    }

    func testSuccessStatusesDoNotThrow() throws {
        for status in [200, 201, 204, 299] {
            try requireSuccess(status: status)
        }
    }

    func testUnauthorizedAndForbiddenThrowAuthExpired() {
        for status in [401, 403] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .authExpired)
            }
        }
    }

    func testOtherNon2xxThrowRequestFailedWithStatus() {
        for status in [400, 404, 429, 500, 503] {
            XCTAssertThrowsError(try requireSuccess(status: status)) { error in
                XCTAssertEqual(error as? SampleError, .requestFailed(status))
            }
        }
    }
}
