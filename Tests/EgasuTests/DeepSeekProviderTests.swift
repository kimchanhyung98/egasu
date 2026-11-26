import SwiftUI
import XCTest

@testable import Egasu

@MainActor
final class DeepSeekProviderTests: XCTestCase {
    private let entry =
        #"{"currency":"USD","total_balance":"0.0000000100","topped_up_balance":"0.0000000001","granted_balance":"0.0000000099"}"#
    private let zero =
        #"{"currency":"CNY","total_balance":"0.0000","topped_up_balance":"0.00","granted_balance":"0.0"}"#

    private func provider(_ body: String, status: Int = 200) -> (DeepSeekProvider, FakeHTTPClient) {
        let http = FakeHTTPClient(response: .init(statusCode: status, headers: [:], body: Data(body.utf8)))
        let provider = DeepSeekProvider(
            files: FakeFiles(), environment: FakeEnvironment(["DEEPSEEK_API_KEY": "test-only"]),
            usageClient: .init(http: http)
        )
        return (provider, http)
    }

    func testBalancePreservesEachCurrencyPrecisionAndDetails() async throws {
        let (provider, http) = provider(#"{"is_available":false,"balance_infos":[\#(zero),\#(entry)]}"#)
        let snapshot = await provider.refresh()
        let request = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.url.absoluteString, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(request.headers["Authorization"], "Bearer test-only")
        XCTAssertNil(request.body)
        XCTAssertNil(snapshot.refreshFailure)
        XCTAssertNil(snapshot.usageHistory)
        XCTAssertNil(snapshot.totalSpendLines)

        let restored = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        let rows = L10n.withLanguage(.korean) {
            provider.widgetDescriptors.map {
                WidgetDataResolver.resolve($0, snapshot: restored, codexResetWatch: .init())
            }
        }
        XCTAssertEqual(rows[0].valueTextOverride, "USD 0.0000000100")
        XCTAssertEqual(rows[0].menuBarValue, "USD 0.0000000100")
        XCTAssertEqual(rows[0].unboundedValueTooltip, "충전액 (USD) 0.0000000001\n지급액 (USD) 0.0000000099")
        XCTAssertEqual(rows[1].valueTextOverride, "CNY 0.0000")
        XCTAssertEqual(rows[1].unboundedValueTooltip, "충전액 (CNY) 0.00\n지급액 (CNY) 0.0")
        XCTAssertEqual(rows[2].valueTextOverride, "Insufficient Balance")
    }

    func testEmptyListKeepsReportedAvailabilityWithoutInventingBalances() async {
        let (provider, _) = provider(#"{"is_available":true,"balance_infos":[]}"#)
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.refreshFailure)
        XCTAssertEqual(snapshot.lines, [.badge(label: "API Access", text: "Available")])
        let usd = WidgetDataResolver.resolve(
            provider.widgetDescriptors[0], snapshot: snapshot, codexResetWatch: .init())
        XCTAssertFalse(usd.hasData)
    }

    func testLegacyUsagePreservesBalancesWithoutChangingWireShape() async throws {
        let cny = entry.replacingOccurrences(of: "USD", with: "CNY")
        let (provider, _) = provider(#"{"is_available":true,"balance_infos":[\#(entry),\#(cny)]}"#)
        let snapshot = await provider.refresh()
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["deepseek"], knownIDs: ["deepseek"], snapshots: ["deepseek": snapshot]
        )

        for path in ["/v1/usage", "/v1/usage/deepseek"] {
            let response = L10n.withLanguage(.korean) {
                LocalUsageAPI.respond(method: "GET", path: path, state: state)
            }
            XCTAssertEqual(response.status, 200)
            let body = try XCTUnwrap(response.body)
            let providers = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [[String: Any]])
            let lines = try XCTUnwrap(providers.first?["lines"] as? [[String: Any]])
            for currency in ["USD", "CNY"] {
                let balance = try XCTUnwrap(lines.first { $0["label"] as? String == "Balance (\(currency))" })
                XCTAssertEqual(Set(balance.keys), ["type", "label", "value", "color", "subtitle"])
                XCTAssertEqual(balance["type"] as? String, "text")
                XCTAssertEqual(balance["value"] as? String, "\(currency) 0.0000000100")
                XCTAssertTrue(balance["color"] is NSNull)
                XCTAssertTrue(balance["subtitle"] is NSNull)
            }
        }
    }

    func testLocalLimitsExportsCurrencyBalancesSeparatelyAndOmitsUnreportedCurrency() async throws {
        for (entries, keys) in [(entry + "," + zero, ["balanceUSD", "balanceCNY"]), (entry, ["balanceUSD"]), ("", [])] {
            let (provider, _) = provider(#"{"is_available":true,"balance_infos":[\#(entries)]}"#)
            let snapshot = await provider.refresh()
            let state = LocalUsageAPI.State(
                enabledOrderedIDs: ["deepseek"], knownIDs: ["deepseek"],
                snapshots: ["deepseek": snapshot], limitDescriptors: ["deepseek": provider.widgetDescriptors],
                generatedAt: Date()
            )
            let response = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/deepseek", state: state)
            XCTAssertEqual(response.status, 200)
            let root = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(response.body)) as? [String: Any])
            let providers = try XCTUnwrap(root["providers"] as? [String: [String: Any]])
            let resources = try XCTUnwrap(providers["deepseek"]?["resources"] as? [String: [String: Any]])
            XCTAssertEqual(Set(resources.keys), Set(keys))
            if let usd = resources["balanceUSD"] {
                XCTAssertEqual(usd["kind"] as? String, "balance")
                XCTAssertEqual(usd["unit"] as? String, "usd")
                XCTAssertEqual(usd["available"] as? Double, 0.00000001)
            }
            if let cny = resources["balanceCNY"] {
                XCTAssertEqual(cny["unit"] as? String, "cny")
                XCTAssertEqual(cny["available"] as? Double, 0)
            }
        }
    }

    func testDeniedKeyAndMalformedResponseHaveDistinctErrors() async {
        for status in [401, 403, 429, 503] {
            let (provider, _) = provider("private response content", status: status)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, status == 401 || status == 403 ? .authInvalid : .http(status))
            XCTAssertFalse(snapshot.refreshFailure?.message.contains("private response content") ?? true)
        }
        for entries in [entry + "," + entry, entry.replacingOccurrences(of: "0.0000000100", with: "unknown")] {
            let (provider, _) = provider(#"{"is_available":true,"balance_infos":[\#(entries)]}"#)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.errorCategory, .decoding)
        }
    }

    func testManagedKeyOverridesEnvironmentAndRemovalRestoresItWithoutNetwork() async throws {
        let (provider, http) = provider("")
        XCTAssertEqual(provider.apiKeyStatus, .fromEnvironment)
        try provider.saveAPIKey(" entered-key ")
        XCTAssertEqual(provider.apiKeyStatus, .overrideActive)
        XCTAssertEqual(provider.currentAPIKey(), "entered-key")
        let detected = await provider.hasLocalCredentials()
        XCTAssertTrue(detected)
        try provider.deleteAPIKey()
        XCTAssertEqual(provider.currentAPIKey(), "test-only")
        XCTAssertTrue(http.requests.isEmpty)
    }

    func testBalanceCacheFollowsTheKeyUsedByTheAppAndCLI() async throws {
        let suite = "DeepSeekCredentialCacheTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let (provider, http) = provider(#"{"is_available":true,"balance_infos":[\#(entry)]}"#)
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        let id = provider.provider.id
        _ = await store.refresh(providerID: id, force: true)
        let initial = try XCTUnwrap(store.snapshots[id])
        let identity = try XCTUnwrap(initial.producedByIdentityKey)
        let wire = LocalUsageAPI.respond(
            method: "GET", path: "/v1/usage/deepseek",
            state: .init(enabledOrderedIDs: [id], knownIDs: [id], snapshots: [id: initial]))
        let payload = String(decoding: try XCTUnwrap(wire.body), as: UTF8.self)
        XCTAssertFalse(payload.contains(identity))
        XCTAssertFalse(payload.contains("test-only"))
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        let cached = try await reader.read(providerID: id)
        XCTAssertTrue(cached.warnings.isEmpty)
        XCTAssertEqual(http.requests.count, 1)
        http.response = .init(statusCode: 503, headers: [:], body: Data())
        _ = await store.refresh(providerID: id, force: true)
        XCTAssertEqual(store.snapshots[id]?.refreshedAt, initial.refreshedAt)

        try provider.saveAPIKey("another-account-key")
        let generation = store.credentialsDidChange(for: id)
        XCTAssertNil(store.snapshots[id], "A replacement key must not display the old account while loading")
        let calls = http.requests.count
        let result = try await reader.read(providerID: id)
        XCTAssertEqual(http.requests.count, calls + 1, "The new CLI connection must bypass the old fresh balance")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(json["providers"] as? [String: Any]).isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
        await store.refreshAfterCredentialChange(providerID: id, credentialGeneration: generation)
        XCTAssertNil(store.snapshots[id])
    }

    func testExternalKeyChangeDuringRequestDiscardsTheOldBalance() async throws {
        let files = FakeFiles()
        let config = StorageNamespace.current.configPath("deepseek.json")
        let body = #"{"is_available":true,"balance_infos":[\#(entry)]}"#
        let http = RoutingHTTPClient { request in
            XCTAssertEqual(request.headers["Authorization"], "Bearer first-fixture")
            try files.writeText(config, #"{"apiKey":"second-fixture"}"#)
            return .init(statusCode: 200, headers: [:], body: Data(body.utf8))
        }
        let runtime = DeepSeekProvider(
            files: files, environment: FakeEnvironment(["DEEPSEEK_API_KEY": "first-fixture"]),
            usageClient: .init(http: http))
        let snapshot = await runtime.refresh()
        XCTAssertNotNil(snapshot.refreshFailure)
        XCTAssertNil(snapshot.line(label: "Balance (USD)"))
        let active = await runtime.currentIdentityKey(allowKeychainInteraction: false)
        XCTAssertEqual(snapshot.producedByIdentityKey, active)
    }

    func testMissingKeyDoesNotSendRequest() async {
        let http = FakeHTTPClient(response: .init(statusCode: 200, headers: [:], body: Data()))
        let provider = DeepSeekProvider(
            files: FakeFiles(), environment: FakeEnvironment(), usageClient: .init(http: http))
        let detected = await provider.hasLocalCredentials()
        let snapshot = await provider.refresh()
        XCTAssertFalse(detected)
        XCTAssertEqual(snapshot.errorCategory, .notLoggedIn)
        XCTAssertTrue(http.requests.isEmpty)
    }
}

extension DashboardSnapshotTests {
    func testDeepSeekRendersReportedCurrencyAndAvailability() throws {
        let runtime = DeepSeekProvider(files: FakeFiles(), environment: FakeEnvironment())
        let balance = DeepSeekBalance(
            isAvailable: true,
            balanceInfos: [
                .init(currency: .cny, totalBalance: "110.00", toppedUpBalance: "100.00", grantedBalance: "10.00")
            ])
        let snapshot = try balance.snapshot(for: runtime.provider)
        try L10n.withLanguage(.korean) {
            let lines = runtime.widgetDescriptors.map { descriptor in
                DashboardLine(
                    descriptor: descriptor,
                    data: WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init()))
            }.filter(\.isVisible)
            XCTAssertEqual(lines.map(\.id), ["deepseek.balanceCNY", "deepseek.api"])
            XCTAssertEqual(lines.map { $0.data.headline }, ["CNY 110.00", "사용 가능"])
            let account = DashboardAccount(
                provider: runtime.provider, providerName: "DeepSeek", name: nil, lines: lines)
            let family = DashboardFamily(
                id: "deepseek", provider: runtime.provider, displayName: "DeepSeek", accounts: [account])
            let view = DashboardProviderSection(family: family) { DashboardAccountRows(account: $0, plan: nil) }
            let image = try render(view, appearance: .dark, name: "deepseek-balance")
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 2)
        }
    }
}
