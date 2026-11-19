import XCTest
@testable import Egasu

@MainActor
final class QuotaResetWindowTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func evaluate(
        _ evaluator: QuotaNotificationEvaluator,
        used: Double,
        reset: Date?,
        now: Date,
        family: String = "codex",
        period: TimeInterval? = 5 * 60 * 60,
        enabled: Set<PaceMilestone> = Set(PaceMilestone.allCases),
        hasData: Bool = true,
        deliverySucceeds: Bool = true
    ) async -> [String] {
        var posted: [String] = []
        let data = WidgetData(
            title: (period ?? 0) > 86_400 ? "Weekly" : "Session", icon: .providerMark(family),
            kind: .percent, used: used, limit: 100,
            resetsAt: reset, periodDurationMs: period.map { Int($0 * 1000) }, hasData: hasData
        )
        await evaluator.evaluate(
            metrics: [.init(key: "\(family).quota", providerID: family, data: data)],
            isOn: { enabled.contains($0) }, now: now, providerName: { $0 },
            post: { id, _, _, _, _ in
                posted.append(id); return deliverySucceeds
            }
        )
        return posted
    }

    func testMovingResetBeforeItsDueTimeDoesNotRepeatWarning() async {
        let evaluator = QuotaNotificationEvaluator()
        let reset = base.addingTimeInterval(1800)
        _ = await evaluate(evaluator, used: 60, reset: reset, now: base)
        let first = await evaluate(evaluator, used: 75, reset: reset, now: base)
        XCTAssertEqual(first, ["codex.healthyToClose"])
        let repeated = await evaluate(evaluator, used: 75, reset: reset.addingTimeInterval(600), now: base)
        XCTAssertTrue(repeated.isEmpty, "아직 초기화 시각 전이면 시각 연장만으로 같은 경고 반복 금지")
    }

    func testEarlyFullResetRearmsLevelAndPaceAlertsWithUnchangedOrExtendedTime() async {
        for family in ["codex", "claude"] {
            for period: TimeInterval in [5 * 60 * 60, week] {
                for extended in [false, true] {
                    let evaluator = QuotaNotificationEvaluator()
                    let oldReset = base.addingTimeInterval(period * 0.10)
                    _ = await evaluate(evaluator, used: 60, reset: oldReset, now: base, family: family, period: period)
                    let first = await evaluate(
                        evaluator, used: 95, reset: oldReset, now: base, family: family, period: period)
                    XCTAssertEqual(Set(first), ["\(family).underTenPercent", "\(family).closeToRunningOut"])

                    let reset = extended ? base.addingTimeInterval(period) : oldReset
                    _ = await evaluate(evaluator, used: 0, reset: reset, now: base, family: family, period: period)
                    let repeated = await evaluate(
                        evaluator, used: 95, reset: reset, now: base.addingTimeInterval(period * 0.02),
                        family: family, period: period
                    )
                    XCTAssertEqual(
                        Set(repeated), ["\(family).underTenPercent", "\(family).closeToRunningOut"],
                        "\(family), period=\(period), extended=\(extended): 실제 0% 회복 뒤 다시 소진되면 재알림")
                }
            }
        }
    }

    func testEarlyResetStartingANewWeeklyWindowRearmsUnusedReminder() async {
        let evaluator = QuotaNotificationEvaluator()
        let oldReset = base.addingTimeInterval(12 * 3600)
        _ = await evaluate(evaluator, used: 60, reset: oldReset, now: base, period: week, enabled: [.useItOrLoseIt])
        let first = await evaluate(
            evaluator, used: 40, reset: oldReset, now: base, period: week, enabled: [.useItOrLoseIt])
        XCTAssertEqual(first, ["codex.useItOrLoseIt"])
        let newReset = base.addingTimeInterval(week)
        _ = await evaluate(evaluator, used: 0, reset: newReset, now: base, period: week, enabled: [.useItOrLoseIt])
        let nextWindow = await evaluate(
            evaluator, used: 5, reset: newReset, now: newReset.addingTimeInterval(-12 * 3600),
            period: week, enabled: [.useItOrLoseIt]
        )
        XCTAssertEqual(nextWindow, ["codex.useItOrLoseIt"], "주간 기간까지 새로 시작되었다면 다음 초기화 전 알림도 필요")
    }

    func testDelayedResetTimestampRearmsOnlyTheNewWindowsUnusedReminder() async {
        let evaluator = QuotaNotificationEvaluator()
        let oldReset = base.addingTimeInterval(12 * 3600)
        let newReset = base.addingTimeInterval(week + 30)
        func read(_ used: Double, _ reset: Date, _ now: Date, hasData: Bool = true) async -> [String] {
            await evaluate(
                evaluator, used: used, reset: reset, now: now, period: week,
                enabled: [.critical, .useItOrLoseIt], hasData: hasData)
        }
        _ = await read(60, oldReset, base)
        let firstReminder = await read(40, oldReset, base)
        XCTAssertEqual(firstReminder, ["codex.useItOrLoseIt"])
        _ = await read(0, oldReset, base.addingTimeInterval(60))
        _ = await read(0, newReset, base.addingTimeInterval(90), hasData: false)
        let critical = await read(95, oldReset, base.addingTimeInterval(120))
        XCTAssertEqual(critical, ["codex.underTenPercent"])
        let missingPeriod = await evaluate(
            evaluator, used: 95, reset: newReset, now: base.addingTimeInterval(150),
            period: nil, enabled: [.critical, .useItOrLoseIt])
        XCTAssertTrue(missingPeriod.isEmpty)
        let confirmed = await read(95, newReset, base.addingTimeInterval(180))
        XCTAssertTrue(confirmed.isEmpty, "시각을 뒤늦게 확인해도 회복 후 이미 보낸 Critical 알림 유지")
        let next = await read(5, newReset, newReset.addingTimeInterval(-12 * 3600))
        XCTAssertEqual(next, ["codex.useItOrLoseIt"])
        let repeated = await read(5, newReset, newReset.addingTimeInterval(-11 * 3600))
        XCTAssertTrue(repeated.isEmpty)
    }

    func testSameWindowRecoveryDoesNotSuppressCriticalAfterNaturalRollover() async {
        let evaluator = QuotaNotificationEvaluator()
        let oldReset = base.addingTimeInterval(12 * 3600)
        _ = await evaluate(evaluator, used: 60, reset: oldReset, now: base, period: week)
        _ = await evaluate(evaluator, used: 0, reset: oldReset, now: base, period: week)
        let first = await evaluate(
            evaluator, used: 95, reset: oldReset, now: base.addingTimeInterval(60),
            period: week, enabled: [.critical])
        XCTAssertEqual(first, ["codex.underTenPercent"])
        let next = await evaluate(
            evaluator, used: 95, reset: oldReset.addingTimeInterval(week),
            now: oldReset.addingTimeInterval(60), period: week, enabled: [.critical])
        XCTAssertEqual(next, ["codex.underTenPercent"])
    }

    func testTimeExtensionAloneDoesNotRepeatPaceCriticalOrUnusedAlerts() async {
        for used in [40.0, 95.0] {
            let evaluator = QuotaNotificationEvaluator()
            let reset = base.addingTimeInterval(12 * 3600)
            _ = await evaluate(evaluator, used: 60, reset: reset, now: base, period: week)
            let first = await evaluate(evaluator, used: used, reset: reset, now: base, period: week)
            XCTAssertEqual(
                Set(first),
                used == 40
                    ? ["codex.useItOrLoseIt"]
                    : ["codex.underTenPercent", "codex.closeToRunningOut"])
            let repeated = await evaluate(
                evaluator, used: used, reset: reset.addingTimeInterval(600), now: base, period: week
            )
            XCTAssertTrue(repeated.isEmpty)
        }
    }

    func testRecoveryWithinTheSameWeeklyWindowDoesNotRepeatUnusedReminder() async {
        for recoveredUsed in [0.0, 20.0] {
            let evaluator = QuotaNotificationEvaluator()
            let reset = base.addingTimeInterval(12 * 3600)
            _ = await evaluate(evaluator, used: 60, reset: reset, now: base, period: week)
            let first = await evaluate(evaluator, used: 40, reset: reset, now: base, period: week)
            XCTAssertEqual(first, ["codex.useItOrLoseIt"])
            let recovered = await evaluate(evaluator, used: recoveredUsed, reset: reset, now: base, period: week)
            XCTAssertTrue(recovered.isEmpty, "같은 주간 기간의 사용량 회복은 미사용 알림을 반복하지 않음")
            let jittered = await evaluate(
                evaluator, used: recoveredUsed, reset: reset.addingTimeInterval(0.5), now: base, period: week
            )
            XCTAssertTrue(jittered.isEmpty)
            let extended = await evaluate(
                evaluator, used: recoveredUsed, reset: reset.addingTimeInterval(600), now: base, period: week
            )
            XCTAssertTrue(extended.isEmpty, "회복 없이 시각만 연장된 경우도 같은 기간 유지")
        }
    }

    func testPartialRecoveryRearmsPaceAndLevelsWithoutChangingWindow() async {
        for family in ["codex", "claude"] {
            let evaluator = QuotaNotificationEvaluator()
            let reset = base.addingTimeInterval(week * 0.10)
            _ = await evaluate(evaluator, used: 60, reset: reset, now: base, family: family, period: week)
            _ = await evaluate(evaluator, used: 95, reset: reset, now: base, family: family, period: week)
            _ = await evaluate(evaluator, used: 50, reset: reset, now: base, family: family, period: week)
            let repeated = await evaluate(evaluator, used: 95, reset: reset, now: base, family: family, period: week)
            XCTAssertEqual(Set(repeated), ["\(family).underTenPercent", "\(family).closeToRunningOut"])
        }
    }

    func testNoDataDoesNotRearmAlertsOrConsumeAnEarlyReset() async {
        let evaluator = QuotaNotificationEvaluator()
        let oldReset = base.addingTimeInterval(week * 0.10)
        let newReset = base.addingTimeInterval(week)
        _ = await evaluate(evaluator, used: 60, reset: oldReset, now: base, period: week)
        _ = await evaluate(evaluator, used: 95, reset: oldReset, now: base, period: week)
        let missing = await evaluate(evaluator, used: 0, reset: newReset, now: base, period: week, hasData: false)
        XCTAssertTrue(missing.isEmpty)
        let unchanged = await evaluate(evaluator, used: 95, reset: oldReset, now: base, period: week)
        XCTAssertTrue(unchanged.isEmpty, "데이터 없는 0은 회복으로 판단하지 않음")
        _ = await evaluate(evaluator, used: 0, reset: newReset, now: base, period: week)
        let repeated = await evaluate(
            evaluator, used: 95, reset: newReset, now: base.addingTimeInterval(week * 0.02), period: week
        )
        XCTAssertEqual(Set(repeated), ["codex.underTenPercent", "codex.closeToRunningOut"])
    }

    func testMissingPaceMetadataAtNonzeroUsageDoesNotRearmPace() async {
        let evaluator = QuotaNotificationEvaluator()
        let reset = base.addingTimeInterval(week * 0.10)
        _ = await evaluate(evaluator, used: 60, reset: reset, now: base, period: week)
        _ = await evaluate(evaluator, used: 95, reset: reset, now: base, period: week)
        let unpaced = await evaluate(evaluator, used: 95, reset: nil, now: base, period: nil)
        XCTAssertTrue(unpaced.isEmpty)
        let restored = await evaluate(evaluator, used: 95, reset: reset, now: base, period: week)
        XCTAssertTrue(restored.isEmpty)
    }

    func testExhaustionWithoutPaceMetadataOnlyFiresCritical() async {
        let reset = base.addingTimeInterval(1800)
        let contexts: [(Date?, TimeInterval?)] = [
            (nil, nil), (nil, 18_000), (reset, nil), (reset, 0), (reset, -1)
        ]
        for (reset, period) in contexts {
            let evaluator = QuotaNotificationEvaluator()
            _ = await evaluate(evaluator, used: 60, reset: reset, now: base, period: period)

            let spent = await evaluate(evaluator, used: 100, reset: reset, now: base, period: period)
            XCTAssertEqual(spent, ["codex.underTenPercent"], "초기화 시각과 양수 기간이 모두 있어야 속도 알림")
            let repeated = await evaluate(evaluator, used: 100, reset: reset, now: base, period: period)
            XCTAssertTrue(repeated.isEmpty)
        }
    }

    func testExhaustionWithPaceMetadataStillFiresPaceAndCritical() async {
        for family in ["codex", "claude"] {
            let evaluator = QuotaNotificationEvaluator()
            let reset = base.addingTimeInterval(1800)
            _ = await evaluate(evaluator, used: 60, reset: reset, now: base, family: family)

            let spent = await evaluate(evaluator, used: 100, reset: reset, now: base, family: family)
            XCTAssertEqual(spent, ["\(family).closeToRunningOut", "\(family).underTenPercent"])
            let repeated = await evaluate(evaluator, used: 100, reset: reset, now: base, family: family)
            XCTAssertTrue(repeated.isEmpty)
        }
    }

    func testMissingPaceMetadataAtExhaustionDoesNotConsumePaceTransition() async {
        let evaluator = QuotaNotificationEvaluator()
        let reset = base.addingTimeInterval(1800)
        _ = await evaluate(evaluator, used: 60, reset: reset, now: base)

        let unpaced = await evaluate(evaluator, used: 100, reset: nil, now: base, period: nil)
        XCTAssertEqual(unpaced, ["codex.underTenPercent"])
        let restored = await evaluate(evaluator, used: 100, reset: reset, now: base)
        XCTAssertEqual(restored, ["codex.closeToRunningOut"], "빠진 속도 정보가 돌아오면 기존 기준선에서 평가")
    }

    func testExhaustedFirstObservationOnlyPrimesWithOrWithoutPaceMetadata() async {
        for hasContext in [false, true] {
            let evaluator = QuotaNotificationEvaluator()
            let reset = hasContext ? base.addingTimeInterval(1800) : nil
            let period: TimeInterval? = hasContext ? 18_000 : nil

            let first = await evaluate(evaluator, used: 100, reset: reset, now: base, period: period)
            XCTAssertTrue(first.isEmpty)
            let repeated = await evaluate(evaluator, used: 100, reset: reset, now: base, period: period)
            XCTAssertTrue(repeated.isEmpty)
        }
    }

    func testRestoredPeriodDoesNotAlertForAnAlreadyExhaustedFirstObservation() async {
        let evaluator = QuotaNotificationEvaluator()
        let reset = base.addingTimeInterval(1800)
        let first = await evaluate(evaluator, used: 100, reset: reset, now: base, period: nil)
        XCTAssertTrue(first.isEmpty)

        let restored = await evaluate(evaluator, used: 100, reset: reset, now: base)
        XCTAssertTrue(restored.isEmpty, "기간 정보만 추가된 첫 소진 상태는 새 악화가 아님")
    }

    func testFirstKnownResetPreservesTheBaselineAndStillReportsNewExhaustion() async {
        for family in ["codex", "claude"] {
            for initialUsed in [50.0, 100] {
                let evaluator = QuotaNotificationEvaluator()
                _ = await evaluate(evaluator, used: initialUsed, reset: nil, now: base, family: family, period: nil)
                let reported = await evaluate(
                    evaluator, used: 100, reset: base.addingTimeInterval(3600), now: base,
                    family: family, period: 5 * 3600)
                let expected: Set<String> =
                    initialUsed == 100
                    ? []
                    : [
                        "\(family).closeToRunningOut", "\(family).underTenPercent"
                    ]
                XCTAssertEqual(Set(reported), expected, "\(family), first usage=\(initialUsed)")
            }
        }
    }

    func testNaturalRolloverRearmsEvenWhenZeroUsageWasNotObserved() async {
        for used in [40.0, 95.0] {
            let evaluator = QuotaNotificationEvaluator()
            let reset = base.addingTimeInterval(12 * 3600)
            _ = await evaluate(evaluator, used: 60, reset: reset, now: base, period: week)
            let first = await evaluate(evaluator, used: used, reset: reset, now: base, period: week)
            let nextReset = reset.addingTimeInterval(week)
            let repeated = await evaluate(
                evaluator, used: used, reset: nextReset, now: nextReset.addingTimeInterval(-12 * 3600), period: week
            )
            XCTAssertFalse(first.isEmpty)
            XCTAssertEqual(repeated, first)
        }
    }

    func testZeroRecoveryPreservesRetryAfterFailedDelivery() async {
        let evaluator = QuotaNotificationEvaluator()
        let reset = base.addingTimeInterval(1800)
        _ = await evaluate(evaluator, used: 60, reset: reset, now: base)
        _ = await evaluate(evaluator, used: 95, reset: reset, now: base)
        _ = await evaluate(evaluator, used: 0, reset: reset, now: base)
        let failed = await evaluate(evaluator, used: 95, reset: reset, now: base, deliverySucceeds: false)
        XCTAssertTrue(failed.contains("codex.closeToRunningOut"))
        let retried = await evaluate(evaluator, used: 95, reset: reset, now: base)
        XCTAssertEqual(Set(retried), ["codex.underTenPercent", "codex.closeToRunningOut"])
        let repeated = await evaluate(evaluator, used: 95, reset: reset, now: base)
        XCTAssertTrue(repeated.isEmpty)
    }

    func testRecoveryOfOneLimitDoesNotRearmOtherLimits() async {
        let evaluator = QuotaNotificationEvaluator()
        let reset = base.addingTimeInterval(1800)
        func evaluate(session: Double, weekly: Double) async -> [String] {
            let metrics = [("Session", session), ("Weekly", weekly)].map { title, used in
                QuotaNotificationEvaluator.Metric(
                    key: "claude.\(title)", providerID: "claude",
                    data: WidgetData(
                        title: title, icon: .providerMark("claude"), kind: .percent, used: used, limit: 100,
                        resetsAt: title == "Weekly" ? base.addingTimeInterval(week * 0.10) : reset,
                        periodDurationMs: title == "Weekly" ? Int(week * 1000) : 18_000_000
                    )
                )
            }
            var posted: [String] = []
            await evaluator.evaluate(
                metrics: metrics, isOn: { $0 == .closeToRunningOut }, now: base,
                providerName: { $0 },
                post: { _, _, subtitle, _, _ in
                    posted.append(subtitle)
                    return true
                })
            return posted
        }
        _ = await evaluate(session: 60, weekly: 60)
        let first = await evaluate(session: 95, weekly: 95)
        XCTAssertEqual(first.count, 2)
        _ = await evaluate(session: 0, weekly: 95)
        let repeated = await evaluate(session: 95, weekly: 95)
        XCTAssertEqual(repeated, [first[0]], "초기화되지 않은 주간 한도의 알림 기록 유지")
    }
}
