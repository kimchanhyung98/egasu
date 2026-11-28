import Darwin
import Observation
import XCTest
@testable import Egasu

@MainActor
final class AccountAddSignInShutdownTests: XCTestCase {
    func testShutdownBeforeTheOperationStartsCancelsItAndRejectsNewLogins() async throws {
        let state = try makeState()
        var started = false
        let task = try XCTUnwrap(state.startAddingAccount { started = true })
        addTeardownBlock {
            task.cancel(); await task.value
        }

        let pending = state.beginSignInShutdown()

        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(state.hasRunningAccountSignIn)
        XCTAssertTrue(state.isSigningInForNewAccount)
        XCTAssertNil(state.startAddingAccount { XCTFail("Shutdown must reject another account") })
        XCTAssertNil(state.startReSignIn(for: "saved") { XCTFail("Shutdown must reject re-sign-in") })
        for task in pending { await task.value }
        XCTAssertFalse(started)
        XCTAssertFalse(state.hasRunningAccountSignIn)
        XCTAssertFalse(state.isSigningInForNewAccount)
    }

    func testShutdownWithoutWorkStillRejectsBothSignInKinds() throws {
        let state = try makeState()

        XCTAssertTrue(state.beginSignInShutdown().isEmpty)
        XCTAssertNil(state.startAddingAccount { XCTFail("Shutdown must reject another account") })
        XCTAssertNil(state.startReSignIn(for: "saved") { XCTFail("Shutdown must reject re-sign-in") })
    }

    func testHideAndShowBeforeTheOperationStartsClosesTheSheetSynchronously() async throws {
        let state = try makeState()
        state.isAddingAccount = true
        var started = false
        let task = try XCTUnwrap(state.startAddingAccount { started = true })
        addTeardownBlock {
            task.cancel(); await task.value
        }

        state.popoverShown = false
        state.popoverShown = true

        XCTAssertFalse(state.isAddingAccount)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(state.isSigningInForNewAccount)
        XCTAssertTrue(state.hasRunningAccountSignIn)
        XCTAssertNil(state.startAddingAccount { XCTFail("The previous task still owns cleanup") })
        await task.value
        XCTAssertFalse(started)
        XCTAssertFalse(state.isSigningInForNewAccount)
        let next = try XCTUnwrap(state.startAddingAccount {})
        await next.value
    }

    func testReopeningDuringCleanupKeepsBothStartButtonsBlockedAndObservesCompletion() async throws {
        let state = try makeState()
        state.isAddingAccount = true
        let gate = Gate()
        let started = expectation(description: "operation started")
        let observedStart = expectation(description: "account-add progress became observable")
        withObservationTracking {
            XCTAssertFalse(state.isSigningInForNewAccount)
        } onChange: {
            observedStart.fulfill()
        }
        var cleaned = false
        let task = try XCTUnwrap(
            state.startAddingAccount {
                defer { cleaned = true }
                started.fulfill()
                await gate.wait()
            })
        addTeardownBlock { @MainActor in
            task.cancel()
            gate.open()
            await task.value
        }
        await fulfillment(of: [started, observedStart], timeout: 2)
        let observedCompletion = expectation(description: "cleanup completion became observable")
        withObservationTracking {
            XCTAssertTrue(state.isSigningInForNewAccount)
        } onChange: {
            observedCompletion.fulfill()
        }

        state.popoverShown = false
        state.popoverShown = true

        XCTAssertFalse(state.isAddingAccount)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(state.isSigningInForNewAccount)
        XCTAssertFalse(cleaned)
        XCTAssertNil(state.startAddingAccount { XCTFail("The previous task still owns cleanup") })
        XCTAssertTrue(
            ManagedAccountSignInStep.blocksAdding(
                isSwitching: false, hasUnreadableRegistry: false, activeProfileCount: 0,
                isSigningInForNewAccount: state.isSigningInForNewAccount))
        gate.open()
        await task.value
        await fulfillment(of: [observedCompletion], timeout: 2)
        XCTAssertTrue(cleaned)
        XCTAssertFalse(state.isSigningInForNewAccount)
        XCTAssertFalse(
            ManagedAccountSignInStep.blocksAdding(
                isSwitching: false, hasUnreadableRegistry: false, activeProfileCount: 0,
                isSigningInForNewAccount: state.isSigningInForNewAccount))
        let next = try XCTUnwrap(state.startAddingAccount {})
        await next.value
    }

    func testShutdownReturnsBothSignInTasksAndWaitsForBothCleanups() async throws {
        let state = try makeState()
        let addGate = Gate()
        let reSignInGate = Gate()
        let started = expectation(description: "both login operations started")
        started.expectedFulfillmentCount = 2
        let addCleaned = expectation(description: "account-add cleanup finished")
        var reSignInCleaned = false
        let addition = try XCTUnwrap(
            state.startAddingAccount {
                defer { addCleaned.fulfill() }
                started.fulfill()
                await addGate.wait()
            })
        let reSignIn = try XCTUnwrap(
            state.startReSignIn(for: "saved") {
                defer { reSignInCleaned = true }
                started.fulfill()
                await reSignInGate.wait()
            })
        addTeardownBlock { @MainActor in
            addition.cancel()
            reSignIn.cancel()
            addGate.open()
            reSignInGate.open()
            await addition.value
            await reSignIn.value
        }
        await fulfillment(of: [started], timeout: 2)

        let pending = state.beginSignInShutdown()
        let repeated = state.beginSignInShutdown()
        var shutdownFinished = false
        let shutdown = Task {
            for task in pending { await task.value }
            shutdownFinished = true
        }

        XCTAssertEqual(pending.count, 2)
        XCTAssertEqual(repeated.count, 2)
        XCTAssertTrue(addition.isCancelled)
        XCTAssertTrue(reSignIn.isCancelled)
        XCTAssertEqual(state.signingInAgainAccountID, "saved")
        addGate.open()
        await fulfillment(of: [addCleaned], timeout: 2)
        XCTAssertFalse(shutdownFinished)
        XCTAssertFalse(reSignInCleaned)
        XCTAssertTrue(state.hasRunningAccountSignIn)
        reSignInGate.open()
        await shutdown.value
        XCTAssertTrue(reSignInCleaned)
        XCTAssertFalse(state.isSigningInForNewAccount)
        XCTAssertNil(state.signingInAgainAccountID)
        XCTAssertFalse(state.hasRunningAccountSignIn)
        for task in repeated { await task.value }
    }

    func testShutdownTerminatesTheAddLoginBeforeDiscardingItsWorkspace() async throws {
        try await checkLoginShutdown(ignoresTermination: false)
    }

    func testShutdownKillsAnUnresponsiveAddLoginBeforeDiscardingItsWorkspace() async throws {
        try await checkLoginShutdown(ignoresTermination: true)
    }

    func testShutdownAfterLauncherExitStillWaitsForTheWholeOperationCleanup() async throws {
        try await checkLoginShutdown(ignoresTermination: false, pauseAfterLauncher: true)
    }

    private func checkLoginShutdown(ignoresTermination: Bool, pauseAfterLauncher: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "AccountAddSignInShutdownTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let state = PopoverState(defaults: defaults)
        state.show()
        let store = AccountProfilesStore(defaults: defaults)
        _ = try store.add(family: "codex", label: "Existing", identityKey: "existing", id: "saved")
        let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("accounts"))
        let savedDirectory = try workspace.prepare(family: "codex", profileID: "saved")
        let importer = AccountCredentialImporter(
            keychain: FakeKeychain(), environment: FakeEnvironment(), homeDirectory: root, workspace: workspace,
            httpClient: RoutingHTTPClient { _ in
                XCTFail("Account-add cancellation must not make an API request")
                return HTTPResponse(statusCode: 500, headers: [:], body: Data())
            })
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let child = root.appendingPathComponent("codex")
        let ready = root.appendingPathComponent("ready")
        let pidFile = root.appendingPathComponent("pid")
        let script = """
            #!/bin/sh
            \(ignoresTermination ? "trap '' TERM" : "")
            echo $$ > "$PID_FILE"
            echo ready > "$READY"
            \(pauseAfterLauncher ? "exit 0" : "exec /bin/sleep 8")
            """
        try Data(script.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        let profileID = "unregistered"
        let directory = try workspace.directory(family: "codex", profileID: profileID)
        let gate = Gate()
        let launcherFinished = pauseAfterLauncher ? expectation(description: "launcher returned before cleanup") : nil
        var exitCode: Int32?
        var reachedRegistration = false
        var cleanupFinished = false
        let login = try XCTUnwrap(
            state.startAddingAccount {
                var pendingWorkspace: String?
                defer {
                    if let pendingWorkspace {
                        do {
                            try importer.discardUnregisteredSignInWorkspace(
                                family: "codex", profileID: pendingWorkspace, in: store)
                            cleanupFinished = true
                        } catch {
                            XCTFail("Workspace cleanup failed: \(error)")
                        }
                    }
                }
                do {
                    pendingWorkspace = profileID
                    let home = try workspace.prepare(family: "codex", profileID: profileID)
                    exitCode = try await AccountSignInLauncher().runLogin(
                        family: "codex", home: home.path,
                        baseEnvironment: ["PATH": root.path, "READY": ready.path, "PID_FILE": pidFile.path],
                        usesLoginShellPATH: false)
                    if pauseAfterLauncher {
                        launcherFinished?.fulfill()
                        await gate.wait()
                    }
                    try Task.checkCancellation()
                    reachedRegistration = true
                } catch is CancellationError {
                } catch {
                    XCTFail("Login failed: \(error)")
                }
            })
        addTeardownBlock { @MainActor in
            login.cancel()
            gate.open()
            await login.value
        }
        if let launcherFinished {
            await fulfillment(of: [launcherFinished], timeout: 4)
        } else {
            let deadline = ContinuousClock.now + .seconds(4)
            while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try XCTUnwrap(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))

        let pending = state.beginSignInShutdown()
        let waiting = pauseAfterLauncher ? expectation(description: "shutdown is awaiting owned operations") : nil
        var shutdownFinished = false
        let shutdown = Task {
            waiting?.fulfill()
            for task in pending { await task.value }
            shutdownFinished = true
        }
        XCTAssertEqual(pending.count, 1)
        XCTAssertTrue(login.isCancelled)
        if let waiting {
            await fulfillment(of: [waiting], timeout: 2)
            XCTAssertFalse(shutdownFinished)
            XCTAssertFalse(cleanupFinished)
            XCTAssertTrue(state.isSigningInForNewAccount)
            XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))
            gate.open()
        }
        await shutdown.value

        XCTAssertEqual(exitCode, pauseAfterLauncher ? 0 : 128 + (ignoresTermination ? SIGKILL : SIGTERM))
        XCTAssertTrue(cleanupFinished)
        XCTAssertFalse(reachedRegistration)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: savedDirectory.path))
        XCTAssertEqual(store.profiles.map(\.id), ["saved"])
        XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
        XCTAssertFalse(state.isSigningInForNewAccount)
        XCTAssertFalse(state.hasRunningAccountSignIn)
        XCTAssertNil(state.startAddingAccount { XCTFail("Shutdown must reject another account") })
    }

    private func makeState() throws -> PopoverState {
        let suite = "AccountAddSignInShutdownTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = PopoverState(defaults: defaults)
        state.show()
        return state
    }

    @MainActor
    private final class Gate {
        private var opened = false
        private var continuation: CheckedContinuation<Void, Never>?

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }
}
