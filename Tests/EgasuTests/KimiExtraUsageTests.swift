import Foundation
import XCTest
@testable import Egasu

final class KimiExtraUsageTests: XCTestCase {
    func testUnfundedSnakeCaseWalletKeepsZeroUsageAndBalanceVisible() throws {
        let lines = try mapWallet([
            "balance": ["type": "BOOSTER", "unit": "UNIT_CURRENCY"],
            "monthlyUsed": ["currency": "USD", "priceInCents": "0"],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": "10000"]
        ])

        XCTAssertEqual(
            lines.first { $0.label == "Extra Usage" },
            .values(label: "Extra Usage", values: [MetricValue(number: 0, kind: .dollars)]))
        XCTAssertEqual(
            lines.first { $0.label == "Extra Balance" },
            .values(label: "Extra Balance", values: [MetricValue(number: 0, kind: .dollars)]))
    }

    func testCamelCaseWalletUsesDistinctUnitsForBalanceAndMonthlyCharges() throws {
        var wallet = fundedWallet()
        wallet["monthlyChargeLimitEnabled"] = true
        let lines = try mapWallet(wallet, key: "boosterWallet")

        XCTAssertEqual(
            lines.first { $0.label == "Extra Usage" },
            .progress(label: "Extra Usage", used: 12.34, limit: 100, format: .dollars))
        XCTAssertEqual(
            lines.first { $0.label == "Extra Balance" },
            .values(label: "Extra Balance", values: [MetricValue(number: 5.67, kind: .dollars)]))
    }

    func testDisabledSpendingCapLeavesActualUsageUnbounded() throws {
        var wallet = fundedWallet()
        wallet["monthlyChargeLimitEnabled"] = false
        let lines = try mapWallet(wallet)

        XCTAssertEqual(
            lines.first { $0.label == "Extra Usage" },
            .values(label: "Extra Usage", values: [MetricValue(number: 12.34, kind: .dollars)]))
    }

    func testSnakeCaseWalletTakesPrecedenceIncludingExplicitNull() throws {
        var root = quotaPayload()
        root["boosterWallet"] = fundedWallet()
        root["booster_wallet"] = ["balance": ["type": "BOOSTER"]]
        let lines = try KimiUsageMapper.map(root).lines
        XCTAssertEqual(
            lines.first { $0.label == "Extra Balance" },
            .values(label: "Extra Balance", values: [MetricValue(number: 0, kind: .dollars)]))

        root["booster_wallet"] = NSNull()
        XCTAssertEqual(try KimiUsageMapper.map(root).lines.map(\.label), ["Session"])
    }

    func testMissingNullAndOtherBalanceTypesDoNotInventAnExtraWallet() throws {
        XCTAssertEqual(try KimiUsageMapper.map(quotaPayload()).lines.map(\.label), ["Session"])
        XCTAssertEqual(try mapWallet(NSNull()).map(\.label), ["Session"])
        XCTAssertEqual(try mapWallet(["balance": NSNull()]).map(\.label), ["Session"])
        XCTAssertEqual(try mapWallet(["balance": ["type": "SUBSCRIPTION"]]).map(\.label), ["Session"])
    }

    func testNullWalletFieldsKeepTheQuotaAndUseTheSameDefaultsAsOmittedFields() throws {
        let minimalWallet = ["balance": ["type": "BOOSTER"]]
        let expected = try mapWallet(minimalWallet)
        for money in [NSNull() as Any, ["currency": NSNull(), "priceInCents": NSNull()] as Any] {
            let wallet: [String: Any] = [
                "balance": ["type": "BOOSTER", "amountLeft": NSNull()],
                "monthlyUsed": money,
                "monthlyChargeLimit": money,
                "monthlyChargeLimitEnabled": NSNull()
            ]
            XCTAssertEqual(try mapWallet(wallet), expected)
        }
    }

    func testNullCurrencyKeepsTheCurrencyOfTheOtherAmount() throws {
        var wallet = fundedWallet(currency: "CNY")
        wallet["monthlyChargeLimitEnabled"] = true
        let expected = try mapWallet(wallet)
        wallet["monthlyUsed"] = ["currency": NSNull(), "priceInCents": "1234"]
        XCTAssertEqual(try mapWallet(wallet), expected)
    }

    func testExplicitZeroSpendingCapIsNotUnlimited() throws {
        let lines = try mapWallet([
            "balance": ["type": "BOOSTER", "amountLeft": "0"],
            "monthlyUsed": ["currency": "USD", "priceInCents": 0],
            "monthlyChargeLimit": ["currency": "USD", "priceInCents": 0],
            "monthlyChargeLimitEnabled": true
        ])

        XCTAssertEqual(
            lines.first { $0.label == "Extra Usage" },
            .progress(label: "Extra Usage", used: 0, limit: 0, format: .dollars))
    }

    func testNonDollarWalletPreservesCurrencyAndItsSpendingCap() throws {
        var wallet = fundedWallet(currency: "CNY")
        wallet["monthlyChargeLimitEnabled"] = true
        let lines = try mapWallet(wallet)

        XCTAssertEqual(
            lines.first { $0.label == "Extra Usage" },
            .badge(label: "Extra Usage", text: "CNY 12.34 / CNY 100.00"))
        XCTAssertEqual(
            lines.first { $0.label == "Extra Balance" },
            .badge(label: "Extra Balance", text: "CNY 5.67"))
    }

    func testNonDollarUnboundedUsageHasNoInventedDollarValue() throws {
        let lines = try mapWallet(fundedWallet(currency: "CNY"))

        XCTAssertEqual(
            lines.first { $0.label == "Extra Usage" },
            .badge(label: "Extra Usage", text: "CNY 12.34"))
        XCTAssertEqual(
            lines.first { $0.label == "Extra Balance" },
            .badge(label: "Extra Balance", text: "CNY 5.67"))
    }

    @MainActor
    func testNonDollarExtraUsageKeepsCurrencyInMenuBarAfterResolution() throws {
        for capped in [false, true] {
            var wallet = fundedWallet(currency: "CNY")
            wallet["monthlyChargeLimitEnabled"] = capped
            var data = try resolvedExtraUsage(wallet)
            let expected = capped ? "CNY 12.34 / CNY 100.00" : "CNY 12.34"

            XCTAssertTrue(data.hasData)
            XCTAssertNil(data.limit)
            XCTAssertFalse(data.isBounded)
            for mode in [WidgetDisplayMode.used, .remaining] {
                data.displayMode = mode
                XCTAssertEqual(data.menuBarValue, expected)
            }
        }
    }

    @MainActor
    func testZeroDollarCapKeepsItsExplicitCapInMenuBarAfterResolution() throws {
        for (cents, expected) in [(0, "$0.00 / $0.00"), (1234, "$12.34 / $0.00")] {
            var wallet = fundedWallet()
            wallet["monthlyUsed"] = ["currency": "USD", "priceInCents": cents]
            wallet["monthlyChargeLimit"] = ["currency": "USD", "priceInCents": 0]
            wallet["monthlyChargeLimitEnabled"] = true
            var data = try resolvedExtraUsage(wallet)

            XCTAssertTrue(data.hasData)
            XCTAssertNil(data.limit)
            XCTAssertFalse(data.isBounded)
            for mode in [WidgetDisplayMode.used, .remaining] {
                data.displayMode = mode
                XCTAssertEqual(data.menuBarValue, expected)
            }
        }
    }

    @MainActor
    func testPositiveDollarCapKeepsReportedLimitAfterResolution() throws {
        var wallet = fundedWallet()
        wallet["monthlyChargeLimit"] = ["currency": "USD", "priceInCents": 25000]
        wallet["monthlyChargeLimitEnabled"] = true
        let data = try resolvedExtraUsage(wallet)

        XCTAssertTrue(data.hasData)
        XCTAssertTrue(data.isBounded)
        XCTAssertEqual(data.used, 12.34)
        XCTAssertEqual(data.limit, 250)
        XCTAssertNil(data.valueTextOverride)
    }

    @MainActor
    func testDollarWalletExportsUsageAndBalanceScalarsInUSD() throws {
        for capped in [false, true] {
            var wallet = fundedWallet()
            wallet["monthlyChargeLimitEnabled"] = capped
            let resources = try exportedResources(wallet)
            let usage = try XCTUnwrap(resources["extraUsage"] as? [String: Any])
            let balance = try XCTUnwrap(resources["extraUsageBalance"] as? [String: Any])

            XCTAssertEqual(usage["kind"] as? String, "consumption")
            XCTAssertEqual(usage["unit"] as? String, "usd")
            XCTAssertEqual(usage["used"] as? Double, 12.34)
            XCTAssertEqual(balance["kind"] as? String, "balance")
            XCTAssertEqual(balance["unit"] as? String, "usd")
            XCTAssertEqual(balance["available"] as? Double, 5.67)
        }
    }

    @MainActor
    func testZeroDollarCapExportsReportedUsageAndZeroLimit() throws {
        for cents in [0, 1234] {
            var wallet = fundedWallet()
            wallet["monthlyUsed"] = ["currency": "USD", "priceInCents": cents]
            wallet["monthlyChargeLimit"] = ["currency": "USD", "priceInCents": 0]
            wallet["monthlyChargeLimitEnabled"] = true
            let resources = try exportedResources(wallet)
            let usage = try XCTUnwrap(resources["extraUsage"] as? [String: Any])

            XCTAssertEqual(usage["unit"] as? String, "usd")
            XCTAssertEqual(usage["used"] as? Double, Double(cents) / 100)
            XCTAssertEqual(usage["limit"] as? Double, 0)
            XCTAssertEqual(usage["remaining"] as? Double, 0)
            XCTAssertNil(usage["utilization"])
        }
    }

    @MainActor
    func testNonDollarWalletDoesNotExportDollarResources() throws {
        for capped in [false, true] {
            var wallet = fundedWallet(currency: "CNY")
            wallet["monthlyChargeLimitEnabled"] = capped
            let resources = try exportedResources(wallet)

            XCTAssertNotNil(resources["session"])
            XCTAssertNil(resources["extraUsage"])
            XCTAssertNil(resources["extraUsageBalance"])
        }
    }

    func testMissingCurrencyUsesOfficialDollarDefaultButConflictingCurrenciesFail() throws {
        var wallet = fundedWallet()
        wallet["monthlyUsed"] = ["priceInCents": 1234]
        wallet["monthlyChargeLimit"] = ["priceInCents": 10000]
        XCTAssertEqual(
            try mapWallet(wallet).first { $0.label == "Extra Usage" },
            .values(label: "Extra Usage", values: [MetricValue(number: 12.34, kind: .dollars)]))

        wallet["monthlyUsed"] = ["currency": "CNY", "priceInCents": 1234]
        wallet["monthlyChargeLimit"] = ["currency": "USD", "priceInCents": 10000]
        assertInvalid(wallet)
    }

    func testNegativeBalancePreservesActualDebtWithoutChangingUsage() throws {
        var wallet = fundedWallet()
        wallet["balance"] = ["type": "BOOSTER", "amountLeft": "-50000000"]

        XCTAssertEqual(
            try mapWallet(wallet).first { $0.label == "Extra Balance" },
            .values(label: "Extra Balance", values: [MetricValue(number: -0.5, kind: .dollars)]))
    }

    func testPresentMalformedMoneyDoesNotBecomeZero() {
        let invalid: [Any] = [true, "invalid", "NaN", Double.infinity, -1, 0.5]
        for value in invalid {
            var wallet = fundedWallet()
            wallet["monthlyUsed"] = ["currency": "USD", "priceInCents": value]
            assertInvalid(wallet)
        }
        var wallet = fundedWallet()
        wallet["monthlyChargeLimitEnabled"] = true
        wallet["monthlyChargeLimit"] = ["currency": "USD", "priceInCents": -100]
        assertInvalid(wallet)
        for value: Any in [true, "invalid", Double.infinity, 0.5] {
            wallet = fundedWallet()
            wallet["balance"] = ["type": "BOOSTER", "amountLeft": value]
            assertInvalid(wallet)
        }
    }

    func testMalformedWalletAndMoneyContainersSurfaceInvalidResponse() {
        assertInvalid("invalid")
        assertInvalid(["balance": "invalid"])
        var wallet = fundedWallet()
        wallet["monthlyUsed"] = "invalid"
        assertInvalid(wallet)
        wallet = fundedWallet()
        wallet["monthlyChargeLimitEnabled"] = "true"
        assertInvalid(wallet)
    }

    private func quotaPayload() -> [String: Any] {
        ["usages": ["limit_5h": ["used_ratio": 0.25]]]
    }

    private func fundedWallet(currency: String = "USD") -> [String: Any] {
        [
            "balance": [
                "type": "BOOSTER", "amount": "1000000000", "amountLeft": "567000000",
                "periodEnd": "2099-12-31T00:00:00Z"
            ],
            "monthlyUsed": ["currency": currency, "priceInCents": "1234"],
            "monthlyChargeLimit": ["currency": currency, "priceInCents": "10000"]
        ]
    }

    private func mapWallet(_ wallet: Any, key: String = "booster_wallet") throws -> [MetricLine] {
        var root = quotaPayload()
        root[key] = wallet
        return try KimiUsageMapper.map(root).lines
    }

    @MainActor
    private func resolvedExtraUsage(_ wallet: [String: Any]) throws -> WidgetData {
        let suite = "EgasuTests.KimiExtraUsage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = KimiProvider()
        let registry = WidgetRegistry.from([provider])
        let store = WidgetDataStore(
            registry: registry, providers: [],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
        )
        store.snapshots[provider.provider.id] = ProviderSnapshot(
            providerID: provider.provider.id, displayName: provider.provider.displayName,
            lines: try mapWallet(wallet)
        )
        return store.data(for: try XCTUnwrap(registry.descriptor(id: "kimi.extra")))
    }

    @MainActor
    private func exportedResources(_ wallet: [String: Any]) throws -> [String: Any] {
        let provider = KimiProvider()
        let now = Date(timeIntervalSince1970: 2_000)
        let snapshot = ProviderSnapshot(
            providerID: provider.provider.id, displayName: provider.provider.displayName,
            lines: try mapWallet(wallet), refreshedAt: now
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: [provider.provider.id], knownIDs: [provider.provider.id],
            snapshots: [provider.provider.id: snapshot],
            limitDescriptors: [provider.provider.id: provider.widgetDescriptors], generatedAt: now
        )
        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state)
        XCTAssertEqual(response.status, 200)
        let body = try XCTUnwrap(response.body)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let kimi = try XCTUnwrap(providers[provider.provider.id] as? [String: Any])
        return try XCTUnwrap(kimi["resources"] as? [String: Any])
    }

    private func assertInvalid(_ wallet: Any, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try mapWallet(wallet), file: file, line: line) { error in
            XCTAssertEqual(error as? KimiUsageError, .invalidResponse, file: file, line: line)
        }
    }
}
