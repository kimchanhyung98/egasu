import XCTest
@testable import Egasu

final class PaceNotificationLogicTests: XCTestCase {
    private let reset = Date(timeIntervalSince1970: 1_700_000_000)

    private let healthy = WidgetData.MeterState.healthy(projectedFraction: 0.5)
    private let close = WidgetData.MeterState.closeToLimit(spare: "~5% spare", projectedFraction: 0.95)
    private let running = WidgetData.MeterState.runningOut(eta: nil, projectedFraction: 1.2)
    private let unpaced = WidgetData.MeterState.level(.normal)

    /// `fraction`은 남은 비율 — 기본 Priority 기준(Warning 30%, Critical 10%)으로 단계 계산.
    private func step(
        _ state: WidgetData.MeterState,
        fraction: Double = 0.9,
        resetsAt: Date? = nil,
        unusedNearReset: Bool = false,
        from previous: NotificationState = NotificationState(),
        now: Date? = nil
    ) -> PaceNotificationLogic.Transition {
        let now = now ?? reset.addingTimeInterval(-1800)
        let used = (1 - fraction) * 100
        let resetsAt = resetsAt ?? reset
        let change = PaceNotificationLogic.windowChange(
            from: previous, used: used, resetsAt: resetsAt, period: 7 * 86_400, now: now)
        return PaceNotificationLogic.transitions(
            state: state,
            severity: WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
                .severity,
            used: used,
            resetsAt: resetsAt,
            windowChange: change,
            hasPaceContext: true,
            unusedNearReset: unusedNearReset,
            previous: previous,
            now: now
        )
    }

    func testTheLevelsTurnOverExactlyWhereTheBarsChangeColor() {
        let primed = step(healthy, fraction: 0.31).newState
        XCTAssertEqual(step(healthy, fraction: 0.30, from: primed).fire, [.warning])
        let orange = step(healthy, fraction: 0.11, from: primed).newState
        XCTAssertEqual(step(healthy, fraction: 0.10, from: orange).fire, [.critical])
    }

    func testDroppingStraightUnderTenOffersBothLevelsLowestFirst() {
        let primed = step(healthy).newState
        XCTAssertEqual(step(healthy, fraction: 0.05, from: primed).fire, [.critical, .warning])
    }

    func testWillRunOutReArmsOnlyOnceThePaceEasesToNinetyPercent() {
        var state = step(running, from: step(healthy).newState).newState
        state.firedMilestones.insert(.closeToRunningOut)
        state = step(close, from: state).newState
        XCTAssertTrue(step(running, from: state).fire.isEmpty, "easing to 95% and back doesn't fire it again")
        state = step(healthy, from: state).newState
        XCTAssertEqual(step(running, from: state).fire, [.closeToRunningOut])
    }

    func testCriticalFiresOncePerWindow() {
        let primed = step(close, fraction: 0.50).newState
        var first = step(close, fraction: 0.08, from: primed)
        XCTAssertTrue(first.fire.contains(.critical))
        first.newState.firedMilestones.formUnion(first.fire)
        let again = step(close, fraction: 0.05, from: first.newState)
        XCTAssertFalse(again.fire.contains(.critical))
    }

    func testCriticalRearmsAfterRecoveryToWarningInTheSameWindow() {
        let primed = step(healthy, fraction: 0.50).newState
        var first = step(healthy, fraction: 0.10, from: primed)
        first.newState.firedMilestones.formUnion(first.fire)
        let recovered = step(healthy, fraction: 0.11, from: first.newState).newState
        XCTAssertEqual(step(healthy, fraction: 0.10, from: recovered).fire, [.critical])
    }

    func testColdStartPrimesWithoutFiring() {
        let first = step(running, fraction: 0.02)
        XCTAssertTrue(first.fire.isEmpty, "cold start primes, it doesn't fire")
        XCTAssertTrue(step(unpaced, fraction: 0.01).fire.isEmpty)
        XCTAssertTrue(step(unpaced, fraction: 0.99).fire.isEmpty)
        let recovered = step(healthy, fraction: 0.50, from: first.newState).newState
        let red = step(running, fraction: 0.02, from: recovered)
        XCTAssertTrue(red.fire.contains(.closeToRunningOut))
        XCTAssertTrue(red.fire.contains(.critical))
    }

    func testResetRolloverClearsFiredSetSoItCanFireAgain() {
        var state = step(healthy).newState
        state = step(running, from: state).newState
        state.firedMilestones.insert(.closeToRunningOut)
        XCTAssertTrue(step(running, from: state).fire.isEmpty)
        let newReset = reset.addingTimeInterval(3600)
        let rolled = step(healthy, resetsAt: newReset, from: state, now: reset).newState
        XCTAssertEqual(step(running, resetsAt: newReset, from: rolled).fire, [.closeToRunningOut])
    }

    func testResetJitterKeepsTheWindow() {
        var state = step(healthy).newState
        state = step(running, from: state).newState
        state.firedMilestones.insert(.closeToRunningOut)
        XCTAssertTrue(step(running, resetsAt: reset.addingTimeInterval(0.5), from: state, now: reset).fire.isEmpty)
    }

    func testRecoveryThenReworseningRefires() {
        var state = step(healthy).newState
        var orange = step(healthy, fraction: 0.25, from: state)
        orange.newState.firedMilestones.formUnion(orange.fire)
        state = step(running, fraction: 0.25, from: orange.newState).newState
        state = step(healthy, from: state).newState
        let again = step(healthy, fraction: 0.25, from: state)
        XCTAssertEqual(again.fire, [.warning], "recovering above Warning re-arms it")
        XCTAssertEqual(step(running, fraction: 0.25, from: again.newState).fire, [.closeToRunningOut])
    }

    func testUnpacedLimitFiresOnlyTheLevels() {
        let primed = step(unpaced, fraction: 0.20).newState
        let first = step(unpaced, fraction: 0.08, from: primed)
        XCTAssertEqual(first.fire, [.critical], "an unpaced limit has no Will Run Out")
    }

    func testNoDataDoesNotDisturbPreviousSignals() {
        var state = step(healthy).newState
        state = step(.noData, fraction: 0.5, from: state).newState
        XCTAssertEqual(step(healthy, fraction: 0.25, from: state).fire, [.warning])
    }

    func testUseItOrLoseItFiresOncePerWindowButNotOnLaunch() {
        let launched = step(healthy, unusedNearReset: true)
        XCTAssertTrue(launched.fire.isEmpty)
        XCTAssertTrue(step(healthy, unusedNearReset: true, from: launched.newState).fire.isEmpty, "already unused at launch")

        let primed = step(healthy).newState
        var first = step(healthy, unusedNearReset: true, from: primed)
        XCTAssertEqual(first.fire, [.useItOrLoseIt])
        first.newState.firedMilestones.formUnion(first.fire)
        XCTAssertTrue(step(healthy, unusedNearReset: true, from: first.newState).fire.isEmpty)
    }

    func testSavedSwitchesKeepTheirKeysThroughTheRename() {
        XCTAssertEqual(PaceMilestone.critical.settingKey, "openusage.notifications.underTenPercent")
        XCTAssertEqual(PaceMilestone.warning.settingKey, "openusage.notifications.healthyToClose")
        XCTAssertEqual(PaceMilestone.closeToRunningOut.settingKey, "openusage.notifications.closeToRunningOut")
        XCTAssertEqual(PaceMilestone.useItOrLoseIt.settingKey, "openusage.notifications.useItOrLoseIt")
    }
}
