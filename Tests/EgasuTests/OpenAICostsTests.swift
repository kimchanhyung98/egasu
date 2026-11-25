import Foundation
import XCTest

@testable import Egasu

@MainActor
final class OpenAICostsTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 1_730_419_200 + 3_600)

    private func makeDefaults() -> UserDefaults {
        let suite = "OpenAICostsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func makeProvider(
        http: any HTTPClient, keychain: any KeychainAccessing = FakeKeychain("test-admin-key"),
        defaults: UserDefaults? = nil
    ) -> OpenAICostsProvider {
        OpenAICostsProvider(
            defaults: defaults ?? makeDefaults(), keys: .init(keychain: keychain),
            client: .init(http: http), now: { [date] in date })
    }

    func testAllPagesKeepQueryScopeAndPreserveSubCentAmountByCurrency() async throws {
        let http = RoutingHTTPClient { request in
            let items = try XCTUnwrap(URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(request.method, "GET")
            XCTAssertEqual(request.url.host, "api.openai.com")
            XCTAssertEqual(request.url.path, "/v1/organization/costs")
            XCTAssertEqual(request.headers["Authorization"], "Bearer test-admin-key")
            XCTAssertEqual(items.filter { $0.name == "project_ids[]" }.compactMap(\.value), ["proj_A", "proj_B"])
            XCTAssertEqual(items.first { $0.name == "start_time" }?.value, String(1_730_419_200 - 29 * 86_400))
            XCTAssertEqual(items.first { $0.name == "end_time" }?.value, String(1_730_419_200 + 3_600))
            XCTAssertFalse(request.logTarget.contains("proj_"))
            let page = items.first { $0.name == "page" }?.value
            if let page {
                XCTAssertEqual(page, "+Q/1==")
                XCTAssertTrue(request.url.absoluteString.contains("%2B"))
                return Self.response(
                    #"{"data":[{"results":[{"amount":{"currency":"usd","value":0.000000000000000003}},{"amount":{"currency":"eur","value":-1.2}}]}],"has_more":false}"#
                )
            }
            return Self.response(
                #"{"data":[{"results":[{"amount":{"currency":"usd","value":0.008000000000000001}}]}],"has_more":true,"next_page":"+Q/1=="}"#
            )
        }
        let provider = makeProvider(http: http)
        try provider.saveConnection(key: "", projects: "proj_B, proj_A,proj_A")
        let snapshot = await provider.refresh()
        XCTAssertNil(snapshot.refreshFailure)
        XCTAssertEqual(snapshot.line(label: "Billing Scope"), .badge(label: "Billing Scope", text: "proj_A, proj_B"))
        XCTAssertEqual(
            snapshot.line(label: "Last 30 Days"),
            .badge(
                label: "Last 30 Days", text: "EUR -1.2 · USD 0.008000000000000004",
                subtitle: "2024-10-03 – 2024-11-01 UTC"))
        XCTAssertEqual(http.requests.count, 2)
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "openai-api.costs" })
        let card = WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
        XCTAssertEqual(card.dashboardRow().mark, .value("EUR -1.2", detail: "USD 0.008000000000000004"))
        let id = provider.provider.id
        let wire = LocalUsageAPI.respond(
            method: "GET", path: "/v1/usage/openai-api",
            state: .init(enabledOrderedIDs: [id], knownIDs: [id], snapshots: [id: snapshot]))
        let json = String(decoding: try XCTUnwrap(wire.body), as: UTF8.self)
        XCTAssertTrue(json.contains("USD 0.008000000000000004"))
        XCTAssertFalse(json.contains(provider.connectionID))
        XCTAssertFalse(json.contains("test-admin-key"))
    }

    func testOrganizationEmptyAndExplicitZeroHaveDistinctCards() async throws {
        let http = FakeHTTPClient(response: Self.response(#"{"data":[{"results":[]}],"has_more":false}"#))
        let provider = makeProvider(http: http)
        let empty = await provider.refresh()
        XCTAssertEqual(empty.line(label: "Billing Scope"), .badge(label: "Billing Scope", text: "Organization"))
        XCTAssertFalse(try XCTUnwrap(http.requests.first).url.absoluteString.contains("project_ids"))
        guard case let .badge(_, text, _, _) = empty.line(label: "Last 30 Days") else { return XCTFail() }
        XCTAssertEqual(text, "No costs reported")
        http.response = Self.response(
            #"{"data":[{"results":[{"amount":{"value":0,"currency":"usd"}}]}],"has_more":false}"#)
        let zero = await provider.refresh()
        guard case let .badge(_, value, _, _) = zero.line(label: "Last 30 Days") else { return XCTFail() }
        XCTAssertEqual(value, "USD 0")
        XCTAssertEqual(zero.line(label: "Credit Balance"), .badge(label: "Credit Balance", text: "Unavailable"))
        XCTAssertThrowsError(try OpenAICostsProvider.parseProjects(", ,"))
    }

    func testFailedPageAndMissingAmountDoNotPublishPartialOrZeroResults() async {
        for body in [
            #"{"data":[{"results":[{"amount":{"currency":"usd","value":4.75}}]}],"has_more":true}"#,
            #"{"data":[],"has_more":true,"next_page":"repeated"}"#,
            #"{"data":[{"results":[{"amount":{"currency":"usd"}}]}],"has_more":false}"#,
            #"{"data":[{"results":[{"amount":{"currency":"usd","value":1e38}},{"amount":{"currency":"usd","value":1e-40}}]}],"has_more":false}"#
        ] {
            let http = FakeHTTPClient(response: Self.response(body))
            let snapshot = await makeProvider(http: http).refresh()
            XCTAssertEqual(snapshot.errorCategory, .decoding)
            XCTAssertNil(snapshot.line(label: "Last 30 Days"))
            XCTAssertLessThanOrEqual(http.requests.count, 2)
        }
    }

    func testPermissionErrorRetainsPreviousCostsAndLastSuccessfulTime() async throws {
        let defaults = makeDefaults()
        let http = FakeHTTPClient(
            response: Self.response(
                #"{"data":[{"results":[{"amount":{"value":1.2,"currency":"usd"}}]}],"has_more":false}"#))
        let provider = makeProvider(http: http, defaults: defaults)
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults)
        _ = await store.refresh(providerID: provider.provider.id, force: true)
        let previous = try XCTUnwrap(store.localSnapshots[provider.provider.id])
        XCTAssertEqual(
            previous.line(label: "Last Updated"), .badge(label: "Last Updated", text: "2024-11-01 01:00:00 UTC"))
        http.response = HTTPResponse(statusCode: 403, headers: [:], body: Data("private response".utf8))
        _ = await store.refresh(providerID: provider.provider.id, force: true)
        XCTAssertEqual(store.localSnapshots[provider.provider.id]?.lines, previous.lines)
        let error = try XCTUnwrap(store.headerNotice(for: provider.provider.id))
        XCTAssertFalse(error.contains("private response"))
        let denied = await provider.refresh()
        XCTAssertEqual(denied.errorCategory, .permission)
    }

    func testConnectionChangesDiscardPreviousCostsInAppAndPersistedCLICache() async throws {
        let defaults = makeDefaults()
        let success = Self.response(
            #"{"data":[{"results":[{"amount":{"value":1.2,"currency":"usd"}}]}],"has_more":false}"#)
        let http = FakeHTTPClient(response: success)
        let provider = makeProvider(http: http, keychain: ServiceKeychain(), defaults: defaults)
        try provider.saveConnection(key: "test-admin-key", projects: "proj_old")
        let cache = ProviderSnapshotCache(
            userDefaults: defaults, allowsPersistedFreshness: true, now: { [date] in date })
        let id = provider.provider.id
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)
        for (key, projects) in [("", "proj_new"), ("new-test-admin-key", "proj_new")] {
            http.response = success
            _ = await store.refresh(providerID: id, force: true)
            XCTAssertNotNil(store.snapshots[id])
            XCTAssertNotNil(cache.snapshot(providerID: id))
            try provider.saveConnection(key: key, projects: projects)
            let generation = store.credentialsDidChange(for: id)
            XCTAssertNil(store.snapshots[id])
            XCTAssertNil(cache.snapshot(providerID: id))
            let relaunched = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: true)
            XCTAssertNil(relaunched.loadSnapshots(providerIDs: [id])[id])
            http.response = HTTPResponse(statusCode: 403, headers: [:], body: Data())
            await store.refreshAfterCredentialChange(providerID: id, credentialGeneration: generation)
            XCTAssertNil(store.snapshots[id])
            XCTAssertNotNil(store.headerNotice(for: id))
            let result = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: id)
            let output = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
            XCTAssertTrue(try XCTUnwrap(output["providers"] as? [String: Any]).isEmpty)
            XCTAssertFalse(result.warnings.isEmpty)
        }
    }

    func testRegistrationKeychainRemovalAndLocalDetection() async throws {
        let defaults = makeDefaults()
        let keychain = ServiceKeychain()
        let http = FakeHTTPClient(response: Self.response("{}"))
        let provider = makeProvider(http: http, keychain: keychain, defaults: defaults)
        let availableBefore = await provider.hasLocalCredentials()
        XCTAssertFalse(availableBefore)
        XCTAssertEqual(provider.apiKeyStatus, .notSet)
        let missing = await provider.refresh()
        XCTAssertEqual(missing.errorCategory, .notLoggedIn)
        try provider.saveAPIKey(" fixture-key ")
        try provider.saveConnection(key: "", projects: "proj_1")
        XCTAssertEqual(Array(keychain.currentUserValues.values), ["fixture-key"])
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == "fixture-key" })
        let availableAfter = await provider.hasLocalCredentials()
        XCTAssertTrue(availableAfter)
        XCTAssertEqual(provider.apiKeyStatus, .saved)
        XCTAssertTrue(http.requests.isEmpty)
        try provider.deleteAPIKey()
        XCTAssertTrue(keychain.currentUserValues.isEmpty)
        XCTAssertTrue(provider.projectIDs.isEmpty)
        XCTAssertEqual(provider.apiKeyStatus, .notSet)
        XCTAssertTrue(ProviderCatalog.make(defaults: defaults).contains { $0 is OpenAICostsProvider })
    }

    func testRemovingConnectionDuringFirstPageStopsUsingDeletedKey() async throws {
        let defaults = makeDefaults()
        let keys = ServiceKeychain()
        let editor = makeProvider(
            http: FakeHTTPClient(response: Self.response("{}")), keychain: keys, defaults: defaults)
        try editor.saveConnection(key: "removed-key", projects: "proj_old")
        let http = RoutingHTTPClient { request in
            if URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: {
                $0.name == "page"
            }) == true {
                return Self.response(#"{"data":[],"has_more":false}"#)
            }
            XCTAssertEqual(request.headers["Authorization"], "Bearer removed-key")
            try await editor.deleteAPIKey()
            return Self.response(#"{"data":[],"has_more":true,"next_page":"old-cursor"}"#)
        }
        let reader = makeProvider(http: http, keychain: keys, defaults: defaults)
        let result = try await UsageReader(userDefaults: defaults, providers: [reader]).read(
            providerID: reader.provider.id, force: true)
        let output = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        XCTAssertTrue(try XCTUnwrap(output["providers"] as? [String: Any]).isEmpty)
        XCTAssertEqual(
            result.warnings, ["openai-api: The OpenAI billing connection changed during refresh. Refresh again."])
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertNil(
            ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: [reader.provider.id])[
                reader.provider.id])
    }

    func testSavingOnlyProjectsChecksThatThePreviouslyDisplayedKeyStillExists() throws {
        let defaults = makeDefaults()
        let keychain = ServiceKeychain()
        let provider = makeProvider(
            http: FakeHTTPClient(response: Self.response("{}")), keychain: keychain, defaults: defaults)
        try provider.saveConnection(key: "fixture-key", projects: "proj_A")
        XCTAssertEqual(provider.apiKeyStatus, .saved)
        try OpenAIAdminKeyStore(keychain: keychain).remove()
        let revision = provider.connectionID
        XCTAssertThrowsError(try provider.saveConnection(key: "", projects: "proj_B")) { error in
            XCTAssertEqual((error as? OpenAICostsError)?.errorCategory, .notLoggedIn)
        }
        XCTAssertEqual(provider.projectIDs, ["proj_A"])
        XCTAssertEqual(provider.connectionID, revision)
    }

    func testCLIReusesFreshCostsOnlyWithTheSameConnection() async throws {
        let defaults = makeDefaults()
        let keys = ServiceKeychain()
        let http = FakeHTTPClient(
            response: Self.response(
                #"{"data":[{"results":[{"amount":{"value":0.005,"currency":"usd"}}]}],"has_more":false}"#))
        let provider = OpenAICostsProvider(defaults: defaults, keys: .init(keychain: keys), client: .init(http: http))
        try provider.saveConnection(key: "fixture-key", projects: "proj_A")
        let id = provider.provider.id
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        let initial = try await reader.read(providerID: id, force: true)
        XCTAssertTrue(initial.warnings.isEmpty)
        let stored = try XCTUnwrap(ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: [id])[id])
        guard case .badge(_, let price, _, _) = stored.line(label: "Last 30 Days") else { return XCTFail() }
        XCTAssertEqual(price, "USD 0.005")
        http.response = HTTPResponse(statusCode: 403, headers: [:], body: Data())
        let cached = try await reader.read(providerID: id)
        XCTAssertTrue(cached.warnings.isEmpty)
        XCTAssertEqual(http.requests.count, 1)
        try provider.saveConnection(key: "", projects: "proj_B")
        let changed = try await reader.read(providerID: id)
        XCTAssertFalse(changed.warnings.isEmpty)
        XCTAssertEqual(http.requests.count, 2)
    }

    nonisolated private static func response(_ body: String) -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
    }
}
