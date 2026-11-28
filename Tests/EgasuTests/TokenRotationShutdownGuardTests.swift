import XCTest
@testable import Egasu

@MainActor
final class TokenRotationShutdownGuardTests: XCTestCase {
    override func tearDown() {
        TokenRotationShutdownGuard.cancelTermination()
        super.tearDown()
    }

    func testPendingQuitCancelsNewRotationWithoutCountingIt() throws {
        TokenRotationShutdownGuard.beginTermination()

        XCTAssertThrowsError(try TokenRotationShutdownGuard.begin()) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)

        TokenRotationShutdownGuard.cancelTermination()
        try TokenRotationShutdownGuard.begin()
        XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
        TokenRotationShutdownGuard.end()
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
    }

    func testSlowQuitWarnsAndWaitsForAllRotations() async throws {
        try TokenRotationShutdownGuard.begin()
        try TokenRotationShutdownGuard.begin()
        TokenRotationShutdownGuard.beginTermination()
        TokenRotationShutdownGuard.end()
        let warned = expectation(description: "quit still waiting")
        let wait = Task {
            await TokenRotationShutdownGuard.waitForIdle(warnAfter: .milliseconds(50)) { warned.fulfill() }
            XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
        }

        await fulfillment(of: [warned], timeout: 3)
        XCTAssertFalse(TokenRotationShutdownGuard.isIdle)
        XCTAssertThrowsError(try TokenRotationShutdownGuard.begin())
        TokenRotationShutdownGuard.end()
        await wait.value
    }

    func testPendingQuitKeepsTheClaudeRefreshTokenUnsent() async {
        let now = EgasuISO8601.date(from: "2026-02-20T16:00:00.000Z")!
        let credential = """
            {"claudeAiOauth":{"accessToken":"stale-token","refreshToken":"refresh-1","expiresAt":4102444800000,
             "subscriptionType":"pro","scopes":["user:profile","user:inference"]}}
            """
        let files = FakeFiles([
            "/tmp/claude/.claude.json": claudeUsageTestIdentity(),
            "/tmp/claude/.credentials.json": credential
        ])
        let httpClient = RoutingHTTPClient { request in
            if request.url.absoluteString.hasSuffix("/api/oauth/usage") {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            XCTFail("종료 대기 중에는 refresh 요청을 보내지 않음")
            return HTTPResponse(statusCode: 500, headers: [:], body: Data())
        }
        let provider = ClaudeProvider(
            authStore: ClaudeAuthStore(
                environment: FakeEnvironment(["CLAUDE_CONFIG_DIR": "/tmp/claude"]),
                files: files,
                keychain: FakeKeychain(),
                now: { now }
            ),
            usageClient: ClaudeUsageClient(httpClient: httpClient),
            usageStateStore: isolatedClaudeUsageStore(),
            logUsageScanner: ClaudeLogFixture.scanner(home: nil),
            now: { now },
            pricing: { TestPricing.bundled }
        )
        TokenRotationShutdownGuard.beginTermination()

        _ = await provider.refresh()

        XCTAssertFalse(httpClient.requests.contains { $0.url.path.hasSuffix("/oauth/token") })
        XCTAssertEqual(files.files["/tmp/claude/.credentials.json"], credential, "저장된 refresh token 유지")
        XCTAssertTrue(TokenRotationShutdownGuard.isIdle)
    }
}

final class TerminationSignalHandlerTests: XCTestCase {
    func testSIGTERMAllowsMainActorToSaveBeforeAppKitExits() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = FileManager.default.temporaryDirectory.appendingPathComponent(
            "egasu-quit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: executable) }

        let compiler = Process()
        compiler.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        compiler.arguments = [
            "swiftc", "-swift-version", "6",
            root.appendingPathComponent("Sources/Egasu/Services/TokenRotationShutdownGuard.swift").path,
            root.appendingPathComponent("script/fixtures/claude_rotation_termination.swift").path, "-o", executable.path
        ]
        try compiler.run()
        compiler.waitUntilExit()
        guard compiler.terminationStatus == 0 else { return XCTFail("AppKit fixture compilation failed") }

        let fixture = Process()
        fixture.executableURL = executable
        let output = Pipe()
        fixture.standardOutput = output
        try fixture.run()
        fixture.waitUntilExit()
        XCTAssertEqual(fixture.terminationReason, .exit)
        XCTAssertEqual(fixture.terminationStatus, 0)
        XCTAssertEqual(
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "rotation saved\n")
    }

    func testSpawnedChildStillStopsOnSIGTERMAfterInstallation() throws {
        var previous = sigaction()
        guard sigaction(SIGTERM, nil, &previous) == 0 else { return XCTFail("signal disposition unavailable") }
        let source = TerminationSignalHandler.install {}
        defer {
            source.cancel()
            sigaction(SIGTERM, &previous, nil)
        }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        let arguments: [UnsafeMutablePointer<CChar>?] = [strdup("/bin/sleep"), strdup("5"), nil]
        defer { arguments.forEach { free($0) } }
        var pid: pid_t = 0
        let spawnResult = posix_spawn(&pid, "/bin/sleep", nil, &attributes, arguments, environ)
        guard spawnResult == 0, pid > 0 else { return XCTFail("posix_spawn failed: \(spawnResult)") }
        usleep(100_000)

        kill(pid, SIGTERM)
        var status: Int32 = 0
        var exited = false
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            if waitpid(pid, &status, WNOHANG) == pid {
                exited = true
                break
            }
            usleep(20_000)
        }
        if !exited {
            kill(pid, SIGKILL)
            waitpid(pid, &status, 0)
        }

        XCTAssertTrue(exited, "앱의 SIGTERM 처리가 자식 프로세스에 무시 상태로 상속되지 않음")
    }
}
