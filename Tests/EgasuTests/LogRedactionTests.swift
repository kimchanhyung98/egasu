import XCTest
@testable import Egasu

/// never-log-secrets 회귀 방지 — 원본 Rust test vector를 그대로 이식해 regex 미세 divergence 검출
final class LogRedactionTests: XCTestCase {
    // MARK: - redactValue

    func testRedactValueShortIsFullyRedacted() {
        XCTAssertEqual(LogRedaction.redactValue("short"), "[REDACTED]")
        // 정확히 12자도 전체 redact (boundary: <= 12)
        XCTAssertEqual(LogRedaction.redactValue("abcdefghijkl"), "[REDACTED]")
    }

    func testRedactValueLongMasksEnds() {
        // 13자부터 first4...last4 — Rust `sk-1...cdef` vector와 동일
        XCTAssertEqual(LogRedaction.redactValue("sk-1234567890abcdef"), "sk-1...cdef")
        XCTAssertEqual(LogRedaction.redactValue("abcdefghijklm"), "abcd...jklm")
    }

    // MARK: - redactURL

    func testRedactURLSensitiveParamsOnly() {
        let url = "https://api.example.com/v1?api_key=sk-1234567890abcdef&other=value"
        let redacted = LogRedaction.redactURL(url)
        XCTAssertTrue(redacted.contains("api_key=sk-1...cdef"), redacted)
        XCTAssertTrue(redacted.contains("other=value"), redacted)
    }

    func testRedactURLUserParam() {
        let url = "https://cursor.com/api/usage?user=user_abcdefghijklmnopqrstuvwxyz&limit=10"
        let redacted = LogRedaction.redactURL(url)
        XCTAssertTrue(redacted.contains("user=user...wxyz"), redacted)
        XCTAssertTrue(redacted.contains("limit=10"), redacted)
    }

    func testRedactURLPreservesNonSensitiveParams() {
        let url = "https://api.example.com/v1?limit=10&offset=20"
        XCTAssertEqual(LogRedaction.redactURL(url), url)
    }

    func testRedactURLProfileArn() {
        let url = "https://q.us-east-1.amazonaws.com/getUsageLimits?profileArn=arn:aws:codewhisperer:us-east-1:699475941385:profile/EHGA3GRVQMUK&origin=AI_EDITOR"
        let redacted = LogRedaction.redactURL(url)
        XCTAssertFalse(redacted.contains("699475941385"), redacted)
        XCTAssertTrue(redacted.contains("origin=AI_EDITOR"), redacted)
    }

    func testRedactURLPreservesNameCaseAndSkipsEmptyValue() {
        let redacted = LogRedaction.redactURL("https://x.com/a?Api_Key=&Token=secretsecretsecret")
        XCTAssertTrue(redacted.contains("Api_Key="), redacted) // 빈 값은 그대로
        XCTAssertTrue(redacted.contains("Token=secr...cret"), redacted) // 이름 casing 보존
    }

    func testRedactURLNoQueryUnchanged() {
        XCTAssertEqual(LogRedaction.redactURL("https://api.example.com/v1"), "https://api.example.com/v1")
    }

    func testURLRemovesUserInfoAndFragmentAndMasksEncodedQueryNames() {
        let url = "https://private-user:private-password@example.invalid/usage?%74oken=SECRET&limit=10#private-fragment"
        XCTAssertEqual(LogRedaction.redactURL(url), "https://example.invalid/usage?%74oken=[REDACTED]&limit=10")
        XCTAssertEqual(LogRedaction.redactURL("invalid-private-url"), "[URL]")
    }

    // MARK: - redactLogMessage

    func testRedactLogMessageJWTAndBareApiKey() {
        let msg = "token=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U key=sk-1234567890abcdef"
        let redacted = LogRedaction.redactLogMessage(msg)
        XCTAssertFalse(redacted.contains("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9"), redacted)
        XCTAssertFalse(redacted.contains("sk-1234567890abcdef"), redacted)
    }

    func testRedactLogMessageDevinSession() {
        let msg = "auth=devin-session-token$abcdefghijklmnopqrstuvwxyz123456"
        let redacted = LogRedaction.redactLogMessage(msg)
        XCTAssertFalse(redacted.contains("devin-session-token$abcdefghijklmnopqrstuvwxyz123456"), redacted)
        XCTAssertTrue(redacted.contains("devi...3456"), redacted)
    }

    func testRedactLogMessageAccountEqAndPaths() {
        let msg = "keychain read: service=Claude Code-credentials, account=rebers path=/opt/homebrew/bin/bunx home=/Users/rebers/.claude"
        let redacted = LogRedaction.redactLogMessage(msg)
        XCTAssertFalse(redacted.contains("account=rebers"), redacted)
        XCTAssertFalse(redacted.contains("/opt/homebrew/bin/bunx"), redacted)
        XCTAssertFalse(redacted.contains("/Users/rebers/.claude"), redacted)
        XCTAssertTrue(redacted.contains("account=[REDACTED]"), redacted)
        XCTAssertTrue(redacted.contains("[PATH]"), redacted)
    }
}
