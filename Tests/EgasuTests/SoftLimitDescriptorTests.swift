import XCTest
@testable import Egasu

@MainActor
final class SoftLimitDescriptorTests: XCTestCase {
    func testDescriptorsRequireExplicitWindowOptIn() {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("fixture"))
        let descriptor = WidgetDescriptor.percent(id: "fixture.quota", provider: provider, title: "Quota")
        XCTAssertTrue(descriptor.softLimitWindows.isEmpty)
        XCTAssertEqual(descriptor.supportingSoftLimit(.weekly).softLimitWindows, [.weekly])
        XCTAssertEqual(descriptor.supportingSoftLimit(.weekly, .monthly).softLimitWindows, [.weekly, .monthly])
    }

    func testCatalogDeclaresOnlyWeeklyAndMonthlySubscriptionQuotaRows() {
        let descriptors = WidgetRegistry.from(ProviderCatalog.make()).descriptors
        let expected: [String: Set<SoftLimitWindow>] = [
            "claude.weekly": [.weekly],
            "claude.fable": [.weekly],
            "claude.sonnet": [.weekly],
            "codex.weekly": [.weekly],
            "codex.monthly": [.monthly],
            "codex.sparkWeekly": [.weekly],
            "codex.sparkMonthly": [.monthly],
            "cursor.usage": [.weekly, .monthly],
            "cursor.auto": [.weekly, .monthly],
            "cursor.api": [.weekly, .monthly],
            "cursor.requests": [.weekly, .monthly],
            "antigravity.geminiWeekly": [.weekly],
            "antigravity.claudeWeekly": [.weekly],
            "antigravity.argonWeekly": [.weekly],
            "copilot.premium": [.monthly],
            "copilot.chat": [.monthly],
            "copilot.completions": [.monthly],
            "devin.weekly": [.weekly],
            "grok.weekly": [.weekly],
            "grok.monthly": [.monthly],
            "kimi.weekly": [.weekly],
            "kimi.total": [.monthly],
            "kiro.credits": [.monthly],
            "opencode.weekly": [.weekly],
            "opencode.monthly": [.monthly],
            "qwencloud.weekly": [.weekly],
            "qwencloud.monthly": [.monthly],
            "zai.weekly": [.weekly],
            "zai.monthly": [.monthly],
            "zai.webSearches": [.weekly, .monthly]
        ]
        XCTAssertEqual(windows(descriptors), expected)
        let dstWeek = MetricPeriod.weekMs - 3_600_000
        XCTAssertEqual(
            Set(descriptors.filter { $0.supportsSoftLimit(.weekly, periodDurationMs: dstWeek) }.map(\.id)),
            ["cursor.usage", "cursor.auto", "cursor.api", "cursor.requests", "grok.weekly"])
        XCTAssertEqual(
            descriptors.filter { $0.supportsSoftLimit(.all, periodDurationMs: nil) }.map(\.id),
            ["kimi.total", "qwencloud.monthly"])
    }

    func testSnapshotAccountCardsDeclareTheSameQuotaWindowsAsTheirOwnProvider() {
        let cards = [
            AccountUsageSnapshotCard(id: "claude@profile-work", profileID: "work", family: "claude"),
            AccountUsageSnapshotCard(id: "codex@profile-work", profileID: "work", family: "codex")
        ]
        let registry = WidgetRegistry.from(ProviderCatalog.make(snapshotCards: cards))
        for card in cards {
            let primary = windows(registry.descriptors(for: card.family))
            let expected = Dictionary(
                uniqueKeysWithValues: primary.map { id, windows in
                    (card.id + id.dropFirst(card.family.count), windows)
                })
            XCTAssertEqual(windows(registry.descriptors(for: card.id)), expected)
        }
    }

    private func windows(_ descriptors: [WidgetDescriptor]) -> [String: Set<SoftLimitWindow>] {
        let eligible = descriptors.filter { !$0.softLimitWindows.isEmpty }
        return Dictionary(uniqueKeysWithValues: eligible.map { ($0.id, $0.softLimitWindows) })
    }
}
