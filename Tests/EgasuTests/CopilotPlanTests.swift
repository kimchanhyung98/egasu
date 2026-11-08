import XCTest
@testable import Egasu

final class CopilotPlanTests: XCTestCase {
    @MainActor
    func testFreeRefreshPreservesQuotaLinesWithoutOrganizationBilling() async throws {
        var body = freeQuotaBody()
        body["access_type_sku"] = "free_limited_copilot"
        body["token_based_billing"] = true
        let http = FakeHTTPClient(response: HTTPResponse(
            statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body)
        ))
        let suiteName = "CopilotPlanTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let provider = CopilotProvider(
            authStore: CopilotAuthStore(
                files: FakeFiles([CopilotAuthStore.editorAppsPath: #"{"github.com":{"oauth_token":"gho_test"}}"#]),
                keychain: FakeKeychain()
            ),
            usageClient: CopilotUsageClient(http: http),
            orgBillingClient: CopilotOrgBillingClient(http: http),
            usageScanner: .init(databasePath: { nil }),
            sharedUsage: .init(collectors: []),
            defaults: defaults
        )

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.plan, "Free")
        XCTAssertEqual(snapshot.lines.map(\.label), ["Chat", "Completions"])
        XCTAssertEqual(http.requests.map(\.url.path), ["/copilot_internal/user"])
    }

    func testKnownFreeSKUChangesOnlyPlanLabel() throws {
        var body = freeQuotaBody()
        let baseline = try CopilotUsageMapper.map(body: body)
        body["access_type_sku"] = "free_limited_copilot"
        let response = HTTPResponse(statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))

        let mapped = try CopilotUsageMapper.map(response)

        XCTAssertEqual(mapped.plan, "Free")
        XCTAssertEqual(mapped.lines, baseline.lines)
        XCTAssertEqual(mapped.isOrgManagedSeat, baseline.isOrgManagedSeat)
        XCTAssertEqual(mapped.hasInvalidPersonalCredits, baseline.hasInvalidPersonalCredits)
    }

    func testIndividualWithoutKnownFreeSKUIsNotAssumedFree() throws {
        for sku in [nil, "unknown_sku"] as [String?] {
            var body = freeQuotaBody()
            if let sku { body["access_type_sku"] = sku }

            let mapped = try CopilotUsageMapper.map(body: body)

            XCTAssertEqual(mapped.plan, "Individual")
        }
    }

    func testKnownFreeSKUDoesNotRequirePlanName() throws {
        var body = freeQuotaBody()
        body.removeValue(forKey: "copilot_plan")
        body["access_type_sku"] = "free_limited_copilot"

        let mapped = try CopilotUsageMapper.map(body: body)

        XCTAssertEqual(mapped.plan, "Free")
    }

    func testOrganizationPlansAndCreditsSurviveMissingOrUnknownSKU() throws {
        for (plan, label) in [("business", "Business"), ("enterprise", "Enterprise")] {
            for sku in [nil, "unknown_sku"] as [String?] {
                var body: [String: Any] = [
                    "copilot_plan": plan,
                    "token_based_billing": true,
                    "quota_snapshots": [
                        "premium_interactions": ["entitlement": 0, "remaining": 0, "credits_used": 12]
                    ]
                ]
                if let sku { body["access_type_sku"] = sku }

                let mapped = try CopilotUsageMapper.map(body: body)

                XCTAssertEqual(mapped.plan, label)
                XCTAssertTrue(mapped.isOrgManagedSeat)
                XCTAssertFalse(mapped.hasInvalidPersonalCredits)
                XCTAssertEqual(mapped.lines, [.values(label: "Credits", values: [MetricValue(number: 12, kind: .count)])])
            }
        }
    }

    private func freeQuotaBody() -> [String: Any] {
        [
            "copilot_plan": "individual",
            "quota_snapshots": [
                "premium_interactions": ["entitlement": 0, "remaining": 0],
                "chat": ["entitlement": 200, "remaining": 180],
                "completions": ["entitlement": 2000, "remaining": 1900]
            ]
        ]
    }
}
