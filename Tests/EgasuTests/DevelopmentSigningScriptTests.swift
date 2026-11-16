import Foundation
import XCTest

final class DevelopmentSigningScriptTests: XCTestCase {
    func testPinnedIdentityUsesNativeNameHashPartialNameAndPreferenceResolution() throws {
        for identity in [
            Self.identityName, Self.identityFingerprint, "Fixture Developer", "fixture-signing-preference",
            "Native-only identity"
        ] {
            let result = try preflight(pin: identity + "\n")

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("PREFLIGHT_OK:" + identity), result.output)
            XCTAssertEqual(Array(result.probeArguments.prefix(5)), [
                "--dryrun", "--force", "--sign", identity, "--timestamp=none"
            ])
            XCTAssertEqual(result.probeArguments.count, 6)
            XCTAssertEqual(result.remainingProbeCount, 0)
        }
    }

    func testExplicitIdentityOverridesTheLocalPin() throws {
        let result = try preflight(pin: "Unavailable Identity", requested: Self.identityName)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PREFLIGHT_OK:" + Self.identityName), result.output)
    }

    func testEmptyPinStopsBeforeTheBuild() throws {
        let result = try preflight(pin: "\n")

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.output.contains(".env.local.codesign-identity is empty"), result.output)
        XCTAssertFalse(result.output.contains("PREFLIGHT_OK:"))
        XCTAssertTrue(result.probeArguments.isEmpty)
        XCTAssertEqual(result.remainingProbeCount, 0)
    }

    func testUnavailableOrAmbiguousIdentityStopsBeforeTheBuildAndRemovesTheProbe() throws {
        for identity in ["Unavailable Identity", "Ambiguous Identity"] {
            let result = try preflight(pin: identity)

            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("Configured signing identity is unavailable"), result.output)
            XCTAssertFalse(result.output.contains("PREFLIGHT_OK:"))
            XCTAssertEqual(result.probeArguments.count, 6)
            XCTAssertEqual(result.remainingProbeCount, 0)
        }
    }

    func testExplicitAdHocSigningDoesNotProbeAnIdentity() throws {
        let result = try preflight(pin: "Unavailable Identity", requested: "-")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PREFLIGHT_OK:-"), result.output)
        XCTAssertTrue(result.probeArguments.isEmpty)
        XCTAssertEqual(result.remainingProbeCount, 0)
    }

    func testNoConfiguredIdentityLeavesAutomaticSelectionAvailable() throws {
        let result = try preflight(pin: nil)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PREFLIGHT_OK:\n"), result.output)
        XCTAssertTrue(result.probeArguments.isEmpty)
        XCTAssertEqual(result.remainingProbeCount, 0)
    }

    func testInvalidModeStopsBeforeSourcingTheVersionScript() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("egasu-mode-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let script = scripts.appendingPathComponent("build_and_run.sh")
        try FileManager.default.copyItem(at: Self.repositoryRoot.appendingPathComponent("script/build_and_run.sh"), to: script)
        try "touch \"$ROOT_DIR/version-sourced\"\nexit 91\n".write(
            to: scripts.appendingPathComponent("version.sh"), atomically: true, encoding: .utf8
        )

        let result = try run("/bin/bash", arguments: [script.path, "invalid-mode"], environment: ["PATH": "/usr/bin:/bin"])

        XCTAssertEqual(result.status, 2, result.output)
        XCTAssertTrue(result.output.contains("[run|build|logs|verify]"), result.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("version-sourced").path))
    }

    func testVerifyRejectsTheProductionAppAndOtherCheckouts() throws {
        for processes in [
            "123 /Applications/egasu.app/Contents/MacOS/egasu\n",
            "456 /tmp/other-checkout/dist/egasu.app/Contents/MacOS/egasu\n",
            ""
        ] {
            let result = try verify(processes: processes)

            XCTAssertNotEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("Expected development app is not running:"), result.output)
            XCTAssertFalse(result.output.contains("==> running"), result.output)
        }
    }

    func testVerifyAcceptsOnlyThisCheckoutsExecutablePath() throws {
        let result = try verify(processes: "123 /Applications/egasu.app/Contents/MacOS/egasu\n", includeCheckout: true)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("==> running"), result.output)
    }

    private func preflight(pin: String?, requested: String? = nil) throws -> (
        status: Int32, output: String, probeArguments: [String], remainingProbeCount: Int
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("egasu-signing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
        let temporary = root.appendingPathComponent("probe-directory")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: Self.repositoryRoot.appendingPathComponent("script/version.sh"),
            to: scripts.appendingPathComponent("version.sh")
        )
        if let pin {
            try pin.write(
                to: root.appendingPathComponent(".env.local.codesign-identity"), atomically: true, encoding: .utf8)
        }
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8)
        let boundary = try XCTUnwrap(source.range(of: "\nTARGET_NAME="))
        let preflight = String(source[..<boundary.lowerBound])
            .replacingOccurrences(of: "/usr/bin/security", with: "\"$ROOT_DIR/security-fixture\"")
            .replacingOccurrences(of: "/usr/bin/codesign", with: "\"$ROOT_DIR/codesign-fixture\"")
        let script = scripts.appendingPathComponent("build_and_run.sh")
        try (preflight + "\nprintf 'PREFLIGHT_OK:%s\\n' \"$CODESIGN_IDENTITY\"\n")
            .write(to: script, atomically: true, encoding: .utf8)
        let security = root.appendingPathComponent("security-fixture")
        try """
        #!/bin/bash
        touch "$(dirname "$0")/security-called"
        exit 97

        """.write(to: security, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)
        let codesign = root.appendingPathComponent("codesign-fixture")
        try """
        #!/bin/bash
        printf '%s\\n' "$@" > "$(dirname "$0")/codesign-arguments"
        [ "$#" -eq 6 ] && [ "$1" = --dryrun ] && [ "$2" = --force ] && [ "$3" = --sign ] \\
          && [ "$5" = --timestamp=none ] && [ "$6" != /usr/bin/true ] \\
          && /usr/bin/cmp -s /usr/bin/true "$6" || exit 98
        case "$4" in
          '\(Self.identityName)'|'\(Self.identityFingerprint)'|'Fixture Developer'|'fixture-signing-preference'|'Native-only identity')
            exit 0 ;;
          'Ambiguous Identity') echo 'ambiguous identity' >&2; exit 1 ;;
          *) echo 'identity not found' >&2; exit 1 ;;
        esac

        """.write(to: codesign, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codesign.path)
        var environment = [
            "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "TMPDIR": temporary.path
        ]
        environment["CODESIGN_IDENTITY"] = requested
        let initialized = try run("/usr/bin/git", arguments: ["init", "--quiet", root.path], environment: environment)
        XCTAssertEqual(initialized.status, 0, initialized.output)
        let result = try run("/bin/bash", arguments: [script.path], environment: environment)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("security-called").path))
        let argumentsFile = root.appendingPathComponent("codesign-arguments")
        let arguments = FileManager.default.fileExists(atPath: argumentsFile.path)
            ? try String(contentsOf: argumentsFile, encoding: .utf8).split(separator: "\n").map(String.init) : []
        return (
            result.status, result.output, arguments,
            try FileManager.default.contentsOfDirectory(atPath: temporary.path).count
        )
    }

    private func verify(processes: String, includeCheckout: Bool = false) throws -> (status: Int32, output: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("egasu verify \(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let binary = root.appendingPathComponent("dist/egasu.app/Contents/MacOS/egasu")
        let listing = processes + (includeCheckout ? "789 \(binary.path)\n" : "")
        try listing.write(to: root.appendingPathComponent("ps-output"), atomically: true, encoding: .utf8)
        let ps = root.appendingPathComponent("ps-fixture")
        try "#!/bin/sh\ncat \"$ROOT_DIR/ps-output\"\n".write(to: ps, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ps.path)
        let source = try String(
            contentsOf: Self.repositoryRoot.appendingPathComponent("script/build_and_run.sh"), encoding: .utf8
        )
        let boundary = try XCTUnwrap(source.range(of: "\ncase \"$MODE\" in", options: .backwards))
        let dispatch = String(source[boundary.lowerBound...])
            .replacingOccurrences(of: "\"/bin/ps\"", with: "\"\(ps.path)\"")
        let script = root.appendingPathComponent("verify.sh")
        try """
        #!/bin/bash
        set -euo pipefail
        MODE=verify
        APP_BINARY="$ROOT_DIR/dist/egasu.app/Contents/MacOS/egasu"
        launch_app() { :; }
        sleep() { :; }
        pgrep() { return 0; }
        \(dispatch)
        """.write(to: script, atomically: true, encoding: .utf8)
        return try run("/bin/bash", arguments: [script.path], environment: [
            "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "ROOT_DIR": root.path
        ])
    }

    private func run(_ executable: String, arguments: [String], environment: [String: String]) throws -> (
        status: Int32, output: String
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    private static let identityName = "Apple Development: Fixture Developer (FIXTURE123)"
    private static let identityFingerprint = "0123456789ABCDEF0123456789ABCDEF01234567"
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
