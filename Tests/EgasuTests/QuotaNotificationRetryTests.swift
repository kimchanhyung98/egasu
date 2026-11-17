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

    private func evaluate(
        _ evaluator: QuotaNotificationEvaluator, used: Double, enabled: Set<PaceMilestone>,
        post: QuotaNotificationEvaluator.Post
    ) async {
        let data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        await evaluator.evaluate(
            metrics: [.init(key: "codex.weekly", providerID: "codex", data: data)],
            isOn: { enabled.contains($0) }, now: now, providerName: { $0 }, post: post
        )
    }
}
