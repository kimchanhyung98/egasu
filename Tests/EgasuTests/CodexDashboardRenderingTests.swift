import SwiftUI
import XCTest
@testable import Egasu

extension DashboardSnapshotTests {
    func testCodexBusinessIndividualCreditsRenderOnlyOnTheAccountWithAReportedLimit() throws {
        let now = Date()
        let accountID = "codex@fixture"
        let runtime = CodexProvider(provider: CodexProvider.makeProvider(id: accountID))
        let body = Data("""
            {"plan_type":"business","rate_limit":{
                "primary_window":{"limit_window_seconds":604800,"used_percent":26},
                "secondary_window":{"limit_window_seconds":2592000,"used_percent":42}},
             "spend_control":{"individual_limit":{"unit":"credit","used":325,"limit":1000}}}
            """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(.init(statusCode: 200, headers: [:], body: body))
        let snapshot = ProviderSnapshot.make(provider: runtime.provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now)
        let rows = runtime.widgetDescriptors.map { descriptor in
            DashboardLine(descriptor: descriptor,
                          data: WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init()))
        }.filter { $0.data.hasData && $0.isVisible }
        XCTAssertEqual(rows.map(\.id), ["weekly", "monthly", "individualCredits"].map { "\(accountID).\($0)" })
        let descriptor = try XCTUnwrap(rows.last?.descriptor)
        let ordinary = ProviderSnapshot.make(provider: runtime.provider, plan: "Plus", lines: [], refreshedAt: now)
        let absent = WidgetDataResolver.resolve(descriptor, snapshot: ordinary, codexResetWatch: .init())
        XCTAssertFalse(DashboardLine(descriptor: descriptor, data: absent).isVisible)

        try L10n.withLanguage(.korean) {
            let account = DashboardAccount(provider: runtime.provider, providerName: "Codex", name: "Business", lines: rows)
            let family = DashboardFamily(id: "codex", provider: runtime.provider, displayName: "Codex", accounts: [account])
            let view = DashboardProviderSection(family: family) { account in
                DashboardAccountRows(account: account, plan: mapped.plan)
            }
            let image = try render(view, appearance: .dark, name: "codex-business-individual-credits")
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 3)
        }
    }
}
