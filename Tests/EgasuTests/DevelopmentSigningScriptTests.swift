import Foundation
import XCTest

final class DevelopmentSigningScriptTests: XCTestCase {
    func testPinnedIdentityAcceptsAnExactNameOrFingerprint() throws {
        for identity in [Self.identityName, Self.identityFingerprint] {
            let result = try preflight(pin: identity + "\n")

            XCTAssertEqual(result.status, 0, result.output)
            XCTAssertTrue(result.output.contains("PREFLIGHT_OK:" + identity), result.output)
            XCTAssertTrue(result.queriedIdentities)
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
        XCTAssertFalse(result.queriedIdentities)
    }

    func testUnavailableOrPartialIdentityStopsBeforeTheBuild() throws {
        for identity in ["Unavailable Identity", "Fixture"] {
            let result = try preflight(pin: identity)

            XCTAssertNotEqual(result.status, 0)
            XCTAssertTrue(result.output.contains("Configured signing identity is unavailable"), result.output)
            XCTAssertFalse(result.output.contains("PREFLIGHT_OK:"))
            XCTAssertTrue(result.queriedIdentities)
        }
    }

    func testExplicitAdHocSigningDoesNotQueryIdentities() throws {
        let result = try preflight(pin: "Unavailable Identity", requested: "-")

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PREFLIGHT_OK:-"), result.output)
        XCTAssertFalse(result.queriedIdentities)
    }

    func testNoConfiguredIdentityLeavesAutomaticSelectionAvailable() throws {
        let result = try preflight(pin: nil)

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("PREFLIGHT_OK:\n"), result.output)
        XCTAssertFalse(result.queriedIdentities)
    }

    private func preflight(pin: String?, requested: String? = nil) throws -> (
        status: Int32, output: String, queriedIdentities: Bool
    ) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("egasu-signing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scripts = root.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scripts, withIntermediateDirectories: true)
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
        let script = scripts.appendingPathComponent("build_and_run.sh")
        try (preflight + "\nprintf 'PREFLIGHT_OK:%s\\n' \"$CODESIGN_IDENTITY\"\n")
            .write(to: script, atomically: true, encoding: .utf8)
        let security = root.appendingPathComponent("security-fixture")
        try """
        #!/bin/bash
        touch "$(dirname "$0")/security-called"
        printf '%s\\n' '  1) \(Self.identityFingerprint) "\(Self.identityName)"'

        """.write(to: security, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: security.path)
        var environment = [
            "PATH": "/usr/bin:/bin", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"
        ]
        environment["CODESIGN_IDENTITY"] = requested
        let initialized = try run("/usr/bin/git", arguments: ["init", "--quiet", root.path], environment: environment)
        XCTAssertEqual(initialized.status, 0, initialized.output)
        let result = try run("/bin/bash", arguments: [script.path], environment: environment)
        return (
            result.status, result.output,
            FileManager.default.fileExists(atPath: root.appendingPathComponent("security-called").path)
        )
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
