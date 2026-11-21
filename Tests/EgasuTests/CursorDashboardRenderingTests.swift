import SwiftUI
import XCTest
@testable import Egasu

extension DashboardSnapshotTests {
    func testCursorUnifiedWeeklyBillingRendersNormalizedDashboardRows() async throws {
        let now = Date()
        let http = RoutingHTTPClient { request in
            let json: String
            switch request.url {
            case CursorUsageClient.unifiedBalanceURL:
                json = #"{"usdRemainingCents":3750}"#
            case CursorUsageClient.usageStatusURL:
                json = #"{"availability":"available","monthlyUsage":{"usedCents":2350,"limitCents":10000}}"#
            default:
                XCTFail("Unexpected request: \(request.url)")
                return HTTPResponse(statusCode: 404, headers: [:], body: Data())
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(json.utf8))
        }
        let provider = CursorProvider(usageClient: CursorUsageClient(http: http))
        let payload = Data(#"{"exp":9999999999,"sub":"google-oauth2|fixture"}"#.utf8)
            .base64EncodedString().replacingOccurrences(of: "=", with: "")
        let cycleEnd = now.addingTimeInterval(3 * 86_400)
        let mapped = try await provider.mergedUsage(
            [
                "billingCycleStart": cycleEnd.addingTimeInterval(-7 * 86_400).timeIntervalSince1970 * 1_000,
                "billingCycleEnd": cycleEnd.timeIntervalSince1970 * 1_000,
                "planUsage": ["limit": 20_000, "totalSpend": 12_800]
            ],
            planName: "pro", token: "a.\(payload).c"
        )
        XCTAssertEqual(Set(http.requests.map(\.url)), [
            CursorUsageClient.unifiedBalanceURL, CursorUsageClient.usageStatusURL
        ])
        XCTAssertEqual(mapped.lines.map(\.label), ["Total usage", "Credits", "On-demand"])
        let snapshot = ProviderSnapshot(
            providerID: provider.provider.id, displayName: provider.provider.displayName,
            plan: mapped.plan, lines: mapped.lines)
        let ids = ["cursor.usage", "cursor.credits", "cursor.onDemand"]
        let lines = try ids.map { id in
            let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == id })
            return DashboardLine(
                descriptor: descriptor,
                data: WidgetDataResolver.resolve(
                    descriptor, snapshot: snapshot, codexResetWatch: .init(watch: nil, isAbsent: true)))
        }
        XCTAssertTrue(lines.allSatisfy { $0.data.hasData })
        XCTAssertEqual(lines[0].data.used, 64)
        XCTAssertEqual(lines[0].data.periodDurationMs, 7 * 86_400_000)
        XCTAssertEqual(lines[1].data.values.first?.number, 37.5)
        XCTAssertEqual(lines[2].data.used, 23.5)
        let account = DashboardAccount(
            provider: provider.provider, providerName: "Cursor", name: nil, lines: lines)
        XCTAssertEqual(account.lines.count, 3)
        let family = DashboardFamily(
            id: "cursor", provider: provider.provider, displayName: "Cursor", accounts: [account])
        try L10n.withLanguage(.english) {
            let view = DashboardProviderSection(family: family) { account in
                DashboardAccountRows(account: account, plan: snapshot.plan)
            }
            let image = try render(view, appearance: .dark, name: "cursor-unified-billing")
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 3)
        }
    }
}
