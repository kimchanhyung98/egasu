import Foundation
import XCTest
@testable import Egasu

@MainActor
final class UsageTimerCoverageTests: XCTestCase {
    func testSessionBudgetDoesNotBlockNextSessionOrAnotherProvider() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var observation = fixture.observation()
        let start = fixture.now
        XCTAssertNotNil(
            try fixture.store.begin(
                accountKey: observation.storageKey, resetBefore: nil,
                now: start, budgetWindow: observation.budgetWindow))
        XCTAssertNil(
            try fixture.store.begin(
                accountKey: observation.storageKey, resetBefore: nil,
                now: start.addingTimeInterval(299), budgetWindow: observation.budgetWindow))
        XCTAssertNotNil(
            try fixture.store.begin(
                accountKey: observation.storageKey, resetBefore: nil,
                now: start.addingTimeInterval(300), budgetWindow: observation.budgetWindow))
        let reloaded = UsageTimerAttemptStore(fileURL: fixture.store.fileURL)
        XCTAssertFalse(
            try reloaded.canAttempt(
                accountKey: observation.storageKey,
                now: start.addingTimeInterval(900), budgetWindow: observation.budgetWindow))
        XCTAssertTrue(
            try reloaded.canAttempt(
                accountKey: observation.storageKey,
                now: start.addingTimeInterval(18_000), budgetWindow: observation.budgetWindow))
        observation.timerID = "kimi.session"
        XCTAssertTrue(
            try reloaded.canAttempt(
                accountKey: observation.storageKey, now: start,
                budgetWindow: observation.budgetWindow))
    }

    func testMissingResetStartsOnceAndServerConfirmationSurvivesRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        fixture.receive(coordinator)
        await coordinator.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.sends, 1)
        XCTAssertEqual(fixture.verifications, 1, "A newly reported future Claude reset confirms the session")
        XCTAssertTrue(fixture.reports.last == nil || fixture.reports.last! == nil)
        let restarted = fixture.coordinator()
        fixture.now.addTimeInterval(901)
        fixture.receive(restarted)
        await restarted.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.sends, 1)
        fixture.now.addTimeInterval(18_000)
        fixture.receive(restarted)
        await restarted.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.sends, 2)
    }

    func testActiveSessionAndUnknownQuotaNeverSend() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let coordinator = fixture.coordinator()
        var active = fixture.observation()
        active.rawResetAt = fixture.now.addingTimeInterval(18_000)
        coordinator.receive(providerID: "claude", bindingID: fixture.binding, observation: active)
        await Task.yield()
        XCTAssertFalse(coordinator.hasPendingWork)
        XCTAssertEqual(fixture.sends, 0)
        XCTAssertNil(
            UsageTimerObservation.from(
                lines: [], accountKey: "a", timerID: "claude.session",
                observedAt: fixture.now, startRule: .missingReset))
    }

    func testPreparationErrorNeverReservesOrExecutesAndFreshObservationCanRecover() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.preparationFails = true
        let coordinator = fixture.coordinator()
        fixture.receive(coordinator)
        await coordinator.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.executions, 0)
        XCTAssertEqual(fixture.sends, 0)
        XCTAssertNil(try fixture.store.attempt(for: fixture.observation().storageKey))
        fixture.preparationFails = false
        fixture.receive(coordinator)
        await coordinator.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.sends, 1)
    }

    func testPrelaunchFailuresKeepCooldownWithoutConsumingMessageBudgetAcrossRestart() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.cannotLaunch = true
        for _ in 0..<3 {
            let coordinator = fixture.coordinator()
            fixture.receive(coordinator)
            await coordinator.waitForPendingWork(providerIDs: ["claude"])
            let key = fixture.observation().storageKey
            XCTAssertNotNil(
                try fixture.store.attempt(for: key), "Keep the cooldown after a confirmed prelaunch failure")
            XCTAssertNil(try fixture.store.sendLimitResetsAt(accountKey: key, now: fixture.now))
            XCTAssertFalse(try fixture.store.canAttempt(accountKey: key, now: fixture.now))
            fixture.now.addTimeInterval(301)
        }
        XCTAssertEqual(fixture.sends, 0)
        fixture.cannotLaunch = false
        let coordinator = fixture.coordinator()
        fixture.receive(coordinator)
        await coordinator.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.sends, 1)
    }

    func testAccountChangeBeforeLaunchKeepsReservationButDoesNotSend() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.changeBeforeLaunch = true
        let coordinator = fixture.coordinator()
        fixture.receive(coordinator)
        await coordinator.waitForPendingWork(providerIDs: ["claude"])
        XCTAssertEqual(fixture.sends, 0)
        XCTAssertNotNil(try fixture.store.attempt(for: fixture.observation().storageKey))
    }

    func testAntigravityUsesFourBucketsAndDoesNotSendToExhaustedPool() {
        let provider = AntigravityProvider()
        let lines: [MetricLine] = [
            .progress(
                label: "Session", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs),
            .progress(label: "Weekly", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs),
            .progress(label: "Claude", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs),
            .progress(
                label: "Claude Weekly", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
        ]
        let credentials = AntigravityKeychainToken(accessToken: "test", refreshToken: "identity", expiry: nil)
        provider.recordUsageTimer(lines: lines, credentials: credentials)
        XCTAssertEqual(provider.usageTimerObservations.count, 4)
        var exhausted = lines
        exhausted[1] = .progress(
            label: "Weekly", used: 100, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
        provider.recordUsageTimer(lines: exhausted, credentials: credentials)
        XCTAssertEqual(
            Set(provider.usageTimerObservations.map(\.timerID)),
            ["antigravity.other.weekly", "antigravity.other.session"])
    }

    func testZAIWeeklyPeriodNeverBecomesMessageCandidate() {
        let provider = ZAIProvider()
        provider.recordUsageTimer(
            lines: [
                .progress(
                    label: "Session", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.sessionMs),
                .progress(label: "Weekly", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
            ], apiKey: "test-key", observedAt: Date())
        XCTAssertEqual(provider.usageTimerObservations.map(\.timerID), ["zai.session"])
    }

    private struct Session: UsageTimerPreparedSession { var observation: UsageTimerObservation }

    @MainActor
    private final class Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store: UsageTimerAttemptStore
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let binding = UUID()
        var sends = 0
        var verifications = 0
        var reports: [String?] = []
        var current = true
        var changeBeforeLaunch = false
        var cannotLaunch = false
        var preparationFails = false
        var executions = 0

        init() throws { store = UsageTimerAttemptStore(fileURL: directory.appendingPathComponent("state.json")) }
        func remove() { try? FileManager.default.removeItem(at: directory) }
        func observation() -> UsageTimerObservation {
            .init(
                accountKey: "account", usedPercent: 0, resetsAt: nil, observedAt: now,
                timerID: "claude.session", duration: 18_000, startRule: .missingReset)
        }
        func receive(_ coordinator: UsageTimerCoordinator<Session>) {
            now.addTimeInterval(1)
            coordinator.receive(providerID: "claude", bindingID: binding, observation: observation())
        }
        func coordinator() -> UsageTimerCoordinator<Session> {
            UsageTimerCoordinator(
                store: store,
                isCurrent: { _, binding, account in self.current && binding == self.binding && account == "account" },
                prepare: { _, _ in
                    if self.preparationFails { throw UsageTimerError.usageUnavailable }
                    self.now.addTimeInterval(1); return Session(observation: self.observation())
                },
                execute: { _, _, _, canLaunch in
                    self.executions += 1
                    if self.cannotLaunch { return .init(launched: false, completed: false) }
                    if self.changeBeforeLaunch { self.current = false }
                    guard canLaunch() else { return .init(launched: false, completed: false) }
                    self.sends += 1
                    return .init(launched: true, completed: true)
                },
                verify: { _, _ in
                    self.verifications += 1
                    self.now.addTimeInterval(1)
                    var observation = self.observation()
                    observation.rawResetAt = self.now.addingTimeInterval(18_000)
                    return observation
                }, report: { _, _, _, message in self.reports.append(message) }, now: { self.now },
                wait: { self.now.addTimeInterval(Double($0.components.seconds)) }
            )
        }
    }
}
