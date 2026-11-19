import Foundation
import XCTest
@testable import Egasu

final class ClaudeQuotaValidationTests: XCTestCase {
    func testPresentMalformedQuotaWindowIsAnErrorInsteadOfAnOmittedLimit() throws {
        let malformed: [Any] = [
            "unavailable", [], [:], ["utilization": "unavailable"], ["utilization": NSNull()],
            ["utilization": true], ["utilization": -1], ["utilization": "NaN"],
            ["utilization": 0, "resets_at": "invalid"], ["utilization": 0, "resets_at": true]
        ]
        for key in ["five_hour", "seven_day"] {
            for window in malformed {
                var body: [String: Any] = ["five_hour": ["utilization": 0], "seven_day": ["utilization": 20]]
                body[key] = window

                XCTAssertThrowsError(try map(body), "Malformed \(key) must not be silently dropped") {
                    XCTAssertEqual($0 as? ClaudeUsageError, .invalidResponse)
                }
            }
        }
    }

    func testAbsentOrNullOptionalWindowsRemainSupported() throws {
        for body: [String: Any] in [
            ["five_hour": ["utilization": 0]],
            [
                "five_hour": ["utilization": 0, "resets_at": NSNull()], "seven_day": NSNull(),
                "seven_day_sonnet": NSNull()
            ]
        ] {
            let usage = try map(body)
            XCTAssertEqual(usage.lines.map(\.label), ["Session"])
        }
    }

    func testNumericStringsAndUsageAboveOneHundredRemainValidAndExhausted() throws {
        let usage = try map([
            "five_hour": ["utilization": "0"],
            "seven_day": ["utilization": "105.5", "resets_at": 1_800_000_000]
        ])

        XCTAssertEqual(usage.lines.map(\.label), ["Session", "Weekly"])
        XCTAssertTrue(UsageTimerObservation.hasExhaustedQuota(usage.lines))
    }

    func testMalformedOptionalWeeklyBucketsKeepValidSiblingMeasurements() throws {
        let fable: [String: Any] = ["kind": "weekly_scoped", "scope": ["model": ["display_name": "Fable"]]]
        let malformed: [[String: Any]] = [
            ["seven_day_sonnet": ["utilization": true]],
            ["seven_day_sonnet": ["utilization": 10, "resets_at": "invalid"]],
            ["limits": "invalid"], ["limits": [fable]], ["limits": [["kind": "weekly_scoped"]]]
        ]
        for optional in malformed {
            let usage = try map(optional.merging(["seven_day": ["utilization": 95]]) { value, _ in value })
            XCTAssertEqual(usage.hasIncompleteWeeklyQuota, true)
            XCTAssertEqual(usage.lines.map(\.label), ["Weekly"])
        }
        for optional: [String: Any] in [[:], ["seven_day_sonnet": NSNull(), "limits": NSNull()], ["limits": []]] {
            let usage = try map(optional.merging(["seven_day": ["utilization": 12]]) { value, _ in value })
            XCTAssertNil(usage.hasIncompleteWeeklyQuota)
            XCTAssertEqual(usage.lines.map(\.label), ["Weekly"])
        }
    }

    @MainActor
    func testDuplicateFableDisplaysFirstValueWithoutDecidingWeeklyQuota() throws {
        let runtime = ClaudeProvider()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for percents in [[95, 10], [10, 95]] {
            let limits: [[String: Any]] = percents.map { percent in
                ["kind": "weekly_scoped", "scope": ["model": ["display_name": "Fable"]], "percent": percent]
            }
            let usage = try map(["seven_day": ["utilization": 25], "limits": limits])
            XCTAssertEqual(usage.hasIncompleteWeeklyQuota, true)
            XCTAssertEqual(
                usage.lines.first { $0.label == "Fable" },
                .progress(label: "Fable", used: Double(percents[0]), limit: 100, format: .percent))
            let snapshot = ProviderSnapshot.make(
                provider: runtime.provider, plan: nil, lines: usage.lines, refreshedAt: now,
                incompleteQuotaWindows: [.weekly], liveQuotaObservedAt: now)
            let reading = try XCTUnwrap(
                SoftLimitObservation.project(
                    snapshot: snapshot, descriptors: runtime.widgetDescriptors, window: .weekly, now: now))
            XCTAssertEqual(reading.quotaState(thresholdPercent: 90, at: now), .unknown)
            XCTAssertEqual(reading.quotaState(thresholdPercent: 25, at: now), .reached)
        }
    }

    private func map(_ body: [String: Any]) throws -> ClaudeMappedUsage {
        let response = HTTPResponse(
            statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
        return try ClaudeUsageMapper.mapUsageResponse(response, credentials: ClaudeOAuth())
    }
}
