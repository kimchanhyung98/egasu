import AppKit
import Darwin
import XCTest
@testable import Egasu

@MainActor
final class ProcessShutdownTests: XCTestCase {
    func testQuitWaitsForQwenQueryBeforeReplying() async throws {
        let owner = StreamingProcessOwner()
        let (_, pid) = try await startQwenQuery(owner: owner)
        XCTAssertEqual(kill(pid, 0), 0)
        guard TokenRotationShutdownGuard.isIdle else {
            return XCTFail("The isolated termination test requires no OAuth rotation")
        }
        defer { TokenRotationShutdownGuard.cancelTermination() }

        let replied = expectation(description: "The delegate replies after process cleanup")
        var replies: [Bool] = []
        let delegate = AppDelegate(processOwner: owner) { _, approved in
            XCTAssertTrue(owner.isIdle)
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
            replies.append(approved)
            replied.fulfill()
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateLater)
        XCTAssertTrue(replies.isEmpty)
        await fulfillment(of: [replied], timeout: 5)
        XCTAssertEqual(replies, [true])
    }

    func testImmediateQuitAlsoPreventsANewCommand() async throws {
        let fixture = try ProcessShutdownFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        guard TokenRotationShutdownGuard.isIdle else {
            return XCTFail("The isolated termination test requires no OAuth rotation")
        }
        defer { TokenRotationShutdownGuard.cancelTermination() }
        let owner = StreamingProcessOwner()
        let delegate = AppDelegate(processOwner: owner) { _, _ in
            XCTFail("An immediate termination must not send a deferred reply")
        }

        XCTAssertEqual(delegate.applicationShouldTerminate(.shared), .terminateNow)
        do {
            _ = try await StreamingProcessRunner(owner: owner).run(fixture.login.request)
            XCTFail("A new command must not launch after termination starts")
        } catch is CancellationError {
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started.pid").path))
        XCTAssertTrue(owner.isIdle)
        await owner.shutdown()
    }

    func testShutdownWaitsForOutputDrainsAndWakesEveryWaiter() async throws {
        let fixture = try ProcessShutdownFixture(command: "printf drain; exec /bin/sleep 30")
        let owner = StreamingProcessOwner()
        let entered = expectation(description: "Output processing is blocked")
        let release = DispatchSemaphore(value: 0)
        let query = Task {
            try await StreamingProcessRunner(owner: owner).run(fixture.login.request) { _ in
                entered.fulfill()
                release.wait()
            }
        }
        addTeardownBlock {
            release.signal()
            query.cancel()
            _ = try? await query.value
            await owner.shutdown()
            try FileManager.default.removeItem(at: fixture.directory)
        }
        let pid = try await fixture.waitForPID()
        await fulfillment(of: [entered], timeout: 5)
        var completions = 0
        let first = Task {
            await owner.shutdown(); completions += 1
        }
        let second = Task {
            await owner.shutdown(); completions += 1
        }

        let exited = await waitForExit(pid)
        XCTAssertTrue(exited)
        XCTAssertFalse(owner.isIdle)
        XCTAssertEqual(completions, 0)
        release.signal()
        await first.value
        await second.value

        XCTAssertEqual(completions, 2)
        XCTAssertTrue(owner.isIdle)
    }

    func testOwnerKeepsEveryRunnerAndDoesNotStopOtherOwners() async throws {
        let owner = StreamingProcessOwner()
        let (_, firstPID) = try await startQwenQuery(owner: owner)
        let (_, secondPID) = try await startQwenQuery(owner: owner)
        let other = StreamingProcessOwner()
        let (otherFixture, otherPID) = try await startQwenQuery(owner: other)

        await owner.shutdown()

        XCTAssertTrue(owner.isIdle)
        XCTAssertEqual(kill(firstPID, 0), -1)
        XCTAssertEqual(kill(secondPID, 0), -1)
        XCTAssertEqual(kill(otherPID, 0), 0)
        XCTAssertFalse(other.isIdle)
        var request = otherFixture.login.request
        request.executableURL = URL(fileURLWithPath: "/bin/echo")
        request.arguments = ["still available"]
        let result = try await StreamingProcessRunner(owner: other).run(request)
        XCTAssertEqual(result.output, "still available\n")
    }

    func testNaturalCompletionAndSpawnFailureReleaseRegistration() async throws {
        let fixture = try ProcessShutdownFixture(command: "exit 7")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = StreamingProcessOwner()
        let runner = StreamingProcessRunner(owner: owner)

        let result = try await runner.run(fixture.login.request)
        XCTAssertEqual(result.exitCode, 7)
        XCTAssertTrue(owner.isIdle)

        var missing = fixture.login.request
        missing.executableURL = fixture.directory.appendingPathComponent("missing")
        do {
            _ = try await runner.run(missing)
            XCTFail("The missing executable must fail")
        } catch {
            XCTAssertEqual((error as NSError).domain, NSPOSIXErrorDomain)
            XCTAssertEqual((error as NSError).code, Int(ENOENT))
        }
        XCTAssertTrue(owner.isIdle)
        await owner.shutdown()
    }

    func testOwnerPreservesRevokedTimerLaunchPermission() async throws {
        let fixture = try ProcessShutdownFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let owner = StreamingProcessOwner()
        let permission = StreamingProcessLaunchPermission()
        permission.revoke()

        do {
            _ = try await StreamingProcessLaunchPermission.$current.withValue(permission) {
                try await StreamingProcessRunner(owner: owner).run(fixture.login.request)
            }
            XCTFail("A revoked timer permission must still prevent the child launch")
        } catch is CancellationError {
        }
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("started.pid").path))
        XCTAssertTrue(owner.isIdle)
    }

    func testShutdownAndSpawnAdmissionAreSerialized() async throws {
        let owner = StreamingProcessOwner()
        let entered = expectation(description: "A launch has admission")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let launch = Task.detached {
            try owner.withLaunchPermission {
                entered.fulfill()
                release.wait()
                return pid_t(0)
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        let closing = expectation(description: "Termination starts")
        let closed = DispatchSemaphore(value: 0)
        let shutdown = Task.detached {
            closing.fulfill()
            owner.beginShutdown()
            closed.signal()
        }
        await fulfillment(of: [closing], timeout: 5)
        XCTAssertEqual(closed.wait(timeout: .now() + 0.05), .timedOut)
        release.signal()
        _ = try await launch.value
        await shutdown.value

        var startedAfterClosing = false
        XCTAssertThrowsError(
            try owner.withLaunchPermission {
                startedAfterClosing = true
                return pid_t(0)
            }
        ) { XCTAssertTrue($0 is CancellationError) }
        XCTAssertFalse(startedAfterClosing)
    }

    private func startQwenQuery(owner: StreamingProcessOwner) async throws -> (ProcessShutdownFixture, pid_t) {
        let fixture = try ProcessShutdownFixture()
        let cli = QwenCloudCLI(runner: StreamingProcessRunner(owner: owner))
        let query = Task { _ = try await cli.fetch(fixture.login) }
        addTeardownBlock {
            query.cancel()
            _ = try? await query.value
            await owner.shutdown()
            try FileManager.default.removeItem(at: fixture.directory)
        }
        return (fixture, try await fixture.waitForPID())
    }

    private func waitForExit(_ pid: pid_t) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if kill(pid, 0) == -1, errno == ESRCH { return true }
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return false }
        }
        return false
    }
}

private struct ProcessShutdownFixture: Sendable {
    let directory: URL

    init(command: String = "exec /bin/sleep 30") throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "EgasuTests.ProcessShutdown.\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("qwencloud")
        let script = """
            #!/bin/sh
            test "$*" = "subscription tokenplan status --edition individual --format json" || exit 4
            printf '%s\\n' "$$" > "$HOME/started.pid"
            \(command)
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
    }

    var login: QwenCloudCLI.Login {
        QwenCloudCLI.Login(
            request: StreamingProcessRequest(
                executableURL: directory.appendingPathComponent("qwencloud"),
                arguments: ["subscription", "tokenplan", "status", "--edition", "individual", "--format", "json"],
                environment: ["HOME": directory.path, "PATH": "/usr/bin:/bin"],
                currentDirectoryURL: directory, timeout: 45, outputLimit: 1024,
                captureStandardErrorSeparately: true
            ),
            credentialPresent: true, identityKey: nil
        )
    }

    func waitForPID() async throws -> pid_t {
        let marker = directory.appendingPathComponent("started.pid")
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: marker, encoding: .utf8),
                let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
            {
                return pid
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
}
