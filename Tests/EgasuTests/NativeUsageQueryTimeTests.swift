import Foundation
import XCTest
@testable import Egasu

final class NativeUsageQueryTimeTests: XCTestCase {
    func testCodexExcludesFutureRowsAfterCumulativeDeltasAndReevaluatesCachedRows() async throws {
        let now = try XCTUnwrap(EgasuISO8601.date(from: "2026-02-20T12:00:00Z"))
        let lines = [
            CodexLogFixture.turnContext(timestamp: "2026-02-20T11:59:58Z", model: "gpt-5.2"),
            CodexLogFixture.tokenCount(
                timestamp: "2026-02-20T12:00:00Z", totals: CodexLogFixture.usage(input: 10, output: 0)),
            CodexLogFixture.tokenCount(
                timestamp: "2026-02-20T12:00:01Z", totals: CodexLogFixture.usage(input: 100, output: 0)),
            CodexLogFixture.tokenCount(
                timestamp: "2026-02-20T11:59:59Z", totals: CodexLogFixture.usage(input: 120, output: 0))
        ].joined(separator: "\n")
        let home = try CodexLogFixture.makeHome(files: ["sessions/time.jsonl": lines])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = CodexLogFixture.scanner(home: home)

        for (query, tokens) in [(now, 30), (now.addingTimeInterval(1), 120), (now, 30)] {
            let result = await scanner.scan(now: query, pricing: .empty)
            let scan = try XCTUnwrap(result)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, tokens)
        }
    }

    func testClaudeExcludesFutureRowsBeforeDedupAndReevaluatesCachedRows() async throws {
        let now = try XCTUnwrap(EgasuISO8601.date(from: "2026-02-20T12:00:00Z"))
        let lines = [
            ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T12:00:01Z", input: 90, costUSD: 9,
                messageID: "message", requestID: "request"),
            ClaudeLogFixture.usageLine(
                timestamp: "2026-02-20T12:00:00Z", input: 10, costUSD: 1,
                messageID: "message", requestID: "request")
        ].joined(separator: "\n")
        let home = try ClaudeLogFixture.makeHome(files: ["time.jsonl": lines])
        defer { try? FileManager.default.removeItem(at: home) }
        let scanner = ClaudeLogFixture.scanner(home: home)

        for (query, tokens, cost) in [(now, 10, 1.0), (now.addingTimeInterval(1), 90, 9.0), (now, 10, 1.0)] {
            let result = await scanner.scan(now: query, pricing: .empty)
            let scan = try XCTUnwrap(result)
            XCTAssertEqual(scan.series.daily.first?.totalTokens, tokens)
            XCTAssertEqual(scan.series.daily.first?.costUSD, cost)
        }
    }
}
