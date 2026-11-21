import XCTest
@testable import Egasu

@MainActor
final class QuotaNotificationRetryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testFailedCriticalRetriesAfterWarningSucceeds() async {
        let evaluator = QuotaNotificationEvaluator()
        var attempts: [String] = []
        var delivered: [String] = []
        let post: QuotaNotificationEvaluator.Post = { id, _, _, _, isCurrent in
            guard isCurrent() else { return false }
            attempts.append(id)
            if id == "codex.underTenPercent", attempts.count == 1 { return false }
            delivered.append(id)
            return true
        }
        await evaluate(evaluator, used: 50, enabled: [.critical, .warning], post: post)
        await evaluate(evaluator, used: 95, enabled: [.critical, .warning], post: post)
        XCTAssertEqual(delivered, ["codex.healthyToClose"])
        await evaluate(evaluator, used: 95, enabled: [.critical, .warning], post: post)
        await evaluate(evaluator, used: 95, enabled: [.critical, .warning], post: post)
        XCTAssertEqual(attempts, ["codex.underTenPercent", "codex.healthyToClose", "codex.underTenPercent"])
        XCTAssertEqual(delivered, ["codex.healthyToClose", "codex.underTenPercent"])
    }

    func testDisabledLevelIsNotConsumedByTheOtherLevelDelivery() async {
        for initiallyEnabled in [PaceMilestone.critical, .warning] {
            let evaluator = QuotaNotificationEvaluator()
            var delivered: [String] = []
            let post: QuotaNotificationEvaluator.Post = { id, _, _, _, isCurrent in
                guard isCurrent() else { return false }
                delivered.append(id)
                return true
            }
            await evaluate(evaluator, used: 50, enabled: [initiallyEnabled], post: post)
            await evaluate(evaluator, used: 95, enabled: [initiallyEnabled], post: post)
            XCTAssertEqual(delivered, ["codex." + initiallyEnabled.rawValue])
            await evaluate(evaluator, used: 95, enabled: [.critical, .warning], post: post)
            await evaluate(evaluator, used: 95, enabled: [.critical, .warning], post: post)
            XCTAssertEqual(Set(delivered), ["codex.underTenPercent", "codex.healthyToClose"])
            XCTAssertEqual(delivered.count, 2)
        }
    }

    func testRecoveryNeedsExhaustionAndFreshReadingFromSameAccount() async {
        let evaluator = QuotaNotificationEvaluator()
        var delivered: [String] = []
        let post: QuotaNotificationEvaluator.Post = { id, _, _, _, current in
            guard current() else { return false }
            delivered.append(id)
            return true
        }
        for (used, account) in [
            (0.0, "a"), (100, "a"), (0, nil), (0, "b"), (100, "b"),
            (50, nil), (50, "b"), (45, "b")
        ] as [(Double, String?)] {
            await evaluate(evaluator, used: used, enabled: [.quotaRecovered], account: account, post: post)
        }
        XCTAssertEqual(delivered, ["codex.quotaRecovered"])
        await evaluate(evaluator, used: 100, enabled: [.quotaRecovered], account: "b", post: post)
        evaluator.reset(providerIDs: ["codex"])
        await evaluate(evaluator, used: 0, enabled: [.quotaRecovered], account: "b", post: post)
        XCTAssertEqual(delivered.count, 1)
    }

    private func evaluate(
        _ evaluator: QuotaNotificationEvaluator, used: Double, enabled: Set<PaceMilestone>, account: String? = nil,
        post: QuotaNotificationEvaluator.Post
    ) async {
        let data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        await evaluator.evaluate(
            metrics: [
                .init(
                    key: "codex.weekly", providerID: "codex", data: data,
                    recoveryReading: account.map { .init(account: $0, isExhausted: used >= 100) })
            ],
            isOn: { enabled.contains($0) }, now: now, providerName: { $0 }, post: post
        )
    }
}
