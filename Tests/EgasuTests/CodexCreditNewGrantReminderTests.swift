import Foundation
import Synchronization
import XCTest
@testable import Egasu

extension CodexCreditExpiryReminderTests {
    func testCompletePreclaimAfterNewGrantKeepsSameExpiryCreditFollowingTwoSuccessfulClaims() async throws {
        try await checkSecondClaimAfterSameExpiryGrant(
            initialIDs: ["a", "b"], grantedIDs: ["c"], completePreclaim: true)
    }

    func testCompletePreclaimAfterNewGrantRestoresNewlyConfirmedReservations() async throws {
        try await checkSecondClaimAfterSameExpiryGrant(
            initialIDs: ["a"], grantedIDs: ["b", "c"], completePreclaim: true)
        try await checkSecondClaimAfterSameExpiryGrant(
            initialIDs: ["a", "b"], grantedIDs: ["c", "d"], completePreclaim: true)
    }

    func testPartialPreclaimAfterNewGrantDoesNotRestoreSameExpiryReservations() async throws {
        try await checkSecondClaimAfterSameExpiryGrant(
            initialIDs: ["a", "b"], grantedIDs: ["c"], completePreclaim: false)
    }

    private func checkSecondClaimAfterSameExpiryGrant(
        initialIDs: [String], grantedIDs: [String], completePreclaim: Bool
    ) async throws {
        let now = Date.now
        let expiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let center = Center(now)
        let state = try auth(subject: "alice", source: .keychain)
        let initialDates = Array(repeating: expiry, count: initialIDs.count)
        let reading = try verified(
            snapshot(count: initialIDs.count, expiries: initialDates, observed: now), using: state)
        let provider = CodexProvider.makeProvider()
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        let runtime = SequenceProviderRuntime(
            provider: provider, descriptors: [], snapshots: [reading, transient, transient])
        let store = claimStore([runtime], defaults: defaults(), center: center)
        let loaded = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(loaded, .refreshed)
        await checkPending(initialDates.flatMap { fireDates($0) }, store: store, center: center)

        let serverInventory = Mutex(initialIDs)
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                let ids = serverInventory.withLock { $0 }
                let listedIDs = completePreclaim || ids == initialIDs ? ids : Array(ids.prefix(1))
                let dates = Array(repeating: expiry, count: listedIDs.count)
                let list = try Self.creditList(listedIDs, expiries: dates, availableCount: ids.count)
                return HTTPResponse(statusCode: 200, headers: [:], body: list)
            }
            XCTAssertEqual(request.method, "POST")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
            let used = try XCTUnwrap(body["credit_id"])
            let hadCredit = serverInventory.withLock { ids in
                guard let index = ids.firstIndex(of: used) else { return false }
                ids.remove(at: index)
                return true
            }
            XCTAssertTrue(hadCredit)
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let service = claimService(http: http, state: state, store: store, expectedRefresh: .failed)
        let binding = try XCTUnwrap(reading.codexResetClaimBinding)
        let first = await service.claim(creditExpiringAt: expiry, redeemRequestID: "one", binding: binding)
        XCTAssertEqual(first, .success)
        let remainingAfterFirst = Array(initialIDs.dropFirst())
        XCTAssertEqual(serverInventory.withLock { $0 }, remainingAfterFirst)
        let firstExpected = Array(repeating: expiry, count: remainingAfterFirst.count).flatMap { fireDates($0) }
        await checkPending(firstExpected, store: store, center: center)

        let nextInventory = remainingAfterFirst + grantedIDs
        serverInventory.withLock { $0 = nextInventory }
        center.now = now.addingTimeInterval(60)
        let second = await service.claim(creditExpiringAt: expiry, redeemRequestID: "two", binding: binding)
        XCTAssertEqual(second, .success)
        let remainingAfterSecond = Array(nextInventory.dropFirst())
        XCTAssertEqual(serverInventory.withLock { $0 }, remainingAfterSecond)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST", "GET", "POST"])
        let remainingCount = completePreclaim ? remainingAfterSecond.count : max(0, remainingAfterFirst.count - 1)
        let expected = Array(repeating: expiry, count: remainingCount).flatMap { fireDates($0) }
        await checkPending(expected, store: store, center: center)
    }

    func testCompletePreclaimKeepsAllConfirmedExpiriesThroughCountOnlyRefresh() async throws {
        let now = Date.now
        let expiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let later = expiry.addingTimeInterval(86_400)
        let center = Center(now)
        let state = try auth(subject: "alice", source: .keychain)
        let initial = try verified(snapshot(count: 2, expiries: [expiry], observed: now), using: state)
        let countOnly = try verified(
            snapshot(count: 2, expiries: [], observed: now.addingTimeInterval(120)), using: state)
        let runtime = SequenceProviderRuntime(
            provider: CodexProvider.makeProvider(), descriptors: [], snapshots: [initial, countOnly])
        let store = claimStore([runtime], defaults: defaults(), center: center)
        let loaded = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(loaded, .refreshed)
        await checkPending(fireDates(expiry), store: store, center: center)

        let list = try Self.creditList(["used", "new", "previously-undated"], expiries: [expiry, expiry, later])
        let http = RoutingHTTPClient { request in
            if request.method == "GET" { return HTTPResponse(statusCode: 200, headers: [:], body: list) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let service = claimService(http: http, state: state, store: store, expectedRefresh: .refreshed)
        center.now = now.addingTimeInterval(60)
        let binding = try XCTUnwrap(initial.codexResetClaimBinding)
        let claim = await service.claim(creditExpiringAt: expiry, redeemRequestID: "one", binding: binding)
        XCTAssertEqual(claim, .success)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        center.now = now.addingTimeInterval(120)
        await checkPending(fireDates(expiry) + fireDates(later), store: store, center: center)
    }

    func testPreclaimWithoutAvailableCountKeepsOtherExpiryReservations() async throws {
        let now = Date.now
        let expiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let later = expiry.addingTimeInterval(86_400)
        let center = Center(now)
        let state = try auth(subject: "alice", source: .keychain)
        let initial = try verified(snapshot(count: 2, expiries: [expiry, later], observed: now), using: state)
        let provider = CodexProvider.makeProvider()
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: [], snapshots: [initial, transient])
        let store = claimStore([runtime], defaults: defaults(), center: center)
        let loaded = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(loaded, .refreshed)
        await checkPending(fireDates(expiry) + fireDates(later), store: store, center: center)

        let list = Data(#"{"credits":[{"id":"used","expires_at":\#(expiry.timeIntervalSince1970)}]}"#.utf8)
        let http = RoutingHTTPClient { request in
            if request.method == "GET" { return HTTPResponse(statusCode: 200, headers: [:], body: list) }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let service = claimService(http: http, state: state, store: store, expectedRefresh: .failed)
        let binding = try XCTUnwrap(initial.codexResetClaimBinding)
        center.now = now.addingTimeInterval(60)
        let claim = await service.claim(creditExpiringAt: expiry, redeemRequestID: "one", binding: binding)
        XCTAssertEqual(claim, .success)
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST"])
        await checkPending(fireDates(later), store: store, center: center)
    }

    func testRetriedClaimKeepsTheNewerBoundAfterReusingItsOriginalSelection() async throws {
        let now = Date.now
        let expiry = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970) + 172_800)
        let center = Center(now)
        let state = try auth(subject: "alice", source: .keychain)
        let reading = try verified(snapshot(count: 3, expiries: [expiry, expiry, expiry], observed: now), using: state)
        let provider = CodexProvider.makeProvider()
        let transient = ProviderSnapshot.error(provider: provider, message: "unavailable", category: .http5xx)
        let runtime = SequenceProviderRuntime(
            provider: provider, descriptors: [], snapshots: [reading, transient, transient])
        let store = claimStore([runtime], defaults: defaults(), center: center)
        let loaded = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(loaded, .refreshed)

        let inventory = Mutex(["a", "b", "c"])
        let rejectFirstAttempt = Mutex(true)
        let http = RoutingHTTPClient { request in
            if request.method == "GET" {
                let ids = inventory.withLock { $0 }
                let body = try Self.creditList(ids, expiries: Array(repeating: expiry, count: ids.count))
                return HTTPResponse(statusCode: 200, headers: [:], body: body)
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
            let id = try XCTUnwrap(body["credit_id"])
            if body["redeem_request_id"] == "retry",
                rejectFirstAttempt.withLock({ rejected in
                    defer { rejected = false }
                    return rejected
                })
            {
                return HTTPResponse(statusCode: 503, headers: [:], body: Data())
            }
            let consumed = inventory.withLock { credits in
                guard let index = credits.firstIndex(of: id) else { return false }
                credits.remove(at: index)
                return true
            }
            XCTAssertTrue(consumed)
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"code":"reset"}"#.utf8))
        }
        let service = claimService(http: http, state: state, store: store, expectedRefresh: .failed)
        let binding = try XCTUnwrap(reading.codexResetClaimBinding)
        let failed = await service.claim(creditExpiringAt: expiry, redeemRequestID: "retry", binding: binding)
        XCTAssertEqual(failed, .failed)

        // 새 요청은 그 사이 다른 곳에서 사용한 C를 제외한 전체 목록을 확인.
        inventory.withLock { $0 = ["b", "a"] }
        center.now = now.addingTimeInterval(60)
        let newer = await service.claim(creditExpiringAt: expiry, redeemRequestID: "new", binding: binding)
        XCTAssertEqual(newer, .success)
        XCTAssertEqual(inventory.withLock { $0 }, ["a"])
        await checkPending(fireDates(expiry), store: store, center: center)

        center.now = now.addingTimeInterval(120)
        let retried = await service.claim(creditExpiringAt: expiry, redeemRequestID: "retry", binding: binding)
        XCTAssertEqual(retried, .success)
        XCTAssertTrue(inventory.withLock { $0.isEmpty })
        XCTAssertEqual(http.requests.map(\.method), ["GET", "POST", "GET", "POST", "POST"])
        await checkPending([], store: store, center: center)
    }

    private nonisolated static func creditList(
        _ ids: [String], expiries: [Date], availableCount: Int? = nil
    ) throws -> Data {
        let credits = zip(ids, expiries).map { ["id": $0, "expires_at": $1.timeIntervalSince1970] as [String: Any] }
        return try JSONSerialization.data(withJSONObject: [
            "available_count": availableCount ?? ids.count,
            "credits": credits
        ])
    }

    private func claimService(
        http: any HTTPClient, state: CodexAuthState, store: WidgetDataStore,
        expectedRefresh: WidgetDataStore.RefreshOutcome
    ) -> CodexResetClaimService {
        let service = CodexResetClaimService(
            usageClient: CodexUsageClient(http: http), credentialLoader: { _, _ in state },
            refreshAfterClaim: { _ in
                let refresh = await store.refresh(providerID: "codex", force: true)
                XCTAssertEqual(refresh, expectedRefresh)
            })
        service.onUnavailable = { store.codexCreditsUnavailable(cardID: "codex", credits: $0) }
        return service
    }
}
