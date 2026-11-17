import XCTest
@testable import Egasu

@MainActor
final class ServerIssueIconTests: XCTestCase {
    func testServerIssueIconPathHasVisibleBounds() {
        for size in [CGFloat(14), CGFloat(16)] {
            let path = ServerIssueIconShape().path(in: CGRect(x: 0, y: 0, width: size, height: size))

            XCTAssertFalse(path.isEmpty)
            XCTAssertGreaterThan(path.boundingRect.width, 0)
            XCTAssertGreaterThan(path.boundingRect.height, 0)
        }
    }

    func testServiceIssueAccessibilityValueNamesProviderSeverityAndComponent() {
        let issue = ProviderServiceIssue(
            severity: .partial,
            componentName: "Claude API (api.anthropic.com)",
            checkedAt: .distantPast
        )

        XCTAssertEqual(
            L10n.withLanguage(.english) { issue.accessibilityValue(providerName: "Claude") },
            "Claude reports a partial outage for Claude API (api.anthropic.com)."
        )
    }
}
