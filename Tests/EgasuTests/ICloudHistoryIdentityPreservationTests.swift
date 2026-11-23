import XCTest
@testable import Egasu

@MainActor
final class ICloudHistoryIdentityPreservationTests: XCTestCase {
    private let deviceID = "this-mac"
    private let history = ProviderUsageHistory(
        series: DailyUsageSeries(daily: [
            .init(date: "2026-11-23", totalTokens: 100, costUSD: 1.25)
        ]))

    func testMissingScopedHistoryRequiresTheSameAccountAndDevice() {
        let store = makeStore(identity: "account-a")
        let previous = document(identity: "account-a")
        let preserved = store.localHistoryDocument(deviceID: deviceID, deviceName: "Local", preserving: previous)
        XCTAssertEqual(preserved.providers["claude"], history)
        XCTAssertEqual(preserved.identities?["claude"], "account-a")

        for rejected in [
            document(identity: "account-b"), document(identity: nil),
            document(identity: "account-a", deviceID: "another-mac")
        ] {
            XCTAssertNil(
                store.localHistoryDocument(
                    deviceID: deviceID, deviceName: "Local", preserving: rejected
                ).providers["claude"])
        }
    }

    func testFamilyTotalDoesNotAcquireTheSelectedAccountsIdentity() {
        let store = makeStore(identity: "selected-account", familyTotal: true)
        let preserved = store.localHistoryDocument(
            deviceID: deviceID, deviceName: "Local", preserving: document(identity: nil))
        XCTAssertEqual(preserved.providers["claude"], history)
        XCTAssertNil(preserved.identities?["claude"])
        XCTAssertNil(
            store.localHistoryDocument(
                deviceID: deviceID, deviceName: "Local", preserving: document(identity: "personal-account")
            )
            .providers["claude"])
    }

    func testRemovedDisabledAndAccountWideCardsDoNotRestoreHistory() {
        for store in [
            makeStore(identity: "account-a", enabled: false),
            makeStore(identity: "account-a", scope: .accountWide),
            makeStore(identity: "account-a", registered: false)
        ] {
            XCTAssertNil(
                store.localHistoryDocument(
                    deviceID: deviceID, deviceName: "Local", preserving: document(identity: "account-a")
                )
                .providers["claude"])
        }
    }

    func testUnresolvedClaudeDoesNotRestoreUnattributedHistory() {
        let store = makeStore(identity: nil)
        XCTAssertNil(
            store.localHistoryDocument(
                deviceID: deviceID, deviceName: "Local", preserving: document(identity: nil)
            ).providers["claude"])
    }

    private func document(identity: String?, deviceID: String? = nil) -> UsageHistoryDocument {
        UsageHistoryDocument(
            deviceID: deviceID ?? self.deviceID, deviceName: "Local", updatedAt: .now,
            providers: ["claude": history], identities: identity.map { ["claude": $0] })
    }

    private func makeStore(
        identity: String?, enabled: Bool = true, scope: UsageHistoryDescriptor.Scope = .machineLocal,
        registered: Bool = true, familyTotal: Bool = false
    ) -> WidgetDataStore {
        let suite = "ICloudHistoryIdentityPreservationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let provider = ClaudeProvider.makeProvider()
        let descriptor = WidgetDescriptor.usageTrend(provider: provider)
            .exportingHistory(scope: scope, estimatedCost: true, sourceNote: "Fixture")
        let registry = WidgetRegistry(
            providers: registered ? [provider] : [], descriptors: registered ? [descriptor] : [])
        return WidgetDataStore(
            registry: registry, providers: [], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, isProviderEnabled: { _ in enabled },
            providerIdentityKeys: identity.map { ["claude": $0] } ?? [:],
            familyTotalHistoryCardIDs: familyTotal ? ["claude"] : [])
    }
}
