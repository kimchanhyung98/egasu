import XCTest

@testable import Egasu

@MainActor
final class CodexPartialWindowTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMalformedSlotCannotConfirmBelowButKeepsReachedSibling() throws {
        for name in ["primary_window", "secondary_window"] {
            for invalid in ["false", "[]", "{}", #"{"used_percent":25,"limit_window_seconds":"bad"}"#] {
                try assertState(fields: "\"\(name)\":\(invalid)", threshold: 90, expected: .unknown)
                try assertState(fields: "\"\(name)\":\(invalid)", threshold: 20, expected: .reached)
            }
        }
    }

    func testAbsentAndExplicitlyUnrelatedWindowsAllowBelow() throws {
        for fields in [
            "", #""primary_window":null"#, #""secondary_window":null"#,
            #""secondary_window":{"limit_window_seconds":18000,"reset_at":"bad"}"#,
            #""primary_window":{"limit_window_seconds":86400,"reset_after_seconds":-1}"#
        ] {
            try assertState(fields: fields, threshold: 90, expected: .belowLimit)
        }
    }

    func testInvalidResetIsIsolatedToItsReportedPeriod() throws {
        for field in [#""reset_at":"invalid""#, #""reset_after_seconds":false"#, #""reset_after_seconds":-1"#] {
            let weekly = "\"primary_window\":{\"used_percent\":99,\"limit_window_seconds\":604800,\(field)}"
            try assertState(fields: weekly, threshold: 90, expected: .unknown)
            try assertState(fields: weekly, threshold: 20, expected: .reached)
            let monthly = "\"primary_window\":{\"used_percent\":99,\"limit_window_seconds\":2592000,\(field)}"
            try assertState(fields: monthly, threshold: 90, expected: .belowLimit)
            try assertState(fields: monthly, window: .monthly, threshold: 90, expected: .unknown)
            try assertState(fields: monthly, window: .monthly, threshold: 20, expected: .reached)
        }
        try assertState(
            fields: #""primary_window":{"used_percent":5,"limit_window_seconds":604800,"reset_after_seconds":null}"#,
            threshold: 90, expected: .belowLimit)
    }

    private func assertState(
        fields: String, window: SoftLimitWindowSelection = .weekly, threshold: Int, expected: SoftLimitQuotaState,
        file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let body = Data(
            """
            {"rate_limit":{\(fields)},"additional_rate_limits":[{"metered_feature":"spark","rate_limit":{
                "primary_window":{"used_percent":20,"limit_window_seconds":604800},
                "secondary_window":{"used_percent":20,"limit_window_seconds":2592000}
            }}]}
            """.utf8)
        let runtime = CodexProvider()
        let mapped = try CodexUsageMapper.mapUsageResponse(
            HTTPResponse(statusCode: 200, headers: [:], body: body), now: now)
        let snapshot = ProviderSnapshot.make(
            provider: runtime.provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now,
            incompleteQuotaWindows: mapped.incompleteQuotaWindows, liveQuotaObservedAt: now)
        let observation = try XCTUnwrap(
            SoftLimitObservation.project(
                snapshot: snapshot, descriptors: runtime.widgetDescriptors, window: window, now: now),
            file: file, line: line)
        XCTAssertEqual(
            observation.quotaState(thresholdPercent: threshold, at: now), expected, fields, file: file, line: line)
    }
}
