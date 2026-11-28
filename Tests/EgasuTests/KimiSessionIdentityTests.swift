import Foundation
import XCTest
@testable import Egasu

@MainActor
final class KimiSessionIdentityTests: XCTestCase {
    func testKimiDoesNotPublishSessionOnlyQuotaAfterExternalAccountChange() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let path = home.appendingPathComponent("credentials/kimi-code.json").path
        let files = FakeFiles([path: #"{"access_token":"test-kimi-before"}"#])
        let client = RoutingHTTPClient { request in
            guard request.url == KimiUsageClient.usageURL,
                request.headers["Authorization"] == "Bearer test-kimi-before"
            else {
                throw URLError(.unsupportedURL)
            }
            try files.writeText(path, #"{"access_token":"test-kimi-after"}"#)
            return .init(
                statusCode: 200, headers: [:],
                body: Data(
                    #"{"usages":{"limit_5h":{"used_ratio":0.25}}}"#.utf8))
        }
        let provider = KimiProvider(
            authStore: KimiAuthStore(
                files: files, environment: FakeEnvironment(["KIMI_CODE_HOME": home.path]), homeDirectory: { home }),
            usageClient: KimiUsageClient(http: client), pricing: { .empty })
        let suite = "EgasuTests.KimiSessionIdentity." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: cache, defaults: defaults)

        let outcome = await store.refresh(providerID: "kimi", force: true, trigger: .manual)

        XCTAssertEqual(client.requests.map(\.url), [KimiUsageClient.usageURL])
        XCTAssertEqual(try files.readText(path), #"{"access_token":"test-kimi-after"}"#)
        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(store.refreshResults["kimi"]?.failure?.category, .credentialAccess)
        XCTAssertNil(store.localSnapshots["kimi"]?.line(label: "Session"))
        XCTAssertNil(ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["kimi"])["kimi"])
    }

}
