import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class CommandLineToolInstallerTests: XCTestCase {
    private func fixture() throws -> (root: URL, source: String, destination: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let source = root.appendingPathComponent("egasu.app/Contents/Helpers/egasu")
        let destination = root.appendingPathComponent("bin/egasu")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path)
        return (root, source.path, destination.path)
    }

    func testInstallAndUninstallOwnSymlink() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var sawVerification = false
        var checkVerifying: (() -> Void)?
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            waitForVerification: { checkVerifying?() },
            performPrivileged: { operation, source, destination in
                do {
                    switch operation {
                    case .install:
                        try FileManager.default.createDirectory(
                            atPath: (destination as NSString).deletingLastPathComponent,
                            withIntermediateDirectories: true
                        )
                        try FileManager.default.createSymbolicLink(atPath: destination, withDestinationPath: source)
                    case .uninstall:
                        try FileManager.default.removeItem(atPath: destination)
                    }
                    return .success
                } catch {
                    return .failure(error.localizedDescription)
                }
            }
        )

        checkVerifying = {
            sawVerification = true
            XCTAssertTrue(installer.isVerifying)
            installer.refreshStatus()
            XCTAssertTrue(installer.isVerifying)
        }
        XCTAssertEqual(installer.status, .notInstalled)
        await installer.install()
        checkVerifying = nil
        XCTAssertTrue(sawVerification)
        XCTAssertFalse(installer.isVerifying)
        XCTAssertEqual(installer.status, .installed)
        installer.uninstall()
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testPrivilegedCommandStatusesAreNotAuthorizationFailures() async throws {
        let cases: [(Int?, CommandLineToolInstaller.Operation, ErrorCategory)] = [
            (1, .install, .subprocess),
            (1, .uninstall, .subprocess),
            (255, .install, .subprocess),
            (73, .install, .subprocess),
            (74, .uninstall, .subprocess),
            (75, .uninstall, .subprocess),
            (-60005, .install, .permission),
            (nil, .install, .other),
            (-999, .uninstall, .other),
            (0, .install, .other),
            (256, .install, .other)
        ]
        for (code, operation, category) in cases {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let previousSink = AppLog.sink
            AppLog.sink = LogFile(directory: fixture.root, fileName: "diagnostics.log")
            AppLog.sink.open()
            AppLog.reloadLevel(.info)
            defer {
                AppLog.sink = previousSink
                AppLog.reloadLevel()
            }
            let diagnostics = DiagnosticEventRecorder()
            if case .uninstall = operation {
                try FileManager.default.createDirectory(
                    atPath: (fixture.destination as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true
                )
                try FileManager.default.createSymbolicLink(atPath: fixture.destination, withDestinationPath: fixture.source)
            }
            let installer = CommandLineToolInstaller(
                sourcePath: fixture.source,
                destinationPath: fixture.destination,
                performPrivileged: { _, _, _ in .failure("PRIVATE_COMMAND_FAILURE", code: code) }
            )
            let expectedOperation: DiagnosticOperation
            switch operation {
            case .install:
                await installer.install()
                expectedOperation = .cliInstall
                XCTAssertEqual(installer.status, .notInstalled)
            case .uninstall:
                installer.uninstall()
                expectedOperation = .cliRemove
                XCTAssertEqual(installer.status, .installed)
            }

            let lines = try String(contentsOf: fixture.root.appendingPathComponent("diagnostics.log"), encoding: .utf8)
                .split(separator: "\n").map(String.init)
            XCTAssertEqual(lines.count, 1, "status=\(String(describing: code))")
            let line = try XCTUnwrap(lines.first)
            XCTAssertTrue(line.contains("[ERROR]"), line)
            if let code {
                XCTAssertTrue(line.contains("; error_code=\(code)"), line)
            } else {
                XCTAssertFalse(line.contains("error_code="), line)
            }
            XCTAssertFalse(line.contains("authorization_error_code"), line)
            XCTAssertFalse(line.contains("PRIVATE_COMMAND_FAILURE"), line)
            XCTAssertEqual(diagnostics.events, [DiagnosticEvent(expectedOperation, result: .failure, category: category)])
            XCTAssertTrue(installer.errorMessage?.contains("PRIVATE_COMMAND_FAILURE") == true)
        }
    }

    func testCancelledAuthorizationDoesNotBecomeFailure() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let diagnostics = DiagnosticEventRecorder()
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in .cancelled }
        )

        await installer.install()

        XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.cliInstall, result: .cancelled)])
        XCTAssertNil(installer.errorMessage)
        XCTAssertEqual(installer.status, .notInstalled)
    }

    func testVerificationRequiresTheExpectedLinkAndAnExecutable() async throws {
        for expectedStatus in [
            CommandLineToolInstaller.Status.notInstalled, .conflict, .installed
        ] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.root) }
            let destination = URL(fileURLWithPath: fixture.destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            let diagnostics = DiagnosticEventRecorder()
            let installer = CommandLineToolInstaller(
                sourcePath: fixture.source, destinationPath: fixture.destination,
                waitForVerification: {
                    do {
                        switch expectedStatus {
                        case .notInstalled: break
                        case .conflict:
                            try Data().write(to: destination)
                        case .installed:
                            try FileManager.default.createSymbolicLink(
                                atPath: destination.path, withDestinationPath: fixture.source)
                            try FileManager.default.setAttributes(
                                [.posixPermissions: 0o644],
                                ofItemAtPath: fixture.source)
                        }
                    } catch { XCTFail(error.localizedDescription) }
                },
                performPrivileged: { _, _, _ in .success })

            await installer.install()
            XCTAssertEqual(installer.status, expectedStatus)
            XCTAssertNotNil(installer.errorMessage)
            XCTAssertFalse(installer.isVerifying)
            XCTAssertEqual(diagnostics.events, [DiagnosticEvent(.cliInstall, result: .failure, category: .storage)])
        }
    }

    func testSearchableDirectoryAtHelperPathDoesNotRequestInstallation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.removeItem(atPath: fixture.source)
        try FileManager.default.createDirectory(atPath: fixture.source, withIntermediateDirectories: false)
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source, destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                XCTFail("A directory cannot provide the terminal command")
                return .success
            })

        await installer.install()

        XCTAssertEqual(installer.status, .notInstalled)
        XCTAssertNotNil(installer.errorMessage)
    }

    func testRemovalSheetRequiresConfirmationAndPreservesLinkOnAuthorizationCancellation() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let destination = URL(fileURLWithPath: fixture.destination)
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: destination.path, withDestinationPath: fixture.source)
        var authorizationRequests = 0
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source, destinationPath: destination.path,
            performPrivileged: { operation, _, _ in
                XCTAssertEqual(operation, .uninstall)
                authorizationRequests += 1
                return .cancelled
            })
        let host = NSHostingView(rootView: Form { TerminalHelperSettingsSection(commandLineTool: installer) })
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 360, height: 180),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(.init(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1000, y: 0))
        window.orderFrontRegardless()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }
        func buttons(in view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        for action in ["Cancel", "Remove"] {
            installer.isConfirmingRemoval = true
            for _ in 0..<100 where window.attachedSheet == nil { try await Task.sleep(for: .milliseconds(20)) }
            let sheet = try XCTUnwrap(
                window.attachedSheet?.contentView,
                "action=\(action) confirming=\(installer.isConfirmingRemoval) sheets=\(window.sheets.count) visible=\(window.isVisible)"
            )
            let button = try XCTUnwrap(buttons(in: sheet).first { $0.title == L10n.settings(action) })
            XCTAssertEqual(authorizationRequests, 0)
            XCTAssertTrue(button.sendAction(try XCTUnwrap(button.action), to: button.target))
            for _ in 0..<100 where window.attachedSheet != nil { try await Task.sleep(for: .milliseconds(20)) }
            XCTAssertNil(window.attachedSheet)
            XCTAssertFalse(installer.isConfirmingRemoval)
            // 취소 상태를 SwiftUI에 반영한 뒤 같은 창에서 다음 확인 요청.
            host.layoutSubtreeIfNeeded()
            XCTAssertEqual(authorizationRequests, action == "Cancel" ? 0 : 1)
            XCTAssertEqual(installer.status, .installed)
            XCTAssertNil(installer.errorMessage)
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.path), fixture.source)
        }
    }

    func testForeignPathIsNeverOverwritten() async throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try Data("foreign".utf8).write(to: URL(fileURLWithPath: fixture.destination))
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        await installer.install()
        XCTAssertFalse(operationRan)
        XCTAssertNotNil(installer.errorMessage)
        XCTAssertEqual(try String(contentsOfFile: fixture.destination, encoding: .utf8), "foreign")
    }

    func testForeignSymlinkIsNeverClaimedOrRemoved() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try FileManager.default.createDirectory(
            atPath: (fixture.destination as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: fixture.destination,
            withDestinationPath: "/tmp/another-egasu"
        )
        var operationRan = false
        let installer = CommandLineToolInstaller(
            sourcePath: fixture.source,
            destinationPath: fixture.destination,
            performPrivileged: { _, _, _ in
                operationRan = true
                return .success
            }
        )

        XCTAssertEqual(installer.status, .conflict)
        installer.uninstall()
        XCTAssertFalse(operationRan)
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: fixture.destination),
            "/tmp/another-egasu"
        )
    }

    func testReplacementCommandPreservesQuotedPathsAndCleansTemporaryDirectory() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let directory = fixture.root.appendingPathComponent("bin ' $(touch injected-directory) `touch injected-backtick`")
        let command = directory.appendingPathComponent("egasu ' $(touch injected-command)")
        let expected = fixture.root.appendingPathComponent("OpenUsage ' $(touch injected-source).app/Contents/Helpers/openusage").path
        let target = fixture.root.appendingPathComponent("egasu ' $(touch injected-target).app/Contents/Helpers/egasu").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: command.path, withDestinationPath: expected)

        let result = try runReplacementCommand(at: command, expected: expected, target: target, in: fixture.root)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), target)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [command.lastPathComponent])
        for name in ["injected-directory", "injected-backtick", "injected-command", "injected-source", "injected-target"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent(name).path), name)
        }
    }

    func testReplacementCommandPreservesChangedLink() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let command = URL(fileURLWithPath: fixture.destination)
        let directory = command.deletingLastPathComponent()
        let foreignTarget = fixture.root.appendingPathComponent("other helper").path
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: command.path, withDestinationPath: foreignTarget)

        let result = try runReplacementCommand(at: command, expected: fixture.source, target: "/new/helper", in: fixture.root)

        XCTAssertEqual(result.status, 75, result.output)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), foreignTarget)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [command.lastPathComponent])
    }

    func testReplacementCommandPreservesRegularFile() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let command = URL(fileURLWithPath: fixture.destination)
        let directory = command.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("user command".utf8).write(to: command)

        let result = try runReplacementCommand(at: command, expected: fixture.source, target: "/new/helper", in: fixture.root)

        XCTAssertEqual(result.status, 74, result.output)
        XCTAssertEqual(try Data(contentsOf: command), Data("user command".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [command.lastPathComponent])
    }

    func testReplacementCommandDoesNotFollowSymlinkToDirectory() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let command = URL(fileURLWithPath: fixture.destination)
        let directory = command.deletingLastPathComponent()
        let previousTarget = fixture.root.appendingPathComponent("previous target")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: previousTarget, withIntermediateDirectories: true)
        let marker = previousTarget.appendingPathComponent("keep")
        try Data("preserved".utf8).write(to: marker)
        try FileManager.default.createSymbolicLink(atPath: command.path, withDestinationPath: previousTarget.path)

        let result = try runReplacementCommand(at: command, expected: previousTarget.path, target: fixture.source, in: fixture.root)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: command.path), fixture.source)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: previousTarget.path), ["keep"])
        XCTAssertEqual(try Data(contentsOf: marker), Data("preserved".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [command.lastPathComponent])
    }

    private func runReplacementCommand(
        at url: URL, expected: String, target: String, in directory: URL
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", CommandLineToolInstaller.replacementCommand(at: url, expected: expected, target: target)]
        process.currentDirectoryURL = directory
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
