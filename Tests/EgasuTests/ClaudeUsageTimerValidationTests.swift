import Foundation
import XCTest
@testable import Egasu

@MainActor
final class ClaudeUsageTimerValidationTests: XCTestCase {
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

    func testVerificationCannotConfirmQuotaWhenStateSaveFails() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = await fixture.provider.refresh()
        let expected = try XCTUnwrap(fixture.provider.usageTimerObservations.first)
        let prepared = try await fixture.provider.prepareUsageTimer(expected, executors: fixture.executors)
        let session = try XCTUnwrap(prepared)
        fixture.files.blockNextStateSave = true

        let verified = try await session.verify()

        XCTAssertNil(verified)
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
                    body: Data(
                        #"{"five_hour":{"utilization":0},"seven_day":{"utilization":20}}"#.utf8))
            }
            provider = ClaudeProvider(
                authStore: auth, usageClient: ClaudeUsageClient(httpClient: http),
                usageStateStore: ClaudeUsageStateStore(directory: directory),
                logUsageScanner: ClaudeLogFixture.scanner(home: nil), includeSharedUsage: false,
                pricing: { TestPricing.bundled })
        }

        func remove() { try? FileManager.default.removeItem(at: directory) }
        nonisolated static func credential(_ token: String) -> String {
            #"{"claudeAiOauth":{"accessToken":"\#(token)","expiresAt":4102444800000,"scopes":["user:profile"]}}"#
        }
    }

    private final class StatefulFiles: TextFileAccessing, @unchecked Sendable {
        let directory: URL
        let base = FakeFiles([
            Fixture.credentialPath: Fixture.credential("file-token"), Fixture.metadataPath: Fixture.metadata
        ])
        var rotateAfterSaved = false
        var blockNextStateSave = false
        init(directory: URL) { self.directory = directory }
        func exists(_ path: String) -> Bool { base.exists(path) }
        func readText(_ path: String) throws -> String {
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
        func execute(
            _ configuration: UsageTimerCLIConfiguration, canLaunch: @escaping @MainActor () async -> Bool
        ) async -> UsageTimerExecutionResult {
            guard await canLaunch(), case .claude(let accessToken) = configuration else {
                return .init(launched: false, completed: false)
            }
            token = accessToken
            return .init(launched: true, completed: true)
        }
    }
}
