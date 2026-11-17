import os
import XCTest
@testable import Egasu

@MainActor
final class UsageTimerProviderCredentialTests: XCTestCase {
    private nonisolated static let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testZAIRechecksAPIKeyBeforePreparedMessageLaunches() async throws {
        for replacement in ["original", "changed", nil] as [String?] {
            let path = ZAIAuthStore.configPaths[0]
            let files = FakeFiles([path: "original"])
            let provider = ZAIProvider(
                authStore: ZAIAuthStore(files: files, environment: FakeEnvironment()),
                usageClient: ZAIUsageClient(
                    http: RoutingHTTPClient { _ in
                        .init(
                            statusCode: 200, headers: [:],
                            body: Data(
                                #"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":0,"nextResetTime":1800018000000}]}}"#
                                    .utf8))
                    }),
                now: { Self.now }, pricing: { .empty }
            )
            _ = await provider.refresh()
            let observation = try XCTUnwrap(provider.usageTimerObservations.first)
            let cli = LaunchProbe()
            let prepared = try await provider.prepareUsageTimer(
                observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli)
            )
            let session = try XCTUnwrap(prepared)
            files.files[path] = replacement

            let result = await session.send { true }

            XCTAssertEqual(result.launched, replacement == "original")
            XCTAssertEqual(cli.launchCount, replacement == "original" ? 1 : 0)
            XCTAssertEqual(files.files[path], replacement)
        }
    }

    func testAntigravityRechecksKeychainIdentityBeforePreparedMessageLaunches() async throws {
        for replacement in ["original", "changed", nil] as [String?] {
            let keychain = FakeKeychain(Self.keychainValue(refreshToken: "original"))
            let routing = RoutingHTTPClient { request in
                if request.url.path.contains("retrieveUserQuotaSummary") {
                    return .init(statusCode: 200, headers: [:], body: Self.summary)
                }
                if request.url.path.contains("loadCodeAssist") {
                    return .init(
                        statusCode: 200, headers: [:], body: Data(#"{"paidTier":{"name":"Google AI Pro"}}"#.utf8))
                }
                return .init(statusCode: 404, headers: [:], body: Data())
            }
            let provider = AntigravityProvider(
                authStore: AntigravityAuthStore(keychain: keychain, files: FakeFiles(), now: { Self.now }),
                usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
                discovery: LanguageServerDiscovery(processRunner: DiscoveryRunner(hasLS: false)),
                usageScan: { _, _ in nil }, now: { Self.now }, pricing: { .empty }
            )
            _ = await provider.refresh()
            let observation = try XCTUnwrap(provider.usageTimerObservations.first)
            let cli = LaunchProbe()
            let prepared = try await provider.prepareUsageTimer(
                observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: cli)
            )
            let session = try XCTUnwrap(prepared)
            keychain.value = replacement.map { Self.keychainValue(refreshToken: $0) }

            let result = await session.send { true }

            XCTAssertEqual(result.launched, replacement == "original")
            XCTAssertEqual(cli.launchCount, replacement == "original" ? 1 : 0)
            XCTAssertEqual(keychain.value, replacement.map { Self.keychainValue(refreshToken: $0) })
        }
    }

    func testOptionalCloudCodeFailureKeepsSuccessfulLanguageServerQuota() async {
        let routing = RoutingHTTPClient { request in
            guard request.url.host == "127.0.0.1" else {
                return .init(statusCode: 503, headers: [:], body: Data())
            }
            if request.url.path.hasSuffix("/RetrieveUserQuotaSummary") {
                return .init(statusCode: 200, headers: [:], body: Self.summary)
            }
            return .init(statusCode: 404, headers: [:], body: Data())
        }
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(
                keychain: FakeKeychain(Self.keychainValue(refreshToken: "original")),
                files: FakeFiles(), now: { Self.now }
            ),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: DiscoveryRunner(hasLS: true)),
            usageScan: { _, _ in nil }, now: { Self.now }, pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.lines.map(\.label), ["Session", "Weekly", "Claude", "Claude Weekly"])
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertTrue(snapshot.isDegraded == true)
        XCTAssertNotNil(snapshot.warning)
        XCTAssertEqual(snapshot.liveQuotaObservedAt, Self.now)
        XCTAssertTrue(provider.usageTimerObservations.isEmpty)
        XCTAssertTrue(routing.requests.contains { $0.url.host != "127.0.0.1" })
    }

    func testCloudCodeQuotaIsNotReadAgainWhenTimerCandidatesAreUnavailable() async {
        for hasRefreshToken in [false, true] {
            let token =
                hasRefreshToken
                ? Self.keychainValue(refreshToken: "original")
                : #"{"token":{"access_token":"test-access","expiry":"2099-01-01T00:00:00Z"}}"#
            let summary =
                hasRefreshToken
                ? Data(
                    String(decoding: Self.summary, as: UTF8.self)
                        .replacingOccurrences(
                            of: "weekly\",\"remainingFraction\":1", with: "weekly\",\"remainingFraction\":0"
                        ).utf8)
                : Self.summary
            let routing = RoutingHTTPClient { request in
                if request.url.path.contains("retrieveUserQuotaSummary") {
                    return .init(statusCode: 200, headers: [:], body: summary)
                }
                return .init(statusCode: 404, headers: [:], body: Data())
            }
            let provider = AntigravityProvider(
                authStore: AntigravityAuthStore(keychain: FakeKeychain(token), files: FakeFiles(), now: { Self.now }),
                usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
                discovery: LanguageServerDiscovery(processRunner: DiscoveryRunner(hasLS: false)),
                usageScan: { _, _ in nil }, now: { Self.now }, pricing: { .empty }
            )

            let snapshot = await provider.refresh()

            XCTAssertNil(snapshot.errorCategory)
            XCTAssertEqual(snapshot.lines.count, 4)
            XCTAssertTrue(provider.usageTimerObservations.isEmpty)
            let hosts = routing.requests.filter { $0.url.path.contains("retrieveUserQuotaSummary") }.compactMap(
                \.url.host)
            XCTAssertFalse(hosts.isEmpty)
            XCTAssertEqual(hosts.count, Set(hosts).count, "Each host must be queried only once")
        }
    }

    func testUnknownZAIQuotaProducesNoTimerCandidateOrCLIEntry() async throws {
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "fixture-key"])),
            usageClient: ZAIUsageClient(
                http: RoutingHTTPClient { _ in
                    .init(statusCode: 200, headers: [:], body: Data(#"{"data":{"limits":[]}}"#.utf8))
                }), now: { Self.now }, pricing: { .empty })
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let cli = LaunchProbe()
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, executor: fixture.executor(),
            cliExecutor: cli, store: fixture.store, report: { _, _ in }, refresh: { _, _ in }, now: { Self.now })

        let snapshot = await provider.refresh()
        router.receive(snapshot, trigger: .manual)
        await router.waitForPendingWork(providerIDs: ["zai"])

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.liveQuotaObservedAt, Self.now)
        XCTAssertTrue(provider.usageTimerObservations.isEmpty)
        XCTAssertFalse(router.hasPendingWork)
        XCTAssertEqual(cli.executionCount, 0)
        await router.shutdown()
    }

    func testZAIQuotaObservationTimeDoesNotIncludeSlowSubscriptionLookup() async throws {
        let clock = OSAllocatedUnfairLock(initialState: Self.now)
        let provider = ZAIProvider(
            authStore: ZAIAuthStore(files: FakeFiles(), environment: FakeEnvironment(["ZAI_API_KEY": "fixture-key"])),
            usageClient: ZAIUsageClient(
                http: RoutingHTTPClient { request in
                    if request.url == ZAIUsageClient.subscriptionURL { clock.withLock { $0.addTimeInterval(120) } }
                    return .init(
                        statusCode: 200, headers: [:],
                        body: Data(
                            #"{"data":{"limits":[{"type":"CREDIT_LIMIT","unit":3,"number":5,"percentage":0,"nextResetTime":1800018000000}]}}"#
                                .utf8))
                }), now: { clock.withLock { $0 } }, pricing: { .empty })

        let snapshot = await provider.refresh()

        XCTAssertEqual(snapshot.liveQuotaObservedAt, Self.now)
        XCTAssertEqual(try XCTUnwrap(provider.usageTimerObservations.first).observedAt, Self.now)
        XCTAssertEqual(clock.withLock { $0 }, Self.now.addingTimeInterval(120))
    }

    func testArgonOnlyUnusedQuotaDoesNotProbeCloudCodeOrDegradeLanguageServerResult() async {
        let body = Data(
            #"{"groups":[{"buckets":[{"bucketId":"gemini-5h","remainingFraction":0.8},{"bucketId":"3p-5h","remainingFraction":0.8},{"bucketId":"gemini-argon-wtu-weekly","remainingFraction":1}]}]}"#
                .utf8)
        let routing = RoutingHTTPClient { request in
            if request.url.host == "127.0.0.1", request.url.path.hasSuffix("/RetrieveUserQuotaSummary") {
                return .init(statusCode: 200, headers: [:], body: body)
            }
            return .init(statusCode: 503, headers: [:], body: Data())
        }
        let provider = AntigravityProvider(
            authStore: AntigravityAuthStore(
                keychain: FakeKeychain(Self.keychainValue(refreshToken: "original")), files: FakeFiles(),
                now: { Self.now }),
            usageClient: AntigravityUsageClient(lsHTTP: routing, http: routing),
            discovery: LanguageServerDiscovery(processRunner: DiscoveryRunner(hasLS: true)),
            usageScan: { _, _ in nil }, now: { Self.now }, pricing: { .empty })

        let snapshot = await provider.refresh()

        XCTAssertNil(snapshot.errorCategory)
        XCTAssertNil(snapshot.warning)
        XCTAssertFalse(snapshot.isDegraded == true)
        XCTAssertEqual(snapshot.liveQuotaObservedAt, Self.now)
        XCTAssertTrue(provider.usageTimerObservations.isEmpty)
        XCTAssertTrue(routing.requests.allSatisfy { $0.url.host == "127.0.0.1" })
    }

    private nonisolated static func keychainValue(refreshToken: String) -> String {
        #"{"token":{"access_token":"test-access","refresh_token":"\#(refreshToken)","expiry":"2099-01-01T00:00:00Z"}}"#
    }

    private nonisolated static let summary = Data(
        #"""
        {"groups":[
          {"buckets":[
            {"bucketId":"gemini-5h","remainingFraction":1,"resetTime":"2027-01-15T13:00:00Z"},
            {"bucketId":"gemini-weekly","remainingFraction":1,"resetTime":"2027-01-22T08:00:00Z"},
            {"bucketId":"3p-5h","remainingFraction":1,"resetTime":"2027-01-15T13:00:00Z"},
            {"bucketId":"3p-weekly","remainingFraction":1,"resetTime":"2027-01-22T08:00:00Z"}
          ]}
        ]}
        """#.utf8)

    private final class LaunchProbe: UsageTimerCLIExecuting {
        var launchCount = 0
        var executionCount = 0
        func execute(
            _ configuration: UsageTimerCLIConfiguration,
            canLaunch: @escaping @MainActor () async -> Bool
        ) async -> UsageTimerExecutionResult {
            executionCount += 1
            guard await canLaunch() else { return .init(launched: false, completed: false) }
            launchCount += 1
            return .init(launched: true, completed: true)
        }
    }

    private struct DiscoveryRunner: ProcessRunning {
        let hasLS: Bool
        func run(
            executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval
        ) throws -> ProcessResult {
            guard hasLS else { return .init(exitCode: 0, stdout: "", stderr: "") }
            let output =
                executable.hasSuffix("/ps")
                ? "4276 /fixture/language_server --csrf_token test-token --app_data_dir antigravity\n"
                : "language_ 4276 user 6u IPv4 0x0 0t0 TCP 127.0.0.1:52168 (LISTEN)\n"
            return .init(exitCode: 0, stdout: output, stderr: "")
        }
    }
}
