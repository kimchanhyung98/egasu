import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ClaudeUsageTimerValidationTests: XCTestCase {
    func testProfileOnlyTokenPreservesFreshQuotaWithoutSchedulingAMessage() async throws {
        for trigger in [RefreshTrigger.manual, .scheduled, .weeklyTimerCheck] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.files.base.files[Fixture.credentialPath] =
                Fixture.credential("file-token", scopes: ["user:profile"])

            let suite = "ClaudeProfileOnlyTimer.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let router = UsageTimerRouter(
                providers: [fixture.provider], isProviderEnabled: { _ in true },
                usageTimerSetting: UsageTimerSetting(defaults: defaults), cliExecutor: fixture.cli,
                store: UsageTimerAttemptStore(fileURL: fixture.directory.appendingPathComponent("attempts.json")),
                report: { _, _ in }, refresh: { _, _ in }, wait: { _ in })
            let snapshot = await ProviderRefreshContext.$isManual.withValue(trigger == .manual) {
                await fixture.provider.refresh()
            }
            router.receive(snapshot, trigger: trigger)
            await router.waitForPendingWork(providerIDs: [snapshot.providerID])

            XCTAssertNotNil(snapshot.line(label: "Session"))
            XCTAssertNotNil(snapshot.liveQuotaObservedAt)
            XCTAssertTrue(fixture.provider.usageTimerObservations.isEmpty)
            XCTAssertNil(fixture.cli.token)
        }
    }

    func testRotatedProfileOnlyCredentialDeliversLiveQuotaAndCannotScheduleAMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.files.base.files[Fixture.credentialPath] = """
            {"claudeAiOauth":{"accessToken":"file-token","refreshToken":"refresh","expiresAt":1,
             "scopes":["user:profile","user:inference"]}}
            """

        let snapshot = await fixture.provider.refresh()

        XCTAssertTrue(fixture.http.requests.contains { $0.url.path == "/v1/oauth/token" })
        XCTAssertTrue(
            fixture.http.requests.contains {
                $0.url.path == "/api/oauth/usage" && $0.headers["Authorization"] == "Bearer fresh"
            })
        let stored = try fixture.files.readText(Fixture.credentialPath)
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(stored)?.claudeAiOauth?.scopes, ["user:profile"])
        XCTAssertNotNil(snapshot.liveQuotaObservedAt)
        XCTAssertNotNil(snapshot.line(label: "Weekly"))
        XCTAssertTrue(fixture.provider.usageTimerObservations.isEmpty)
        XCTAssertNil(fixture.cli.token)
    }

    func testOmittedEmptyAndUnrecognizedScopesKeepExistingTimerBehavior() async throws {
        for scopes in [nil, [], ["user:profile", "future:scope"]] as [[String]?] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.files.base.files[Fixture.credentialPath] = Fixture.credential("file-token", scopes: scopes)

            _ = await fixture.provider.refresh()
            let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            let session = try XCTUnwrap(prepared)
            let result = await session.send { true }

            XCTAssertTrue(result.completed)
            XCTAssertEqual(fixture.cli.token, "file-token")
        }
    }

    func testDroppingInferenceScopeSkipsPreparedMessageEvenIfTheAccountTokenRotated() async throws {
        for token in ["file-token", "rotated-token"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = await fixture.provider.refresh()
            let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            let session = try XCTUnwrap(prepared)
            fixture.files.base.files[Fixture.credentialPath] = Fixture.credential(token, scopes: ["user:profile"])

            let result = await session.send { true }

            XCTAssertFalse(result.launched)
            XCTAssertTrue(result.loginNoLongerEligible)
            XCTAssertNil(result.failureDescription)
            XCTAssertNil(fixture.cli.token)
            let rechecked = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            XCTAssertNil(rechecked)
        }
    }

    func testProfileOnlyChangeBeforeLaunchDoesNotConsumeTimerSendLimit() async throws {
        try await verifyProfileOnlyChangeBeforeLaunch(invalidateBinding: false)
    }

    func testProfileOnlyChangeDuringBindingInvalidationPreservesTimerSendLimit() async throws {
        try await verifyProfileOnlyChangeBeforeLaunch(invalidateBinding: true)
    }

    private func verifyProfileOnlyChangeBeforeLaunch(invalidateBinding: Bool) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let snapshot = await fixture.provider.refresh()
        let observation = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
        let store = UsageTimerAttemptStore(fileURL: fixture.directory.appendingPathComponent("attempts.json"))
        let previousSendDate = observation.observedAt.addingTimeInterval(-600)
        var previousSend = try XCTUnwrap(
            store.begin(
                accountKey: observation.storageKey, resetBefore: nil, now: previousSendDate,
                budgetWindow: observation.budgetWindow))
        previousSend.execution = .completed
        previousSend.messageLaunched = true
        try store.update(accountKey: observation.storageKey, attempt: previousSend)

        let suite = "ClaudeLaunchScopeChange.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var warnings: [[String]] = []
        let router = UsageTimerRouter(
            providers: [fixture.provider], isProviderEnabled: { _ in true },
            usageTimerSetting: UsageTimerSetting(defaults: defaults), cliExecutor: fixture.cli, store: store,
            report: { _, messages in
                if let messages { warnings.append(messages) }
            },
            refresh: { _, _ in }, wait: { _ in })
        let checkingLogin = expectation(description: "CLI launch rechecks the saved login")
        let finishLoginCheck = DispatchSemaphore(value: 0)
        fixture.cli.beforeLaunchCheck = { [files = fixture.files] in
            files.base.files[Fixture.credentialPath] =
                Fixture.credential("rotated-token", scopes: ["user:profile"])
            files.beforeCredentialRead = {
                checkingLogin.fulfill()
                _ = finishLoginCheck.wait(timeout: .now() + 8)
            }
        }

        router.receive(snapshot, trigger: .manual)
        await fulfillment(of: [checkingLogin], timeout: 5)
        if invalidateBinding { router.invalidate(providerIDs: [snapshot.providerID]) }
        finishLoginCheck.signal()
        await router.waitForPendingWork(providerIDs: [snapshot.providerID])

        let attempt = try XCTUnwrap(store.attempt(for: observation.storageKey))
        XCTAssertNotEqual(attempt.id, previousSend.id)
        XCTAssertNil(fixture.cli.token)
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertEqual(
            try store.sendLimitResetsAt(
                accountKey: observation.storageKey, now: attempt.notBefore, budgetWindow: observation.budgetWindow),
            invalidateBinding ? previousSendDate.addingTimeInterval(observation.budgetWindow) : nil)
    }

    func testReplacedTokenRequiresMatchingAccountAndOrganizationToSkipTheLoginWarning() async throws {
        let accountOnly = #"{"oauthAccount":{"accountUuid":"account-a"}}"#
        for (original, replacement) in [
            (Fixture.metadata, Fixture.metadata.replacingOccurrences(of: "test-org", with: "other-org")),
            (accountOnly, accountOnly)
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.files.base.files[Fixture.metadataPath] = original
            _ = await fixture.provider.refresh()
            let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            let session = try XCTUnwrap(prepared)
            fixture.files.base.files[Fixture.metadataPath] = replacement
            fixture.files.base.files[Fixture.credentialPath] = Fixture.credential(
                "other-token", scopes: ["user:profile"])

            let result = await session.send { true }

            XCTAssertFalse(result.launched)
            XCTAssertEqual(result.failureDescription, UsageTimerError.currentLoginRequired.errorDescription)
            XCTAssertNil(fixture.cli.token)
        }
    }

    func testStaleKeychainDoesNotHideSuccessfulFileCredentialDuringTimerPreparation() async throws {
        let fixture = try Fixture(staleKeychain: true)
        defer { fixture.remove() }
        _ = await fixture.provider.refresh()
        let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)

        let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
        let session = try XCTUnwrap(prepared)
        let result = await session.send { true }

        XCTAssertTrue(result.completed)
        XCTAssertEqual(fixture.cli.token, "file-token")
        XCTAssertTrue(fixture.http.requests.contains { $0.headers["Authorization"] == "Bearer stale" })
        XCTAssertEqual(fixture.keychain.currentUserValues, fixture.originalKeychain)
    }

    func testTokenReplacementWithUnchangedMetadataAfterQuotaSaveCannotPrepareMessage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = await fixture.provider.refresh()
        let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
        for url in try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        where url.pathExtension == "json" { try FileManager.default.removeItem(at: url) }
        fixture.files.rotateAfterSaved = true

        do {
            _ = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            XCTFail("A replacement token cannot use the old account's quota")
        } catch {
            XCTAssertEqual(error.localizedDescription, UsageTimerError.currentLoginRequired.localizedDescription)
        }

        XCTAssertFalse(fixture.files.rotateAfterSaved, "Rotation must happen after the successful quota save")
        XCTAssertNil(fixture.cli.token)
        XCTAssertEqual(try fixture.files.readText(Fixture.metadataPath), Fixture.metadata)
    }

    func testQuotaStateSaveFailurePublishesNoTimerCredentialOrObservation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = await fixture.provider.refresh()
        let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
        fixture.files.blockNextStateSave = true

        do {
            _ = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            XCTFail("A failed quota save must stop preparation")
        } catch {
            XCTAssertEqual(error.localizedDescription, UsageTimerError.usageUnavailable.localizedDescription)
        }

        XCTAssertTrue(fixture.provider.usageTimerObservations.isEmpty)
        XCTAssertNil(fixture.provider.usageTimerCredentialState)
        XCTAssertNil(fixture.cli.token)
    }

    func testMalformedWeeklyQuotaCannotPrepareOrLaunchAnAutomaticMessage() async throws {
        for weekly in [
            "unavailable", ["utilization": "unavailable"], ["utilization": -1],
            ["utilization": 0, "resets_at": -1]
        ] as [Any] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = await fixture.provider.refresh()
            let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            fixture.files.quotaBody = try JSONSerialization.data(withJSONObject: [
                "five_hour": ["utilization": 0], "seven_day": weekly
            ])

            do {
                let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
                if let prepared {
                    let result = await prepared.send { true }
                    XCTAssertFalse(result.launched)
                }
                XCTFail("Malformed Weekly quota must fail preparation")
            } catch {
                XCTAssertEqual(error.localizedDescription, UsageTimerError.usageUnavailable.localizedDescription)
            }

            XCTAssertTrue(fixture.provider.usageTimerObservations.isEmpty)
            XCTAssertNil(fixture.provider.usageTimerCredentialState)
            XCTAssertNil(fixture.cli.token)
        }
    }

    func testInvalidSessionResetOrNewlyUsedQuotaStopsPreparedMessage() async throws {
        for (session, weekly, invalidated) in [
            (#"{"utilization":0,"resets_at":-1}"#, 0, false),
            (#"{"utilization":0,"resets_at":"1969-12-31T23:59:59Z"}"#, 0, false),
            (#"{"utilization":0,"resets_at":"2099-01-01T00:00:00Z"}"#, 0, true),
            (#"{"utilization":1}"#, 0, true),
            (#"{"utilization":0}"#, 100, true)
        ] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = await fixture.provider.refresh()
            let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
            let timer = try XCTUnwrap(prepared)
            fixture.files.quotaBody = Data(
                """
                {"five_hour":\(session),"seven_day":{"utilization":\(weekly)}}
                """.utf8)

            let result = await timer.send { true }

            XCTAssertFalse(result.launched)
            XCTAssertNil(fixture.cli.token)
            XCTAssertEqual(result.launchObservationInvalidated, invalidated)
            XCTAssertEqual(
                result.failureDescription, invalidated ? nil : UsageTimerError.usageUnavailable.errorDescription)
        }
    }

    func testVerificationCannotConfirmQuotaWhenStateSaveFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = await fixture.provider.refresh()
        let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
        let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
        let session = try XCTUnwrap(prepared)
        fixture.files.blockNextStateSave = true

        do {
            _ = try await session.verify()
            XCTFail("A failed quota save cannot confirm a timer")
        } catch {
            XCTAssertEqual(error.localizedDescription, UsageTimerError.usageUnavailable.localizedDescription)
        }
        XCTAssertTrue(fixture.provider.usageTimerObservations.isEmpty)
        XCTAssertNil(fixture.provider.usageTimerCredentialState)
    }

    @MainActor
    private final class Fixture {
        nonisolated static let credentialPath = "/timer-fixture/.credentials.json"
        nonisolated static let metadataPath = "/timer-fixture/.claude.json"
        nonisolated static let metadata = #"{"oauthAccount":{"accountUuid":"account-a","organizationUuid":"test-org"}}"#
        let directory: URL
        let files: StatefulFiles
        let keychain = ServiceKeychain()
        let originalKeychain: [String: String]
        let http: RoutingHTTPClient
        let provider: ClaudeProvider
        let cli = CLI()
        var executors: UsageTimerExecutors { .init(codex: UsageTimerRouterTests.Executor(), cli: cli) }

        init(staleKeychain: Bool = false) throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "claude-timer-validation-\(UUID())")
            files = StatefulFiles(directory: directory)
            let auth = ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/timer-fixture"]), files: files,
                keychain: keychain, allowsDesktopFallback: false)
            if staleKeychain {
                keychain.currentUserValues[auth.keychainServiceCandidates().first!] = Self.credential("stale")
            }
            originalKeychain = keychain.currentUserValues
            let files = files
            http = RoutingHTTPClient { request in
                if request.url.path == "/v1/oauth/token" {
                    let body =
                        #"{"access_token":"fresh","refresh_token":"rotated","scope":"user:profile","expires_in":3600}"#
                    return .init(statusCode: 200, headers: [:], body: Data(body.utf8))
                }
                if request.headers["Authorization"] == "Bearer stale" {
                    return .init(statusCode: 401, headers: [:], body: Data())
                }
                if request.url.path.hasSuffix("/profile") {
                    return .init(
                        statusCode: 200, headers: [:],
                        body: Data(
                            #"{"account":{"uuid":"account-a"},"organization":{"uuid":"test-org"}}"#.utf8))
                }
                if files.blockNextStateSave {
                    files.blockNextStateSave = false
                    for url in try FileManager.default.contentsOfDirectory(
                        at: files.directory, includingPropertiesForKeys: nil)
                    where url.pathExtension == "json" {
                        try FileManager.default.removeItem(at: url)
                        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
                    }
                }
                return .init(
                    statusCode: 200, headers: [:],
                    body: files.quotaBody
                        ?? Data(
                            #"{"five_hour":{"utilization":0},"seven_day":{"utilization":20}}"#.utf8))
            }
            provider = ClaudeProvider(
                authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                usageStateStore: ClaudeUsageStateStore(directory: directory),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
                pricing: { TestPricing.bundled })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
        nonisolated static func credential(_ token: String, scopes: [String]? = ["user:profile", "user:inference"])
            -> String
        {
            let oauth = ClaudeOAuth(accessToken: token, expiresAt: 4_102_444_800_000, scopes: scopes)
            let data = try! JSONEncoder().encode(ClaudeCredentialsFile(claudeAiOauth: oauth))
            return String(decoding: data, as: UTF8.self)
        }
    }

    private final class StatefulFiles: TextFileAccessing, @unchecked Sendable {
        let directory: URL
        let base = FakeFiles([
            Fixture.credentialPath: Fixture.credential("file-token"), Fixture.metadataPath: Fixture.metadata
        ])
        var rotateAfterSaved = false
        var blockNextStateSave = false
        var beforeCredentialRead: (@Sendable () -> Void)?
        var quotaBody: Data?
        init(directory: URL) { self.directory = directory }
        func exists(_ path: String) -> Bool { base.exists(path) }
        func readText(_ path: String) throws -> String {
            if path == Fixture.credentialPath, let beforeCredentialRead {
                self.beforeCredentialRead = nil
                beforeCredentialRead()
            }
            if rotateAfterSaved, path == Fixture.credentialPath,
                let contents = try? FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil),
                contents.contains(where: { $0.pathExtension == "json" })
            {
                rotateAfterSaved = false
                base.files[path] = Fixture.credential("replacement-token")
            }
            return try base.readText(path)
        }
        func writeText(_ path: String, _ text: String) throws { try base.writeText(path, text) }
        func remove(_ path: String) throws { try base.remove(path) }
    }

    private final class CLI: UsageTimerCLIExecuting {
        var token: String?
        var beforeLaunchCheck: (() -> Void)?

        func execute(
            _ configuration: UsageTimerCLIConfiguration, canLaunch: @escaping @MainActor () async -> Bool
        ) async -> UsageTimerExecutionResult {
            beforeLaunchCheck?()
            guard await canLaunch(), case .claude(let accessToken) = configuration else {
                return .init(launched: false, completed: false)
            }
            token = accessToken
            return .init(launched: true, completed: true)
        }
    }
}
