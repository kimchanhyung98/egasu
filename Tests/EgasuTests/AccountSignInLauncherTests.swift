import XCTest
@testable import Egasu

final class AccountSignInLauncherTests: XCTestCase {
    func testFirstClaudeLoginUsesTheSameDirectoryAsTheNextSharedRead() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let child = home.appendingPathComponent("claude")
        let script = """
            #!/bin/sh
            test "$1" = auth && test "$2" = login && test "${CLAUDE_CONFIG_DIR-}" = "$EXPECTED_CONFIG"
            """
        try Data(script.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)
        let launcher = AccountSignInLauncher(homeDirectory: home)
        for usesWrapper in [false, true] {
            if usesWrapper {
                try Data(legacyClaudeZshBlock(home: home).utf8).write(to: home.appendingPathComponent(".zshrc"))
            }
            let code = try await launcher.runLogin(
                family: "claude", home: nil,
                baseEnvironment: [
                    "PATH": home.path, "SHELL": "/bin/zsh", "CLAUDE_CONFIG_DIR": "/other",
                    "EXPECTED_CONFIG": usesWrapper ? home.appendingPathComponent(".claude").path : ""
                ],
                usesLoginShellPATH: false
            )
            XCTAssertEqual(code, 0)
        }
    }

    @MainActor
    func testShutdownWaitsForTheBrowserLoginChildAndAttemptCleanup() async throws {
        try await checkShutdownOfBrowserLogin(ignoresTermination: false)
    }

    @MainActor
    func testShutdownStopsAnUnresponsiveLoginBeforeCleaningItsAttempt() async throws {
        try await checkShutdownOfBrowserLogin(ignoresTermination: true)
    }

    @MainActor
    private func checkShutdownOfBrowserLogin(ignoresTermination: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = AccountSignInWorkspace(baseDirectory: root.appendingPathComponent("accounts"))
        let attempt = try workspace.prepareReauthentication(family: "codex", profileID: "saved")
        defer { try? FileManager.default.removeItem(at: root) }
        let attemptID = try XCTUnwrap(attempt.attemptID)
        let child = root.appendingPathComponent("codex")
        let descendantMarker = root.appendingPathComponent("descendant-finished")
        let setup =
            ignoresTermination
            ? """
            trap '' TERM
            (while test -d "$CODEX_HOME"; do /bin/sleep 0.05; done; echo done > "$MARKER") &
            echo $! > "$MARKER.pid"
            """ : ""
        let script = """
            #!/bin/sh
            \(setup)
            echo ready > "$CODEX_HOME/ready"
            exec /bin/sleep 8
            """
        try Data(script.utf8).write(to: child)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: child.path)

        let state = PopoverState()
        state.show()
        var exitCode: Int32?
        let login = try XCTUnwrap(
            state.startReSignIn(for: "saved") {
                do {
                    exitCode = try await AccountSignInLauncher().runLogin(
                        family: "codex", home: attempt.directory.path,
                        baseEnvironment: ["PATH": root.path, "MARKER": descendantMarker.path],
                        usesLoginShellPATH: false)
                    try workspace.remove(family: "codex", profileID: "saved", attemptID: attemptID)
                } catch {
                    XCTFail("Login or cleanup failed: \(error)")
                }
            })
        defer { login.cancel() }
        let ready = attempt.directory.appendingPathComponent("ready")
        let deadline = ContinuousClock.now + .seconds(4)
        while !FileManager.default.fileExists(atPath: ready.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path))

        let first = state.beginReSignInShutdown()
        let repeated = state.beginReSignInShutdown()
        await first?.value
        await repeated?.value

        XCTAssertEqual(exitCode, 128 + (ignoresTermination ? SIGKILL : SIGTERM))
        XCTAssertFalse(FileManager.default.fileExists(atPath: attempt.directory.path))
        if ignoresTermination {
            let pidText = try String(contentsOf: descendantMarker.appendingPathExtension("pid"), encoding: .utf8)
            let pid = try XCTUnwrap(pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
            let deadline = ContinuousClock.now + .seconds(3)
            while kill(pid, 0) == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(kill(pid, 0) == -1 && errno == ESRCH)
            XCTAssertTrue(FileManager.default.fileExists(atPath: descendantMarker.path))
        }
        XCTAssertNil(state.signingInAgainAccountID)
        XCTAssertNil(state.startReSignIn(for: "another") {})
        login.cancel()
        await login.value
    }

    func testCancellationBeforeLaunchTerminatesTheLoginChild() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cli = root.appendingPathComponent("codex")
        try Data("#!/bin/sh\nexec /bin/sleep 2\n".utf8).write(to: cli)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await AccountSignInLauncher().runLogin(
                family: "codex", home: root.path, baseEnvironment: ["PATH": root.path],
                usesLoginShellPATH: false
            )
        }

        let code = try await task.value

        XCTAssertEqual(code, 128 + SIGTERM)
    }

    func testLoginArgumentsMatchTheInstalledCLIs() {
        XCTAssertEqual(AccountSignInLauncher.loginArguments(family: "claude"), ["auth", "login"])
        XCTAssertEqual(
            AccountSignInLauncher.loginArguments(family: "codex"),
            ["-c", "cli_auth_credentials_store=\"file\"", "login"]
        )
        XCTAssertEqual(AccountSignInLauncher.loginArguments(family: "cursor"), [])
    }

    func testClaudeLoginEnvironmentRemovesAuthOverridesAndPinsTheHome() {
        var base = ["PATH": "/usr/bin", "EDITOR": "vim"]
        for variable in AccountSignInLauncher.claudeAuthEnvironmentRemovals {
            base[variable] = "leaked"
        }

        let environment = AccountSignInLauncher.loginEnvironment(
            family: "claude",
            home: "/tmp/workspace",
            base: base
        )

        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/workspace")
        for variable in AccountSignInLauncher.claudeAuthEnvironmentRemovals {
            XCTAssertNil(environment[variable], "\(variable) must be removed from the login child")
        }
        XCTAssertEqual(environment["PATH"], "/usr/bin")
        XCTAssertEqual(environment["EDITOR"], "vim")
    }

    func testCodexLoginEnvironmentRemovesAuthOverridesAndPinsTheHome() {
        var base = ["PATH": "/usr/bin"]
        for variable in AccountSignInLauncher.codexAuthEnvironmentRemovals {
            base[variable] = "leaked"
        }

        let environment = AccountSignInLauncher.loginEnvironment(
            family: "codex",
            home: "/tmp/workspace",
            base: base
        )

        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/workspace")
        for variable in AccountSignInLauncher.codexAuthEnvironmentRemovals {
            XCTAssertNil(environment[variable], "\(variable) must be removed from the login child")
        }
        XCTAssertEqual(environment["PATH"], "/usr/bin")
    }

    func testFirstLoginUsesDefaultAuthenticationWithoutChangingTheParentEnvironment() {
        for (family, homeKey, authKeys) in [
            ("claude", "CLAUDE_CONFIG_DIR", AccountSignInLauncher.claudeAuthEnvironmentRemovals),
            ("codex", "CODEX_HOME", AccountSignInLauncher.codexAuthEnvironmentRemovals)
        ] {
            var base = ["PATH": "/usr/bin", "HOME": "/tmp/test-home", homeKey: "/tmp/custom-home"]
            for key in authKeys { base[key] = "custom-auth" }

            let environment = AccountSignInLauncher.loginEnvironment(family: family, home: nil, base: base)

            XCTAssertNil(environment[homeKey])
            for key in authKeys {
                XCTAssertNil(environment[key])
                XCTAssertEqual(base[key], "custom-auth")
            }
            XCTAssertEqual(base[homeKey], "/tmp/custom-home")
            XCTAssertEqual(environment["PATH"], "/usr/bin")
            XCTAssertEqual(environment["HOME"], "/tmp/test-home")
        }
    }
}
