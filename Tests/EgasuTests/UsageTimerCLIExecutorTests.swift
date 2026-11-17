import Foundation
import XCTest
@testable import Egasu

@MainActor
final class UsageTimerCLIExecutorTests: XCTestCase {
    func testSavedClaudeAccountStartsWithItsOwnTokenAndLeavesSharedLoginUnchanged() async throws {
        let fixture = try claudeFixture()
        let before = fixture.keychain.currentUserValues
        let runner = Runner(outputs: [Self.help, #"{"type":"result","is_error":false}"#])
        let executor = UsageTimerCLIExecutor(runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/claude") })
        _ = await fixture.provider.refresh()
        let observation = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
        let prepared = try await fixture.provider.prepareUsageTimer(
            observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: executor)
        )
        let session = try XCTUnwrap(prepared)

        let result = await session.send { true }

        XCTAssertTrue(result.completed)
        let requests = await runner.requests
        let request = try XCTUnwrap(requests.last)
        XCTAssertEqual(request.environment["CLAUDE_CODE_OAUTH_TOKEN"], "saved-token")
        XCTAssertEqual(request.environment["HOME"], request.currentDirectoryURL?.path)
        XCTAssertEqual(request.environment["CLAUDE_CONFIG_DIR"], request.currentDirectoryURL?.path)
        XCTAssertFalse(request.arguments.joined().contains("saved-token"))
        XCTAssertNil(request.environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(fixture.keychain.currentUserValues, before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(request.currentDirectoryURL).path))
    }

    func testClaudeModelSpecificLimitsDoNotBlockHaikuSessionStart() async throws {
        for (fable, sonnet) in [(100.0, 0.0), (0.0, 100.0)] {
            let fixture = try claudeFixture(fableUsed: fable, sonnetUsed: sonnet)
            let snapshot = await fixture.provider.refresh()

            XCTAssertTrue(UsageTimerObservation.hasExhaustedQuota(snapshot.lines))
            let observation = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            XCTAssertTrue(observation.canStart(at: Date()))
            XCTAssertEqual(observation.timerID, "claude.session")
        }
    }

    func testClaudeSharedWeeklyLimitStillBlocksSessionStart() async throws {
        let fixture = try claudeFixture(weeklyUsed: 100)

        _ = await fixture.provider.refresh()

        XCTAssertTrue(fixture.provider.usageTimerObservations.isEmpty)
    }

    func testSavedClaudeCredentialRemovalOrRotationStopsPreparedMessage() async throws {
        for remove in [true, false] {
            let fixture = try claudeFixture()
            let runner = Runner(outputs: [Self.help])
            let executor = UsageTimerCLIExecutor(runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/claude") })
            _ = await fixture.provider.refresh()
            let observation = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
            let prepared = try await fixture.provider.prepareUsageTimer(
                observation, executors: .init(codex: UsageTimerRouterTests.Executor(), cli: executor)
            )
            let session = try XCTUnwrap(prepared)
            let vault = AccountCredentialVault(keychain: fixture.keychain)
            if remove {
                try vault.delete(profile: fixture.profile)
            } else {
                var entry = try XCTUnwrap(vault.load(family: "claude", profileID: fixture.profile.id))
                entry.credential = entry.credential.replacingOccurrences(of: "saved-token", with: "rotated-token")
                try vault.save(entry, profile: fixture.profile)
            }

            let result = await session.send { true }

            XCTAssertFalse(result.launched)
            XCTAssertFalse(result.completed)
            let requests = await runner.requests
            XCTAssertEqual(requests.map(\.arguments), [["--help"]])
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: try XCTUnwrap(requests.first?.currentDirectoryURL).path))
        }
    }

    private func claudeFixture(
        weeklyUsed: Double = 66, fableUsed: Double = 80, sonnetUsed: Double = 0
    ) throws -> (provider: ClaudeProvider, keychain: ServiceKeychain, profile: AccountProfile) {
        let keychain = ServiceKeychain()
        let profile = AccountProfile(
            id: "timer-saved", family: "claude", label: "Saved",
            identityKey: "saved|org", createdAt: .distantPast)
        let credential =
            #"{"claudeAiOauth":{"accessToken":"saved-token","expiresAt":4102444800000,"scopes":["user:profile","user:inference"]}}"#
        try AccountCredentialVault(keychain: keychain).save(
            .init(
                credential: credential,
                claudeOAuthAccount: #"{"accountUuid":"saved","organizationUuid":"org"}"#
            ), profile: profile)
        let environment = FakeEnvironment([:])
        keychain.currentUserValues[ClaudeAuthStore.baseKeychainServiceName(environment: environment)] =
            #"{"claudeAiOauth":{"accessToken":"other-account-token"}}"#
        let body: [String: Any] = [
            "five_hour": ["utilization": 0, "resets_at": NSNull()],
            "seven_day": ["utilization": weeklyUsed, "resets_at": "2099-01-01T00:00:00Z"],
            "seven_day_sonnet": ["utilization": sonnetUsed, "resets_at": "2099-01-01T00:00:00Z"],
            "limits": [
                [
                    "kind": "weekly_scoped", "scope": ["model": ["display_name": "Fable"]],
                    "percent": fableUsed, "resets_at": "2099-01-01T00:00:00Z"
                ]
            ]
        ]
        let response = HTTPResponse(
            statusCode: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: body))
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: environment, files: FakeFiles(), keychain: keychain,
                scope: .accountSnapshot(profileID: profile.id)),
            usageClient: ClaudeUsageClient(httpClient: FakeHTTPClient(response: response)),
            usageStateStore: isolatedClaudeUsageStore(), logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            includeSharedUsage: false, pricing: { TestPricing.bundled }
        )
        return (provider, keychain, profile)
    }

    func testClaudeIsolatesAccountTokenAndDisablesTools() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try UsageTimerCLIExecutor().makeRequest(
            .claude(accessToken: "test-token"), executable: URL(fileURLWithPath: "/test/claude-cli"),
            directory: directory
        )
        XCTAssertEqual(request.environment["CLAUDE_CONFIG_DIR"], directory.path)
        XCTAssertNil(request.environment["ANTHROPIC_API_KEY"])
        XCTAssertEqual(request.environment["CLAUDE_CODE_OAUTH_TOKEN"], "test-token")
        XCTAssertFalse(request.arguments.joined().contains("test-token"))
        XCTAssertTrue(request.arguments.contains("--no-session-persistence"))
        XCTAssertEqual(request.arguments[try XCTUnwrap(request.arguments.firstIndex(of: "--tools")) + 1], "")
        XCTAssertTrue(request.arguments.contains(#"{"disableAllHooks":true,"autoMemoryEnabled":false}"#))
    }

    func testKimiCredentialsStayOutOfArgumentsAndConfigFiles() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try UsageTimerCLIExecutor().makeRequest(
            .kimi(accessToken: "test-private-token"), executable: URL(fileURLWithPath: "/test/kimi"),
            directory: directory
        )
        XCTAssertFalse(request.arguments.joined().contains("test-private-token"))
        XCTAssertEqual(request.environment["EGASU_KIMI_TOKEN"], "test-private-token")
        XCTAssertEqual(request.environment["KIMI_CODE_HOME"], directory.path)
        let config = try String(contentsOf: directory.appendingPathComponent("config.toml"), encoding: .utf8)
        XCTAssertFalse(config.contains("test-private-token"))
        XCTAssertTrue(config.contains("api_key_env = \"EGASU_KIMI_TOKEN\""))
        XCTAssertTrue(config.contains("telemetry = false"))
        XCTAssertTrue(config.contains("https://api.kimi.com/coding/v1"))
        let agent = try String(contentsOf: directory.appendingPathComponent("timer.md"), encoding: .utf8)
        XCTAssertTrue(agent.contains("tools: []"))
        XCTAssertTrue(agent.hasPrefix("---\nname: timer\n"))
        XCTAssertTrue(request.arguments.contains("--prompt"))
        XCTAssertFalse(request.arguments.contains("--print"))
    }

    func testZAIUsesCodingPlanThroughBareClaudeCLI() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try UsageTimerCLIExecutor().makeRequest(
            .zai(apiKey: "test-key"), executable: URL(fileURLWithPath: "/test/claude"), directory: directory
        )
        XCTAssertEqual(request.environment["ANTHROPIC_BASE_URL"], "https://api.z.ai/api/anthropic")
        XCTAssertEqual(request.environment["HOME"], directory.path)
        XCTAssertEqual(request.environment["ANTHROPIC_AUTH_TOKEN"], "test-key")
        XCTAssertNil(request.environment["ANTHROPIC_API_KEY"])
        XCTAssertTrue(request.arguments.contains("--bare"))
        XCTAssertFalse(request.arguments.joined().contains("test-key"))
    }

    func testAntigravityIsolatesSettingsAndRequiresReviewForEveryTool() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let request = try UsageTimerCLIExecutor().makeRequest(
            .antigravity(model: "gemini-"), executable: URL(fileURLWithPath: "/test/agy"), directory: directory
        )
        XCTAssertEqual(request.environment["HOME"], directory.path)
        let settings = try Data(contentsOf: directory.appendingPathComponent(".gemini/antigravity-cli/settings.json"))
        XCTAssertEqual(ProviderParse.jsonObject(settings)?["toolPermission"] as? String, "strict")
        XCTAssertEqual(ProviderParse.jsonObject(settings)?["historySize"] as? Int, 0)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: directory.appendingPathComponent("Library/Keychains").path),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Keychains").path
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".gemini/config").path))
        XCTAssertNil(request.environment["GEMINI_API_KEY"])
        XCTAssertNil(request.environment["GOOGLE_APPLICATION_CREDENTIALS"])
    }

    func testIdentityChangeBlocksMessageAndCleansWorkspace() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = Runner(outputs: [Self.help])
        let executor = UsageTimerCLIExecutor(
            runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/cli") }, baseDirectory: directory)
        let result = await executor.execute(.claude(accessToken: "test-token"), canLaunch: { false })
        XCTAssertFalse(result.launched)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.arguments, ["--help"])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func testOnlySuccessfulCLIResultCountsAsCompletion() async throws {
        for (body, expected) in [
            (#"{"type":"result","is_error":false}"#, true),
            (#"{"type":"result","is_error":true}"#, false), ("OK", false)
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = Runner(outputs: [Self.help, body])
            let executor = UsageTimerCLIExecutor(
                runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/cli") }, baseDirectory: directory)
            let result = await executor.execute(.claude(accessToken: "test-token"), canLaunch: { true })
            XCTAssertTrue(result.launched)
            XCTAssertEqual(result.completed, expected)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testAntigravitySelectsAvailableModelWithinRequestedPool() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let runner = Runner(outputs: [
            Self.help, "gemini-3.8-flash-medium Gemini\nclaude-sonnet-5-5-medium Claude", #"{"status":"SUCCESS"}"#
        ])
        let executor = UsageTimerCLIExecutor(
            runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/agy") }, baseDirectory: directory)
        let result = await executor.execute(.antigravity(model: "claude-"), canLaunch: { true })
        XCTAssertTrue(result.completed)
        let requests = await runner.requests
        XCTAssertEqual(requests[1].arguments, ["models"])
        XCTAssertTrue(requests[2].arguments.contains("claude-sonnet-5-5-medium"))
    }

    func testAntigravityAcceptsHelpWrittenToStandardError() async throws {
        let runner = Runner(results: [
            .init(exitCode: 0, output: "", standardError: Self.help),
            .init(exitCode: 0, output: "gemini-3.8-flash-medium Gemini"),
            .init(exitCode: 0, output: #"{"status":"SUCCESS"}"#)
        ])
        let executor = UsageTimerCLIExecutor(runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/agy") })
        let result = await executor.execute(.antigravity(model: "gemini-"), canLaunch: { true })
        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.completed)
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 3)
    }

    func testUnsupportedCLIReportsCompatibilityInsteadOfLoginFailure() async {
        let runner = Runner(outputs: ["--help"])
        let executor = UsageTimerCLIExecutor(runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/agy") })
        let result = await executor.execute(.antigravity(model: "gemini-"), canLaunch: { true })
        XCTAssertFalse(result.launched)
        XCTAssertEqual(
            result.failureDescription,
            "Usage timer requires the provider's current CLI. Install or update it and refresh.")
    }

    func testModelListingFailureDoesNotLaunchMessageOrReportIncompatibleCLI() async {
        let runner = Runner(results: [
            .init(exitCode: 0, output: "", standardError: Self.help),
            .init(exitCode: 1, output: "", standardError: "Please sign in")
        ])
        let executor = UsageTimerCLIExecutor(runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/agy") })
        let result = await executor.execute(.antigravity(model: "gemini-"), canLaunch: { true })
        XCTAssertFalse(result.launched)
        XCTAssertEqual(
            result.failureDescription, "Usage timer could not load the CLI model list. Check the CLI login and refresh."
        )
        let requests = await runner.requests
        XCTAssertEqual(requests.count, 2)
    }

    func testLaunchBoundaryKeepsSpawnFailuresRefundableAndChargesCancellationOrTimeout() async throws {
        for mode in LaunchBoundaryRunner.Mode.allCases {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = LaunchBoundaryRunner(mode: mode, help: Self.help)
            let executor = UsageTimerCLIExecutor(
                runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/cli") }, baseDirectory: directory
            )

            let result = await executor.execute(.claude(accessToken: "test-token"), canLaunch: { true })

            XCTAssertEqual(result.launched, mode != .beforeSpawn, "\(mode)")
            XCTAssertFalse(result.completed)
            let requests = await runner.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests.first?.arguments, ["--help"])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testGeminiTimerSkipsModelsWithTheSeparateArgonQuota() async throws {
        for listing in [
            "gemini-4-argon-high Argon\ngemini-4-carbon-low Carbon",
            "gemini-pro-orchestrator-argon Argon\ngemini-4-carbon-low Carbon",
            "gemini-4-argon-high Argon"
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = Runner(outputs: [Self.help, listing, #"{"status":"SUCCESS"}"#])
            let executor = UsageTimerCLIExecutor(
                runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/agy") }, baseDirectory: directory
            )

            let result = await executor.execute(.antigravity(model: "gemini-"), canLaunch: { true })

            let requests = await runner.requests
            if listing.contains("carbon") {
                XCTAssertTrue(result.completed)
                XCTAssertEqual(requests.count, 3)
                XCTAssertTrue(requests[2].arguments.contains("gemini-4-carbon-low"))
            } else {
                XCTAssertFalse(result.launched)
                XCTAssertEqual(requests.count, 2)
                XCTAssertEqual(result.failureDescription, "Usage timer could not select the requested model.")
            }
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testOtherAntigravityPoolCanUseGPTOSSWithoutClaudeModel() async throws {
        let runner = Runner(outputs: [Self.help, "gpt-oss-120b GPT OSS", #"{"status":"SUCCESS"}"#])
        let executor = UsageTimerCLIExecutor(runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/agy") })

        let result = await executor.execute(.antigravity(model: "claude-"), canLaunch: { true })

        XCTAssertTrue(result.completed)
        let requests = await runner.requests
        XCTAssertTrue(try XCTUnwrap(requests.last).arguments.contains("gpt-oss-120b"))
    }

    func testProcessPATHKeepsInterpreterAvailableWhenLoginShellCaptureIsUnavailable() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let interpreter = directory.appendingPathComponent("node")
        let executable = directory.appendingPathComponent("claude")
        try Data("#!/usr/bin/env node\n".utf8).write(to: executable)
        let script = """
            #!/bin/sh
            if [ "$2" = "--help" ]; then
              printf '%s\\n' '--print --output-format --model'
            else
              printf '%s\\n' '{"type":"result","is_error":false}'
            fi
            """
        try Data(script.utf8).write(to: interpreter)
        for url in [interpreter, executable] {
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        }
        let executor = UsageTimerCLIExecutor(
            resolve: { _ in executable }, baseDirectory: directory,
            shellEnvironment: LoginShellEnvironment(runner: UnavailableShellRunner()),
            environment: FakeEnvironment(["PATH": directory.path])
        )

        let result = await executor.execute(.claude(accessToken: "fixture-token"), canLaunch: { true })

        XCTAssertTrue(result.launched)
        XCTAssertTrue(result.completed)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)), ["node", "claude"])
    }

    func testKimiTwoXUsesPromptModeAndRequiresSuccessfulAssistantOutput() async throws {
        for (version, body, expected) in [
            ("2.0.1", #"{"role":"assistant","content":"OK"}"#, true),
            ("2.6.0", #"{"role":"assistant","content":"OK"}"#, true),
            ("2.6.0", #"{"role":"tool","content":"OK"}"#, false), ("2.6.0", "OK", false)
        ] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = Runner(outputs: [Self.help, version, body])
            let executor = UsageTimerCLIExecutor(
                runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/kimi") }, baseDirectory: directory)

            let result = await executor.execute(.kimi(accessToken: "fixture-token"), canLaunch: { true })

            XCTAssertTrue(result.launched)
            XCTAssertEqual(result.completed, expected)
            let requests = await runner.requests
            XCTAssertEqual(requests.map(\.arguments).prefix(2), [["--help"], ["--version"]])
            XCTAssertFalse(try XCTUnwrap(requests.last).arguments.contains("--print"))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    func testPythonKimiOrUnknownVersionCannotLaunchOrConsumeMessageAttempt() async throws {
        for version in ["1.46.0", "kimi, version 1.46.0", "2.0.0", "2.bad.6.1", "unknown"] {
            let directory = try temporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let runner = Runner(outputs: [Self.help, version])
            let executor = UsageTimerCLIExecutor(
                runner: runner, resolve: { _ in URL(fileURLWithPath: "/test/kimi") }, baseDirectory: directory)

            let result = await executor.execute(.kimi(accessToken: "fixture-token"), canLaunch: { true })

            XCTAssertFalse(result.launched)
            XCTAssertFalse(result.completed)
            XCTAssertEqual(
                result.failureDescription,
                "Usage timer requires the provider's current CLI. Install or update it and refresh.")
            let requests = await runner.requests
            XCTAssertEqual(requests.map(\.arguments), [["--help"], ["--version"]])
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
        }
    }

    private struct UnavailableShellRunner: ProcessRunning {
        func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) throws
            -> ProcessResult
        {
            .init(exitCode: 1, stdout: "", stderr: "")
        }
    }

    private actor LaunchBoundaryRunner: StreamingProcessRunning {
        enum Mode: CaseIterable, Sendable { case beforeSpawn, cancellation, timeout }
        let mode: Mode
        let help: String
        var requests: [StreamingProcessRequest] = []

        init(mode: Mode, help: String) { self.mode = mode; self.help = help }

        func run(
            _ request: StreamingProcessRequest, onOutput: @escaping @Sendable (String) -> Void
        ) async throws -> StreamingProcessResult {
            try await run(request, onLaunch: {}, onOutput: onOutput)
        }

        func run(
            _ request: StreamingProcessRequest, onLaunch: @escaping @Sendable () -> Void,
            onOutput: @escaping @Sendable (String) -> Void
        ) async throws -> StreamingProcessResult {
            requests.append(request)
            if request.arguments == ["--help"] { return .init(exitCode: 0, output: help) }
            if mode == .beforeSpawn { throw CocoaError(.fileNoSuchFile) }
            onLaunch()
            if mode == .cancellation { throw CancellationError() }
            throw StreamingProcessRunnerError.timedOut(timeout: request.timeout)
        }
    }

    private static let help = "--print --prompt --output-format --model --agent-file --skills-dir"
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private actor Runner: StreamingProcessRunning {
        var results: [StreamingProcessResult]
        var requests: [StreamingProcessRequest] = []
        init(outputs: [String]) { self.results = outputs.map { .init(exitCode: 0, output: $0) } }
        init(results: [StreamingProcessResult]) { self.results = results }
        func run(_ request: StreamingProcessRequest, onOutput: @escaping @Sendable (String) -> Void) async throws
            -> StreamingProcessResult
        {
            requests.append(request)
            return results.removeFirst()
        }
    }
}
