import XCTest

@testable import Egasu

@MainActor
final class SoftLimitObservationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var weekly: WidgetDescriptor {
        WidgetDescriptor.percent(id: "codex.weekly", provider: MockData.codex, title: "Weekly")
            .supportingSoftLimit(.weekly).exportingLimit("weekly", unit: "percent")
    }

    private var monthly: WidgetDescriptor {
        WidgetDescriptor.percent(id: "codex.monthly", provider: MockData.codex, title: "Monthly")
            .supportingSoftLimit(.monthly).exportingLimit("monthly", unit: "percent")
    }

    private func snapshot(_ lines: [MetricLine]) -> ProviderSnapshot {
        .init(providerID: "codex", displayName: "Codex", lines: lines, liveQuotaObservedAt: now)
    }

    private func projection(
        _ snapshot: ProviderSnapshot, window: SoftLimitWindowSelection = .all
    ) throws -> SoftLimitObservation {
        try XCTUnwrap(
            SoftLimitObservation.project(snapshot: snapshot, descriptors: [weekly, monthly], window: window, now: now)
        )
    }

    func testIndependentPeriodsExpireWithoutHidingAnotherFreshBreach() throws {
        let weekReset = now.addingTimeInterval(20)
        let monthReset = now.addingTimeInterval(120)
        let reading = try projection(
            snapshot([
                .progress(
                    label: "Weekly", used: 40, limit: 100, format: .percent,
                    resetsAt: weekReset, periodDurationMs: MetricPeriod.weekMs),
                .progress(
                    label: "Monthly", used: 90, limit: 100, format: .percent,
                    resetsAt: monthReset, periodDurationMs: MetricPeriod.monthMs)
            ]))

        XCTAssertEqual(reading.quotaState(thresholdPercent: 90, at: now.addingTimeInterval(-1)), .unknown)
        XCTAssertEqual(reading.maximumUsedFraction(at: now), 0.9)
        XCTAssertEqual(reading.nextExpiry(after: now), weekReset)
        XCTAssertEqual(reading.quotaState(thresholdPercent: 95, at: now), .belowLimit)
        XCTAssertEqual(reading.nextExpiry(after: weekReset), monthReset)
        XCTAssertEqual(reading.quotaState(thresholdPercent: 90, at: weekReset), .reached)
        XCTAssertEqual(reading.quotaState(thresholdPercent: 95, at: weekReset), .unknown)
        XCTAssertNil(reading.maximumUsedFraction(at: monthReset))
        XCTAssertEqual(reading.quotaState(thresholdPercent: 90, at: monthReset), .unknown)
    }

    func testAHistoryWarningDoesNotInvalidateQuotaButSelectedPartialQuotaDoes() throws {
        var value = snapshot([
            .progress(label: "Monthly", used: 90, limit: 100, format: .percent, periodDurationMs: MetricPeriod.monthMs)
        ])
        value.isDegraded = true
        value.warning = "Local usage history is unavailable."
        let normal = try projection(value)
        XCTAssertEqual(normal.quotaState(thresholdPercent: 91, at: now), .belowLimit)

        value.incompleteQuotaWindows = [.weekly]
        let partial = try projection(value)
        XCTAssertEqual(partial.quotaState(thresholdPercent: 90, at: now), .reached)
        XCTAssertEqual(partial.quotaState(thresholdPercent: 91, at: now), .unknown)
        XCTAssertEqual(try projection(value, window: .monthly).quotaState(thresholdPercent: 91, at: now), .belowLimit)
    }

    func testRateLimitWaitBlocksEvenRecentUsageUntilRetryTime() throws {
        var value = snapshot([
            .progress(label: "Weekly", used: 95, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
        ])
        let retryAt = now.addingTimeInterval(30)
        value.usageRetryAfter = retryAt
        XCTAssertNil(SoftLimitObservation.project(snapshot: value, descriptors: [weekly], window: .weekly, now: now))
        let resumed = try XCTUnwrap(
            SoftLimitObservation.project(snapshot: value, descriptors: [weekly], window: .weekly, now: retryAt))
        XCTAssertEqual(resumed.quotaState(thresholdPercent: 90, at: retryAt), .reached)
    }

    func testInvalidRealLimitCannotAuthorizeAnOtherwiseBelowLimitResult() throws {
        let value = snapshot([
            .progress(label: "Weekly", used: 0, limit: 0, format: .percent, periodDurationMs: MetricPeriod.weekMs),
            .progress(label: "Monthly", used: 90, limit: 100, format: .percent, periodDurationMs: MetricPeriod.monthMs)
        ])
        let partial = try projection(value)
        XCTAssertEqual(partial.quotaState(thresholdPercent: 90, at: now), .reached)
        XCTAssertEqual(partial.quotaState(thresholdPercent: 91, at: now), .unknown)
    }

    func testOptionalAbsentWindowIsNotAnInvalidReadingAndEstimatesCannotAuthorize() throws {
        let estimated = WidgetDescriptor.percent(id: "codex.model", provider: MockData.codex, title: "Model")
            .supportingSoftLimit(.weekly).exportingLimit("model", unit: "percent", estimated: true)
        let value = snapshot([
            .progress(label: "Weekly", used: 79, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs),
            .progress(label: "Model", used: 100, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
        ])
        let reading = try XCTUnwrap(
            SoftLimitObservation.project(
                snapshot: value, descriptors: [weekly, monthly, estimated], window: .all, now: now
            ))
        XCTAssertEqual(reading.quotaState(thresholdPercent: 80, at: now), .belowLimit)
        XCTAssertNil(
            SoftLimitObservation.project(snapshot: value, descriptors: [monthly, estimated], window: .all, now: now))
    }
}
