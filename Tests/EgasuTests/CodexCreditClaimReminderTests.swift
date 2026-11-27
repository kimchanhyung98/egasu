import Foundation
import Synchronization
import XCTest
@testable import Egasu

extension CodexCreditExpiryReminderTests {
    func claimStore(
        _ providers: [SequenceProviderRuntime], defaults: UserDefaults, center: Center
    ) -> WidgetDataStore {
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.codexCreditExpiry = true
        let store = WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults, persistsWrites: false, now: { center.now }),
            defaults: defaults, now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, "workspace") }))
        store.configureCodexCreditReminders(scheduler: center.scheduler())
        return store
    }

    func checkPending(
        _ expected: [Date], store: WidgetDataStore, center: Center, line: UInt = #line
    ) async {
        let read = expectation(description: "만료 예약 대조")
        center.nextPendingRead = read
        store.providerEnablementDidChange()
        await fulfillment(of: [read], timeout: 2)
        XCTAssertEqual(center.requests.values.map(\.date).sorted(), expected.sorted(), line: line)
    }

    func fireDates(_ expiry: Date) -> [Date] {
        [expiry.addingTimeInterval(-86_400), expiry.addingTimeInterval(-43_200)]
    }

    func testClaimReceiptFollowsOriginalUserWhenSourceCardChangesBeforeConsumeReturns() async throws {
        let now = Date.now
        let firstExpiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let secondExpiry = firstExpiry.addingTimeInterval(172_800)
        let defaults = defaults()
        let center = Center(now)
        let alice = try auth(subject: "alice", source: .keychain)
        let bob = try auth(subject: "bob", source: .keychain)
        let aliasID = AccountUsageCardPlanner.cardID(family: "codex", profileID: UUID().uuidString)
        let primary = try verified(snapshot(count: 1, expiries: [firstExpiry], observed: now), using: alice)
        let alias = try verified(
            snapshot(count: 1, expiries: [firstExpiry], observed: now, card: aliasID), using: alice)
        let replacement = try verified(snapshot(count: 1, expiries: [secondExpiry], observed: now), using: bob)
        let runtimes = [
            SequenceProviderRuntime(
                provider: CodexProvider.makeProvider(), descriptors: [], snapshots: [primary, replacement]),
            SequenceProviderRuntime(
                provider: CodexProvider.makeProvider(id: aliasID), descriptors: [], snapshots: [alias])
        ]
        let store = claimStore(runtimes, defaults: defaults, center: center)
        for runtime in runtimes { _ = await store.refresh(providerID: runtime.provider.id, force: true) }
        await checkPending(fireDates(firstExpiry), store: store, center: center)

        let list = try JSONSerialization.data(withJSONObject: [
            "available_count": 1, "credits": [["id": "used", "expires_at": firstExpiry.timeIntervalSince1970]]
        ])
        let http = RoutingHTTPClient { request in
            if request.method == "GET" { return HTTPResponse(statusCode: 200, headers: [:], body: list) }
            let changed = await store.refresh(providerID: "codex", force: true)
            XCTAssertEqual(changed, .refreshed)
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in alice })
        service.onUnavailable = { store.codexCreditsUnavailable(cardID: "codex", credits: $0) }
        let outcome = await service.claim(
            creditExpiringAt: firstExpiry, redeemRequestID: "first",
            binding: try XCTUnwrap(primary.codexResetClaimBinding))
        XCTAssertEqual(outcome, .success)
        await checkPending(fireDates(secondExpiry), store: store, center: center)

        let restarted = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
        await restarted.reconcile(
            accounts: [
                (try XCTUnwrap(alias.liveQuotaAccountKey), "Alice", alias),
                (try XCTUnwrap(replacement.liveQuotaAccountKey), "Bob", replacement)
            ], now: now
        ).value
        XCTAssertEqual(center.requests.values.map(\.date).sorted(), fireDates(secondExpiry))
        XCTAssertEqual(Set(center.requests.values.map(\.subtitle)), ["Bob"])
    }

    func testConfirmedEmptyInventoryClearsEveryExpiryButMissingSelectedDateKeepsOtherCredits() async throws {
        let now = Date.now
        let selected = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let other = selected.addingTimeInterval(172_800)
        let state = try auth(subject: "alice", source: .keychain)
        let reading = try verified(snapshot(count: 2, expiries: [selected, other], observed: now), using: state)
        let remainingCredit = ["id": "other", "expires_at": String(Int(other.timeIntervalSince1970))]
        let cases: [(count: Int, credits: [[String: String]], status: Int, dates: [Date], result: ResetClaimOutcome)] =
            [
                (0, [], 200, [], .noCredit),
                (1, [remainingCredit], 200, fireDates(other), .noCredit),
                (2, [remainingCredit], 200, fireDates(selected) + fireDates(other), .failed),
                (0, [], 503, fireDates(selected) + fireDates(other), .failed)
            ]
        for input in cases {
            let defaults = defaults()
            let center = Center(now)
            let provider = CodexProvider.makeProvider()
            let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
            let runtime = SequenceProviderRuntime(provider: provider, descriptors: [], snapshots: [reading, transient])
            let store = claimStore([runtime], defaults: defaults, center: center)
            _ = await store.refresh(providerID: "codex", force: true)
            await checkPending(fireDates(selected) + fireDates(other), store: store, center: center)
            let response = HTTPResponse(
                statusCode: input.status, headers: [:],
                body: try JSONSerialization.data(withJSONObject: [
                    "available_count": input.count, "credits": input.credits
                ]))
            let http = RoutingHTTPClient { request in
                XCTAssertEqual(request.method, "GET")
                return response
            }
            let service = CodexResetClaimService(
                usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in state },
                refreshAfterClaim: { _ in
                    let refresh = await store.refresh(providerID: "codex", force: true)
                    XCTAssertEqual(refresh, .failed)
                })
            service.onUnavailable = { store.codexCreditsUnavailable(cardID: "codex", credits: $0) }
            let result = await service.claim(
                creditExpiringAt: selected, redeemRequestID: "missing",
                binding: try XCTUnwrap(reading.codexResetClaimBinding))
            XCTAssertEqual(result, input.result)
            await checkPending(input.dates, store: store, center: center)
            let restarted = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
            await restarted.reconcile(
                accounts: [(try XCTUnwrap(reading.liveQuotaAccountKey), "Alice", reading)], now: now
            ).value
            XCTAssertEqual(center.requests.values.map(\.date).sorted(), input.dates.sorted())
        }
    }

    func testReplayedConsumptionKeepsRemainingCreditAfterInterveningDatedRefresh() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false)
    }

    func testReplayedConsumptionKeepsDatedRemainingCreditAfterCountOnlyRefresh() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: true)
    }

    func testReplayedConsumptionAfterOfflineFirstPostAndLostSecondResponseUsesActualRemainingCredit() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, failures: 2, startsOffline: true)
    }

    func testReplayedConsumptionAfterTwoLostResponsesKeepsCreditObservedBetweenAttempts() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, failures: 2)
    }

    func testFailedReplayInventoryDefersOnlyTheSelectedExpiryUntilDatedRefresh() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, verification: .failed)
    }

    func testIncompleteReplayInventoryDefersOnlyTheSelectedExpiryUntilDatedRefresh() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, verification: .incomplete)
    }

    func testChangedReplayLoginSkipsTheNewAccountsInventory() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, verification: .changedLogin)
    }

    func testFailedReplayInventoryKeepsTheVerifiedPreclaimUpperBound() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, verification: .failedWithBound)
    }

    func testConfirmedReplayInventoryIncludesNewGrantsBeyondThePreclaimBound() async throws {
        try await checkReplayedConsumption(countOnlyAfterDatedRefresh: false, verification: .newGrants)
    }

    private enum ReplayInventory: Equatable, Sendable {
        case complete, incomplete, failed, changedLogin, failedWithBound, newGrants

        var defersSelected: Bool { self == .incomplete || self == .failed || self == .changedLogin }
        var completePreclaim: Bool { self == .failedWithBound || self == .newGrants }
    }

    private func checkReplayedConsumption(
        countOnlyAfterDatedRefresh: Bool, failures: Int = 1, startsOffline: Bool = false,
        verification: ReplayInventory = .complete
    ) async throws {
        let now = Date.now
        let expiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let otherDates = verification == .complete ? [] : [expiry.addingTimeInterval(172_800)]
        let initialDates = [expiry, expiry] + otherDates
        let defaults = defaults()
        let center = Center(now)
        let state = try auth(subject: "alice", source: .keychain)
        let replacementLogin = try auth(subject: "bob", source: .keychain)
        let reading = try verified(
            snapshot(count: initialDates.count, expiries: initialDates, observed: now), using: state)
        let provider = CodexProvider.makeProvider()
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [], snapshots: [reading])
        let store = claimStore([runtime], defaults: defaults, center: center)
        _ = await store.refresh(providerID: "codex", force: true)
        let initialReminders = initialDates.flatMap { fireDates($0) }
        await checkPending(initialReminders, store: store, center: center)
        let beforeCredits = verification.completePreclaim ? initialDates : [expiry]
        let list = try JSONSerialization.data(withJSONObject: [
            "available_count": initialDates.count,
            "credits": beforeCredits.enumerated().map { index, date -> [String: Any] in
                ["id": index == 0 ? "used" : "original-\(index)", "expires_at": date.timeIntervalSince1970]
            }
        ])
        let finalCount = verification == .newGrants ? 3 : 1
        let finalDates = Array(repeating: expiry, count: finalCount) + otherDates
        let confirmed = try JSONSerialization.data(withJSONObject: [
            "available_count": finalDates.count + (verification == .incomplete ? 1 : 0),
            "credits": finalDates.enumerated().map { index, date -> [String: Any] in
                ["id": "remaining-\(index)", "expires_at": date.timeIntervalSince1970]
            }
        ])
        let server = Mutex((posts: 0, available: 2))
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                if server.withLock({ $0.posts == 0 }) { return HTTPResponse(statusCode: 200, headers: [:], body: list) }
                let status = verification == .failed || verification == .failedWithBound ? 503 : 200
                return HTTPResponse(statusCode: status, headers: [:], body: confirmed)
            }
            let error = server.withLock { state -> URLError.Code? in
                state.posts += 1
                if startsOffline && state.posts == 1 { return .notConnectedToInternet }
                state.available = 1
                return state.posts <= failures ? .networkConnectionLost : nil
            }
            if let error { throw URLError(error) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"already_redeemed"}"#.utf8))
        }
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http),
            credentialLoader: { _, _ in
                verification == .changedLogin && server.withLock({ $0.posts > failures }) ? replacementLogin : state
            },
            refreshAfterClaim: { _ in
                let refresh = await store.refresh(providerID: "codex", force: true)
                XCTAssertEqual(refresh, .failed)
            })
        service.onUnavailable = { store.codexCreditsUnavailable(cardID: "codex", credits: $0) }
        let binding = try XCTUnwrap(reading.codexResetClaimBinding)
        let lost = await service.claim(creditExpiringAt: expiry, redeemRequestID: "replayed", binding: binding)
        XCTAssertEqual(lost, .failed)
        await checkPending(initialReminders, store: store, center: center)

        center.now = Date.now
        let interimCount = server.withLock { $0.available }
        let interimExpiries = Array(repeating: expiry, count: interimCount) + otherDates
        let remaining = try verified(
            snapshot(count: interimExpiries.count, expiries: interimExpiries, observed: center.now), using: state)
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        var readings = [remaining]
        if countOnlyAfterDatedRefresh {
            let countOnly = try verified(snapshot(count: 1, expiries: [], observed: Date.now), using: state)
            readings.append(countOnly)
        }
        readings.append(transient)
        let updated = SequenceProviderRuntime(provider: provider, descriptors: [], snapshots: readings)
        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([updated]), providers: [updated], identityKeys: ["codex": "workspace"])
        _ = await store.refresh(providerID: "codex", force: true)
        await checkPending(interimExpiries.flatMap { fireDates($0) }, store: store, center: center)
        if countOnlyAfterDatedRefresh {
            center.now = Date.now
            let countOnly = await store.refresh(providerID: "codex", force: true)
            XCTAssertEqual(countOnly, .refreshed)
            await checkPending(interimExpiries.flatMap { fireDates($0) }, store: store, center: center)
        }
        if failures == 2 {
            let lostRetry = await service.claim(creditExpiringAt: expiry, redeemRequestID: "replayed", binding: binding)
            XCTAssertEqual(lostRetry, .failed)
            await checkPending(interimExpiries.flatMap { fireDates($0) }, store: store, center: center)
        }
        center.now = Date.now
        let replay = await service.claim(creditExpiringAt: expiry, redeemRequestID: "replayed", binding: binding)
        XCTAssertEqual(replay, .success)
        let posts = http.requests.filter { $0.method == "POST" }
        let confirmationReads = verification == .changedLogin ? [] : ["GET"]
        XCTAssertEqual(
            http.requests.map(\.method), ["GET"] + Array(repeating: "POST", count: failures + 1) + confirmationReads)
        for post in posts {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(post.body)) as? [String: String])
            XCTAssertEqual(body["credit_id"], "used")
            XCTAssertEqual(body["redeem_request_id"], "replayed")
        }
        let expected = verification.defersSelected ? otherDates : finalDates
        await checkPending(expected.flatMap { fireDates($0) }, store: store, center: center)

        let restarted = CodexCreditExpiryReminders(scheduler: center.scheduler(), defaults: defaults)
        let account = try XCTUnwrap(binding.verifiedAccountKey)
        await restarted.reconcile(accounts: [(account, "Alice", remaining)], now: center.now).value
        // 만료일별 영수증은 재시작 시 이전 목록에서 예약할 수 있는 수량의 상한.
        let restored =
            Array(repeating: expiry, count: verification.defersSelected ? 0 : min(interimCount, finalCount))
            + otherDates
        XCTAssertEqual(center.requests.values.map(\.date).sorted(), restored.flatMap { fireDates($0) }.sorted())

        if verification.defersSelected {
            center.now = Date.now
            let recovery = try verified(
                snapshot(count: finalDates.count, expiries: finalDates, observed: center.now), using: state)
            let recovered = SequenceProviderRuntime(provider: provider, descriptors: [], snapshots: [recovery])
            store.replaceProviderCatalog(
                registry: WidgetRegistry.from([recovered]), providers: [recovered], identityKeys: ["codex": "workspace"]
            )
            let refreshed = await store.refresh(providerID: "codex", force: true)
            XCTAssertEqual(refreshed, .refreshed)
            await checkPending(finalDates.flatMap { fireDates($0) }, store: store, center: center)
        }
    }
}
