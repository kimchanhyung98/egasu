import Foundation
import XCTest
@testable import Egasu

@MainActor
final class CodexWeeklyTimerSendBudgetTests: XCTestCase {
    func testRepeatedMovingResetAndMissingVerificationAreBoundedAcrossRestart() async throws {
        for restart in [false, true] {
            let probe = try WeeklyTimerProbe(seedBaseline: false)
            defer { probe.cleanup() }
            probe.preparationReset = probe.start.addingTimeInterval(604_800)
            _ = try probe.store.observe(accountKey: "a", rawResetAt: probe.start.addingTimeInterval(86_400),
                                        observedAt: probe.start.addingTimeInterval(-600), usedPercent: 40)
            var coordinator = probe.coordinator()
            for index in 0..<288 {
                probe.now = probe.start.addingTimeInterval(Double(index) * 300)
                if restart {
                    await coordinator.shutdown()
                    coordinator = probe.coordinator()
                }
                coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                                    observation: probe.observation(reset: probe.now.addingTimeInterval(604_800)),
                                    checkUnconfirmedReset: index % 3 == 0)
                await settle(coordinator)
            }
            XCTAssertEqual(probe.executed.count, 2, "restart=\(restart)")
            XCTAssertTrue(probe.reports.compactMap { $0 }.contains { $0.contains("usage window") })
            await coordinator.shutdown()
        }
    }

    func testSuccessfulVerificationCannotBypassBudgetAtNextScheduledCheck() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(604_800)
        probe.executionHook = { _ in
            let reset = probe.now.addingTimeInterval(604_800)
            probe.verification = [probe.observation(reset: reset), probe.observation(reset: reset)]
        }
        let coordinator = probe.coordinator()
        for index in 0..<96 {
            probe.now = probe.start.addingTimeInterval(Double(index) * 900)
            coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                                observation: probe.observation(reset: probe.now.addingTimeInterval(604_800)),
                                checkUnconfirmedReset: true)
            await settle(coordinator)
        }
        XCTAssertEqual(probe.executed.count, 2)
        await coordinator.shutdown()
        probe.executionHook = nil
    }

    func testReservationsPersistAndAllowOnlyTwoAttemptsInAnyRollingDay() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        var reservations: [Date] = []
        for index in 0..<(2 * 288) {
            let now = probe.start.addingTimeInterval(Double(index) * 300)
            let restarted = UsageTimerAttemptStore(fileURL: probe.store.fileURL)
            if let attempt = try restarted.begin(accountKey: "a", resetBefore: nil, now: now) {
                reservations.append(attempt.attemptedAt)
            }
            XCTAssertLessThanOrEqual(reservations.filter { now.timeIntervalSince($0) < 86_400 }.count, 2)
        }
        XCTAssertEqual(reservations.count, 4)
        XCTAssertNotNil(try probe.store.begin(accountKey: "another-account", resetBefore: nil, now: probe.start))
    }

    func testFailedAndPendingAttemptsDoNotRefundBudget() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        var attempt = try XCTUnwrap(probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start))
        attempt.execution = .failed
        try probe.store.update(accountKey: "a", attempt: attempt)
        XCTAssertNotNil(try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(300)))
        XCTAssertNil(try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(600)))
        XCTAssertFalse(try probe.store.canAttempt(accountKey: "a", now: probe.start.addingTimeInterval(600)))
        XCTAssertNil(try probe.store.revalidationState(accountKey: "a", now: probe.start.addingTimeInterval(600)))
    }

    func testPrelaunchFailurePreservesEarlierSendAndCooldownAcrossRestart() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        var sent = try XCTUnwrap(probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start))
        sent.execution = .failed
        sent.messageLaunched = true
        try probe.store.update(accountKey: "a", attempt: sent)
        var notSent = try XCTUnwrap(probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(300)))
        notSent.execution = .failed
        notSent.messageLaunched = false
        try probe.store.update(accountKey: "a", attempt: notSent)

        let restarted = UsageTimerAttemptStore(fileURL: probe.store.fileURL)
        XCTAssertNil(try restarted.sendLimitResetsAt(accountKey: "a", now: probe.start.addingTimeInterval(599)))
        XCTAssertFalse(try restarted.canAttempt(accountKey: "a", now: probe.start.addingTimeInterval(599)))
        let next = try XCTUnwrap(restarted.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(600)))
        try restarted.update(accountKey: "a", attempt: notSent)
        XCTAssertEqual(try restarted.attempt(for: "a")?.id, next.id)
        XCTAssertEqual(try restarted.sendLimitResetsAt(accountKey: "a", now: probe.start.addingTimeInterval(900)),
                       probe.start.addingTimeInterval(86_400))
        XCTAssertNil(try restarted.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(900)))
    }

    func testLegacyAttemptsBlockForOneDayWithoutDiscardingConfirmation() throws {
        for version in [1, 2] {
            let probe = try WeeklyTimerProbe(seedBaseline: false)
            defer { probe.cleanup() }
            let attempt = try XCTUnwrap(probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start))
            let reset = probe.start.addingTimeInterval(604_800)
            _ = try probe.store.observe(accountKey: "a", rawResetAt: reset, observedAt: probe.start, usedPercent: 40)
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: probe.store.fileURL)) as? [String: Any])
            document["version"] = version
            document["sendHistory"] = nil
            try JSONSerialization.data(withJSONObject: document).write(to: probe.store.fileURL)
            let restarted = UsageTimerAttemptStore(fileURL: probe.store.fileURL)
            XCTAssertEqual(try restarted.attempt(for: "a")?.id, attempt.id)
            XCTAssertEqual(try restarted.sendLimitResetsAt(accountKey: "a", now: probe.start.addingTimeInterval(300)),
                           probe.start.addingTimeInterval(86_400))
            XCTAssertNil(try restarted.revalidationState(accountKey: "a", now: probe.start.addingTimeInterval(86_399)))
            XCTAssertEqual(try restarted.revalidationState(accountKey: "a", now: probe.start.addingTimeInterval(86_400))?.confirmedReset, reset)
        }
    }

    func testMissingOrTamperedHistoryFailsClosed() throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        _ = try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start)
        let saved = try Data(contentsOf: probe.store.fileURL)
        for value: [String: Any]? in [nil, [:], ["invalid-key": []]] {
            var document = try XCTUnwrap(JSONSerialization.jsonObject(with: saved) as? [String: Any])
            document["sendHistory"] = value
            let corrupt = try JSONSerialization.data(withJSONObject: document)
            try corrupt.write(to: probe.store.fileURL)
            XCTAssertThrowsError(try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(300)))
            XCTAssertEqual(try Data(contentsOf: probe.store.fileURL), corrupt)
        }
    }

    func testConfirmedStableTimerDoesNotShowLimitWarningOnScheduledRead() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        for offset: TimeInterval in [-700, -350] {
            _ = try probe.store.begin(accountKey: "a", resetBefore: nil, now: probe.start.addingTimeInterval(offset))
        }
        let reset = probe.start.addingTimeInterval(604_800)
        _ = try probe.store.observe(accountKey: "a", rawResetAt: reset,
                                    observedAt: probe.start.addingTimeInterval(-100), usedPercent: 10)
        let coordinator = probe.coordinator()
        coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                            observation: probe.observation(reset: reset), checkUnconfirmedReset: true)
        await settle(coordinator)
        XCTAssertTrue(probe.executed.isEmpty)
        XCTAssertTrue(probe.reports.isEmpty)
        await coordinator.shutdown()
    }

    func testStableTimerClearsLimitWarningWithoutReleasingBudget() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        for offset: TimeInterval in [-700, -350] {
            XCTAssertNotNil(try probe.store.begin(accountKey: "a", resetBefore: nil,
                                                 now: probe.start.addingTimeInterval(offset)))
        }
        let coordinator = probe.coordinator()
        let reset = probe.start.addingTimeInterval(604_800)
        let limitExpires = try XCTUnwrap(probe.store.sendLimitResetsAt(accountKey: "a", now: probe.now))

        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports.count, 1)
        let limitWarning = try XCTUnwrap(probe.reports.first ?? nil)
        XCTAssertTrue(limitWarning.contains("usage window"))

        probe.now = probe.now.addingTimeInterval(65)
        probe.receive(coordinator, reset: reset)
        XCTAssertEqual(probe.reports, [limitWarning, nil])
        XCTAssertEqual(try probe.store.sendLimitResetsAt(accountKey: "a", now: probe.now), limitExpires)

        probe.now = probe.now.addingTimeInterval(900)
        probe.receive(coordinator, reset: reset.addingTimeInterval(900))
        await settle(coordinator)
        XCTAssertEqual(probe.reports, [limitWarning, nil, limitWarning])
        XCTAssertEqual(try probe.store.sendLimitResetsAt(accountKey: "a", now: probe.now), limitExpires)
        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertTrue(probe.executed.isEmpty)
        await coordinator.shutdown()
    }

    func testReportedLimitsClearPerAccountAndRecoverPerTimer() async throws {
        let probe = try WeeklyTimerProbe(seedBaseline: false)
        defer { probe.cleanup() }
        try probe.add(providerID: "codex@other", accountKey: "b")
        let timers = [
            ("codex", "a", "codex.default.session"),
            ("codex", "a", "codex.spark.session"),
            ("codex@other", "b", "codex.default.session")
        ]
        func observation(accountKey: String, timerID: String, resetOffset: TimeInterval) -> UsageTimerObservation {
            var observation = probe.observation(accountKey: accountKey, reset: probe.start.addingTimeInterval(18_000 + resetOffset))
            observation.timerID = timerID
            observation.duration = 18_000
            return observation
        }
        for (_, accountKey, timerID) in timers {
            let baseline = observation(accountKey: accountKey, timerID: timerID, resetOffset: -300)
            _ = try probe.store.observe(accountKey: baseline.storageKey, rawResetAt: baseline.rawResetAt,
                                        observedAt: probe.start.addingTimeInterval(-1), usedPercent: 0)
            for offset: TimeInterval in [-700, -350] {
                XCTAssertNotNil(try probe.store.begin(accountKey: baseline.storageKey, resetBefore: nil,
                                                     now: probe.start.addingTimeInterval(offset),
                                                     budgetWindow: baseline.budgetWindow))
            }
        }
        let coordinator = probe.coordinator()
        func receiveAll(resetOffset: TimeInterval) {
            for (providerID, accountKey, timerID) in timers {
                coordinator.receive(
                    providerID: providerID, bindingID: probe.bindings[providerID]!,
                    observation: observation(accountKey: accountKey, timerID: timerID, resetOffset: resetOffset)
                )
            }
        }
        receiveAll(resetOffset: 0)
        XCTAssertEqual(probe.reports.count, 3)
        let warning = try XCTUnwrap(probe.reports.first ?? nil)
        XCTAssertTrue(warning.contains("usage window"))
        receiveAll(resetOffset: 100)
        XCTAssertEqual(probe.reports.count, 3, "Reporting one timer must not clear its sibling's suppression")

        coordinator.clearReportedSendLimit(for: "a")
        receiveAll(resetOffset: 200)
        XCTAssertEqual(probe.reports, [String?](repeating: warning, count: 5), "Other accounts keep their suppression")

        probe.now.addTimeInterval(65)
        coordinator.receive(
            providerID: "codex", bindingID: probe.bindings["codex"]!,
            observation: observation(accountKey: "a", timerID: "codex.default.session", resetOffset: 200)
        )
        XCTAssertEqual(probe.reports.last, .some(nil))
        receiveAll(resetOffset: 300)
        XCTAssertEqual(probe.reports, [String?](repeating: warning, count: 5) + [nil, warning],
                       "A recovered timer must not clear its sibling's suppression")
        for (_, accountKey, timerID) in timers {
            let current = observation(accountKey: accountKey, timerID: timerID, resetOffset: 300)
            XCTAssertNotNil(try probe.store.sendLimitResetsAt(accountKey: current.storageKey, now: probe.now,
                                                            budgetWindow: current.budgetWindow))
        }
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertTrue(probe.prepared.isEmpty)
        XCTAssertTrue(probe.executed.isEmpty)
        await coordinator.shutdown()
    }

    func testUncertainCompletionWithMovingVerificationCannotKeepSending() async throws {
        let probe = try WeeklyTimerProbe()
        defer { probe.cleanup() }
        probe.preparationReset = probe.start.addingTimeInterval(604_800)
        probe.result.completed = false
        probe.verificationHook = {
            probe.verification = [probe.observation(reset: probe.now.addingTimeInterval(604_800))]
        }
        let coordinator = probe.coordinator()
        for index in 0..<96 {
            probe.now = probe.start.addingTimeInterval(Double(index) * 900)
            coordinator.receive(providerID: "codex", bindingID: probe.bindings["codex"]!,
                                observation: probe.observation(reset: probe.now.addingTimeInterval(604_800)),
                                checkUnconfirmedReset: true)
            await settle(coordinator)
        }
        XCTAssertEqual(probe.executed.count, 2)
        await coordinator.shutdown()
        probe.verificationHook = nil
    }

    private func settle(_ coordinator: UsageTimerCoordinator<CodexWeeklyTimerSession>) async {
        for _ in 0..<500 {
            if !coordinator.hasPendingWork { return }
            await Task.yield()
        }
        XCTFail("Coordinator did not finish")
    }
}
