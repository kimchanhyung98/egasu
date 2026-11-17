import Foundation
import XCTest
@testable import Egasu

final class UsageTimerObservationTests: XCTestCase {
    private let observedAt = Date(timeIntervalSince1970: 1_800_000_000)

    func testCodexEmitsBothPeriodsForEachIndependentPool() throws {
        for sessionSlot in ["primary_window", "secondary_window"] {
            let weeklySlot = sessionSlot == "primary_window" ? "secondary_window" : "primary_window"
            let rate: [String: Any] = [
                sessionSlot: ["limit_window_seconds": 18_000, "used_percent": 0.1, "reset_at": 1_800_018_000],
                weeklySlot: ["limit_window_seconds": 604_800, "used_percent": 0, "reset_at": 1_800_604_800]
            ]
            let body: [String: Any] = ["rate_limit": rate, "additional_rate_limits": [
                ["limit_name": "GPT-5.3-Codex-Spark", "rate_limit": rate]
            ]]
            let observations = CodexUsageMapper.timerObservations(
                response: .init(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body)),
                accountKey: "account", observedAt: observedAt
            )
            XCTAssertEqual(Set(observations.map(\.timerID)), [
                "codex.default.weekly", "codex.default.session", "codex.spark.weekly", "codex.spark.session"
            ])
            XCTAssertEqual(Set(observations.map(\.storageKey)).count, 4)
            XCTAssertEqual(observations.first?.storageKey, "account", "Existing weekly record must stay readable")
            for observation in observations {
                let isSession = observation.timerID.hasSuffix(".session")
                XCTAssertEqual(observation.duration, isSession ? 18_000 : 604_800)
                XCTAssertEqual(observation.budgetWindow, isSession ? 18_000 : 86_400)
                XCTAssertEqual(observation.usedPercent, isSession ? 0.1 : 0)
                XCTAssertEqual(observation.rawResetAt, observedAt.addingTimeInterval(observation.duration))
            }
        }
    }

    @MainActor
    func testSessionBudgetExpiresIndependentlyOfOtherCodexTimers() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = UsageTimerAttemptStore(fileURL: directory.appendingPathComponent("attempts.json"))
        var observation = UsageTimerObservation(
            accountKey: "account", usedPercent: 0, resetsAt: nil, observedAt: observedAt,
            timerID: "codex.default.session", duration: 18_000
        )
        XCTAssertNotNil(try store.begin(accountKey: observation.storageKey, resetBefore: nil,
                                       now: observedAt, budgetWindow: observation.budgetWindow))
        XCTAssertNil(try store.begin(accountKey: observation.storageKey, resetBefore: nil,
                                    now: observedAt.addingTimeInterval(299), budgetWindow: observation.budgetWindow))
        XCTAssertNotNil(try store.begin(accountKey: observation.storageKey, resetBefore: nil,
                                       now: observedAt.addingTimeInterval(300), budgetWindow: observation.budgetWindow))
        let restarted = UsageTimerAttemptStore(fileURL: store.fileURL)
        XCTAssertFalse(try restarted.canAttempt(accountKey: observation.storageKey,
                                                now: observedAt.addingTimeInterval(17_999), budgetWindow: observation.budgetWindow))
        XCTAssertTrue(try restarted.canAttempt(accountKey: observation.storageKey,
                                               now: observedAt.addingTimeInterval(18_000), budgetWindow: observation.budgetWindow))
        for timerID in ["codex.default.weekly", "codex.spark.session", "codex.spark.weekly"] {
            observation.timerID = timerID
            observation.duration = timerID.hasSuffix(".weekly") ? 604_800 : 18_000
            XCTAssertTrue(try restarted.canAttempt(accountKey: observation.storageKey, now: observedAt,
                                                   budgetWindow: observation.budgetWindow), timerID)
        }
    }

    func testWeeklyWindowUsesExplicitDurationInEitherSlot() throws {
        for slot in ["primary_window", "secondary_window"] {
            let otherSlot = slot == "primary_window" ? "secondary_window" : "primary_window"
            let response = try response(rateLimit: [
                slot: ["limit_window_seconds": 604_800, "used_percent": 0],
                otherSlot: ["limit_window_seconds": 18_000, "used_percent": 73]
            ])

            let observation = try XCTUnwrap(observation(response))
            XCTAssertEqual(observation.accountKey, "account-key")
            XCTAssertEqual(observation.usedPercent, 0)
            XCTAssertEqual(observation.observedAt, observedAt)
        }
    }

    func testMissingUnknownOrAlmostWeeklyDurationIsNotEligible() throws {
        for duration: Any in [NSNull(), 18_000, 604_799, 604_800.001, false, "NaN", "Infinity"] {
            let response = try response(rateLimit: [
                "secondary_window": ["limit_window_seconds": duration, "used_percent": 0]
            ])
            XCTAssertNil(observation(response), "Unexpected duration: \(duration)")
        }
        XCTAssertNil(observation(try response(rateLimit: ["secondary_window": ["used_percent": 0]])))
    }

    func testHeadersCannotSupplyMissingWeeklyUsageOrDuration() throws {
        let headers = ["x-codex-secondary-used-percent": "0"]
        for rateLimit: [String: Any] in [
            [:],
            ["secondary_window": ["limit_window_seconds": 604_800]],
            ["secondary_window": ["used_percent": 0]]
        ] {
            XCTAssertNil(observation(try response(rateLimit: rateLimit, headers: headers)))
        }
    }

    func testSparkWeeklyWindowCannotReplaceTheDefaultBucket() throws {
        let body: [String: Any] = [
            "rate_limit": ["primary_window": ["limit_window_seconds": 18_000, "used_percent": 0]],
            "additional_rate_limits": [[
                "limit_name": "GPT-5.3-Codex-Spark",
                "rate_limit": ["secondary_window": ["limit_window_seconds": 604_800, "used_percent": 0]]
            ]]
        ]
        let response = HTTPResponse(
            statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body)
        )
        XCTAssertNil(observation(response))
    }

    func testTwoExplicitWeeklyWindowsAreAmbiguousEvenWhenTheirUsageMatches() throws {
        let weekly = ["limit_window_seconds": 604_800, "used_percent": 0]
        XCTAssertNil(observation(try response(rateLimit: ["primary_window": weekly, "secondary_window": weekly])))
    }

    func testFractionalUsageIsPreservedWithoutRoundingToZero() throws {
        let response = try response(rateLimit: [
            "secondary_window": ["limit_window_seconds": 604_800, "used_percent": 0.1]
        ])
        XCTAssertEqual(try XCTUnwrap(observation(response)).usedPercent, 0.1)
    }

    func testInvalidOrMissingUsageCannotBecomeZero() throws {
        for usage: Any in [false, true, "NaN", "Infinity", "-Infinity", "1e309", -0.1, 100.1, NSNull(), ""] {
            let response = try response(rateLimit: [
                "secondary_window": ["limit_window_seconds": 604_800, "used_percent": usage]
            ])
            XCTAssertNil(observation(response), "Unexpected usage: \(usage)")
        }
        XCTAssertNil(observation(try response(rateLimit: [
            "secondary_window": ["limit_window_seconds": 604_800]
        ])))
    }

    func testOnlySuccessfulHTTPResponsesProduceObservations() throws {
        for status in [199, 200, 299, 300, 304, 401, 429, 500] {
            let response = try response(
                rateLimit: ["secondary_window": ["limit_window_seconds": 604_800, "used_percent": 0]],
                status: status
            )
            XCTAssertEqual(observation(response) != nil, (200..<300).contains(status), "HTTP \(status)")
        }
    }

    func testResetDateUsesServerTimestampBeforeRelativeDuration() throws {
        let response = try response(rateLimit: [
            "secondary_window": [
                "limit_window_seconds": 604_800, "used_percent": 0,
                "reset_at": 1_800_012_345, "reset_after_seconds": 60
            ]
        ])
        XCTAssertEqual(observation(response)?.resetsAt, Date(timeIntervalSince1970: 1_800_012_345))
        XCTAssertEqual(observation(response)?.rawResetAt, Date(timeIntervalSince1970: 1_800_012_345))
    }

    func testResetDateUsesServerRelativeDurationAndNeverInventsAnAbsentDate() throws {
        let relative = try response(rateLimit: [
            "secondary_window": [
                "limit_window_seconds": 604_800, "used_percent": 0, "reset_after_seconds": 120
            ]
        ])
        XCTAssertEqual(observation(relative)?.resetsAt, observedAt.addingTimeInterval(120))
        XCTAssertNil(try XCTUnwrap(observation(relative)).rawResetAt)
        let missing = try response(rateLimit: [
            "secondary_window": ["limit_window_seconds": 604_800, "used_percent": 0]
        ])
        XCTAssertNil(try XCTUnwrap(observation(missing)).resetsAt)
        XCTAssertNil(try XCTUnwrap(observation(missing)).rawResetAt)
    }

    func testInvalidAbsoluteResetKeepsRelativeDisplayWithoutRawResetEvidence() throws {
        for reset: Any in [false, true, NSNull(), "NaN", "Infinity", "-Infinity", "1e309", ""] {
            let response = try response(rateLimit: [
                "secondary_window": [
                    "limit_window_seconds": 604_800, "used_percent": 0,
                    "reset_at": reset, "reset_after_seconds": 120
                ]
            ])
            let result = try XCTUnwrap(observation(response))
            XCTAssertNil(result.rawResetAt, "Invalid absolute reset must not become timer evidence: \(reset)")
            XCTAssertEqual(result.resetsAt, observedAt.addingTimeInterval(120))
        }
    }

    func testChangingRelativeResetNeverCreatesRawResetEvidence() throws {
        var displayDates: [Date] = []
        for remainingSeconds in [120, 119] {
            let response = try response(rateLimit: [
                "secondary_window": [
                    "limit_window_seconds": 604_800, "used_percent": 0,
                    "reset_after_seconds": remainingSeconds
                ]
            ])
            let result = try XCTUnwrap(observation(response))
            XCTAssertNil(result.rawResetAt)
            displayDates.append(try XCTUnwrap(result.resetsAt))
        }
        XCTAssertNotEqual(displayDates[0], displayDates[1])
    }

    func testAccountKeySurvivesTokenRotationWithoutPersistingRawIdentity() throws {
        let original = try auth(subject: "user-one", account: "workspace-one", tokenVersion: 1)
        let rotated = try auth(subject: "user-one", account: "workspace-one", tokenVersion: 2)
        let key = try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: original))

        XCTAssertEqual(CodexWeeklyTimerIdentity.accountKey(for: rotated), key)
        XCTAssertEqual(key.count, 64)
        XCTAssertTrue(key.allSatisfy(\.isHexDigit))
        XCTAssertFalse(key.contains("user-one"))
        XCTAssertFalse(key.contains("workspace-one"))
    }

    func testDifferentSubjectsAndWorkspacesHaveDifferentAccountKeys() throws {
        let first = try auth(subject: "user-one", account: "workspace-one")
        let otherUser = try auth(subject: "user-two", account: "workspace-one")
        let otherWorkspace = try auth(subject: "user-one", account: "workspace-two")
        let keys = try [first, otherUser, otherWorkspace].map {
            try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: $0))
        }
        XCTAssertEqual(Set(keys).count, 3)
    }

    func testWorkspaceCasingUsesTheCanonicalAccountIdentity() throws {
        let original = try auth(subject: "user-one", account: "workspace-one")
        var differentlyCased = original
        differentlyCased.tokens?.accountID = " WORKSPACE-ONE "
        differentlyCased.tokens?.idToken = try token(subject: "user-one", account: "Workspace-One")

        XCTAssertEqual(CodexWeeklyTimerIdentity.accountKey(for: differentlyCased),
                       try XCTUnwrap(CodexWeeklyTimerIdentity.accountKey(for: original)))
    }

    func testConflictingAccessAndIDTokenSubjectsRejectIdentity() throws {
        var auth = try auth(subject: "user-one", account: "workspace-one")
        auth.tokens?.idToken = try token(subject: "user-two", account: "workspace-one")
        XCTAssertNil(CodexWeeklyTimerIdentity.accountKey(for: auth))
    }

    func testConflictingWorkspaceClaimsRejectIdentity() throws {
        let original = try auth(subject: "user-one", account: "workspace-one")
        var accountMismatch = original
        accountMismatch.tokens?.accountID = "workspace-two"
        var idTokenMismatch = original
        idTokenMismatch.tokens?.idToken = try token(subject: "user-one", account: "workspace-two")
        var accessTokenMismatch = original
        accessTokenMismatch.tokens?.accessToken = try token(subject: "user-one", account: "workspace-two")

        for auth in [accountMismatch, idTokenMismatch, accessTokenMismatch] {
            XCTAssertNil(CodexWeeklyTimerIdentity.accountKey(for: auth))
        }
    }

    func testMissingIdentityAndAPIKeyOnlyCredentialsAreRejected() throws {
        let missingSubject = CodexAuth(tokens: CodexTokens(
            accessToken: try token(subject: nil, account: "workspace-one"), accountID: "workspace-one"
        ))
        let missingWorkspace = CodexAuth(tokens: CodexTokens(accessToken: try token(subject: "user-one", account: nil)))
        let missingAccess = CodexAuth(tokens: CodexTokens(
            idToken: try token(subject: "user-one", account: "workspace-one"), accountID: "workspace-one"
        ))
        let opaqueAccess = CodexAuth(tokens: CodexTokens(accessToken: "opaque", accountID: "workspace-one"))

        for auth in [missingSubject, missingWorkspace, missingAccess, opaqueAccess, CodexAuth(apiKey: "api-key")] {
            XCTAssertNil(CodexWeeklyTimerIdentity.accountKey(for: auth))
        }
    }

    private func observation(_ response: HTTPResponse) -> UsageTimerObservation? {
        CodexUsageMapper.weeklyTimerObservation(response: response, accountKey: "account-key", observedAt: observedAt)
    }

    private func response(
        rateLimit: [String: Any], status: Int = 200, headers: [String: String] = [:]
    ) throws -> HTTPResponse {
        HTTPResponse(
            statusCode: status, headers: headers,
            body: try JSONSerialization.data(withJSONObject: ["rate_limit": rateLimit])
        )
    }

    private func auth(subject: String, account: String, tokenVersion: Int = 1) throws -> CodexAuth {
        CodexAuth(tokens: CodexTokens(
            accessToken: try token(subject: subject, account: account, tokenVersion: tokenVersion),
            refreshToken: "refresh-\(tokenVersion)",
            idToken: try token(subject: subject, account: account, tokenVersion: tokenVersion),
            accountID: account
        ), lastRefresh: "refresh-time-\(tokenVersion)")
    }

    private func token(subject: String?, account: String?, tokenVersion: Int = 1) throws -> String {
        var payload: [String: Any] = ["jti": "token-\(tokenVersion)", "exp": 1_900_000_000 + tokenVersion]
        if let subject { payload["sub"] = subject }
        if let account { payload["https://api.openai.com/auth"] = ["chatgpt_account_id": account] }
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let encoded = data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "eyJhbGciOiJub25lIn0.\(encoded).signature-\(tokenVersion)"
    }
}
