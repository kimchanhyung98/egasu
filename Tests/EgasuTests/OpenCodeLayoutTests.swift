import XCTest
@testable import Egasu

final class OpenCodeLayoutTests: XCTestCase {
    private let metrics = [
        "opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend",
        "opencode.today", "opencode.yesterday", "opencode.last30"
    ]

    @MainActor
    func testAllMetricsEnabledByDefault() {
        let defaults = DefaultLayout.metricIDs(in: WidgetRegistry.from([OpenCodeProvider()]))
        for id in metrics {
            XCTAssertTrue(defaults.contains(id), "\(id) should be enabled by default")
        }
    }

    func testNothingPinnedByDefault() {
        XCTAssertFalse(
            DefaultLayout.pinnedMetricIDs.contains { $0.hasPrefix("opencode.") },
            "a freshly auto-enabled provider adds no menu-bar pins (matches Grok/Devin)"
        )
    }
}
