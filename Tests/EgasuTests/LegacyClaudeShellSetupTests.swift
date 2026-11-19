import Darwin
import Foundation
import XCTest
@testable import Egasu

final class LegacyClaudeShellSetupTests: XCTestCase {
    private func temporaryHome() throws -> URL {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: home) }
        return home
    }

    func testRemovesOnlyOriginalBlockPreservingSymlinkModeAndSurroundingBytes() throws {
        let home = try temporaryHome()
        let rc = home.appendingPathComponent(".zshrc")
        let target = home.appendingPathComponent("dotfile")
        try FileManager.default.createSymbolicLink(at: rc, withDestinationURL: target)
        let prefix = Data([0x23, 0xff, 0x0d, 0x0a])
        let suffix = Data("# custom setting without trailing newline".utf8)
        let block = (legacyClaudeZshBlock(home: home) + "\n").replacingOccurrences(of: "\n", with: "\r\n")
        try (prefix + Data(block.utf8) + suffix).write(to: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: target.path)

        func route() throws -> ClaudeSharedLoginRoute {
            try ClaudeSharedLoginRoute.resolve(
                homeDirectory: home, files: LocalTextFileAccessor(), environment: FakeEnvironment(["SHELL": "/bin/zsh"])
            )
        }
        XCTAssertEqual(try route(), .legacy(configDir: home.appendingPathComponent(".claude").path))
        try XCTUnwrap(ClaudeLegacyShellProfile.find(in: home).first).remove()
        XCTAssertEqual(try route(), .plain)

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rc.path), target.path)
        XCTAssertEqual(try Data(contentsOf: rc), prefix + suffix)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
    }

    func testQuotedWrapperIsNotAnInstalledFunction() throws {
        let home = try temporaryHome()
        let rc = home.appendingPathComponent(".zshrc")
        for (prefix, suffix) in [("cat <<'EXAMPLE'", "EXAMPLE"), ("example='", "'")] {
            let contents = Data((prefix + "\n" + legacyClaudeZshBlock(home: home) + "\n" + suffix).utf8)
            try contents.write(to: rc)
            XCTAssertThrowsError(try ClaudeLegacyShellProfile.find(in: home))
            XCTAssertThrowsError(
                try ClaudeSharedLoginRoute.resolve(
                    homeDirectory: home, files: LocalTextFileAccessor(),
                    environment: FakeEnvironment(["SHELL": "/bin/zsh"])))
            XCTAssertEqual(try Data(contentsOf: rc), contents)
        }
    }

    func testRouteRejectsNamedPipeWithoutReadingIt() throws {
        let home = try temporaryHome()
        let rc = home.appendingPathComponent(".zshrc")
        XCTAssertEqual(mkfifo(rc.path, 0o600), 0)
        // 회귀 시에도 읽기 스레드가 writer를 기다리며 멈추지 않도록 지연된 EOF 전달.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            let fd = Darwin.open(rc.path, O_WRONLY | O_NONBLOCK)
            if fd >= 0 { Darwin.close(fd) }
        }
        XCTAssertThrowsError(
            try ClaudeSharedLoginRoute.resolve(
                homeDirectory: home, files: LocalTextFileAccessor(), environment: FakeEnvironment(["SHELL": "/bin/zsh"])
            )
        ) {
            XCTAssertTrue($0 is ClaudeSharedLoginRoute.UnrecognizedSetup)
        }
    }

    func testReplacementRestoresTheActualDisplacedEditAndKeepsAnyLaterSave() throws {
        let home = try temporaryHome()
        let target = home.appendingPathComponent("profile")
        let displaced = home.appendingPathComponent("profile.egasu-recovery")
        let original = Data("initial".utf8)
        let updated = Data("migration".utf8)
        let edited = Data("external save".utf8)
        for later in [updated, Data("second external save".utf8)] {
            try edited.write(to: displaced)
            try later.write(to: target)
            XCTAssertThrowsError(
                try ClaudeLegacyShellProfile.verifyDisplacedProfile(
                    at: displaced, target: target, original: original, updated: updated)
            ) {
                XCTAssertEqual($0 as? ClaudeShellLoginMigrationError, .concurrentProfileEdit)
            }
            if later == updated {
                XCTAssertEqual(try Data(contentsOf: target), edited)
                XCTAssertFalse(FileManager.default.fileExists(atPath: displaced.path))
            } else {
                XCTAssertEqual(try Data(contentsOf: target), later)
                XCTAssertEqual(try Data(contentsOf: displaced), edited)
            }
        }
    }

    func testConcurrentShellEditsAndMalformedInstallerBlocksArePreserved() throws {
        let home = try temporaryHome()
        let rc = home.appendingPathComponent(".zshrc")
        let block = legacyClaudeZshBlock(home: home)
        try Data(block.utf8).write(to: rc)
        let plan = try XCTUnwrap(ClaudeLegacyShellProfile.find(in: home).first)
        let changed = Data((block + "\n# edited").utf8)
        try changed.write(to: rc)
        XCTAssertThrowsError(try plan.remove())
        XCTAssertEqual(try Data(contentsOf: rc), changed)

        let modifiedFunction = Data(block.replacingOccurrences(of: "command claude", with: "my-claude").utf8)
        try modifiedFunction.write(to: rc)
        XCTAssertThrowsError(try ClaudeLegacyShellProfile.find(in: home))
        XCTAssertEqual(try Data(contentsOf: rc), modifiedFunction)
    }
}
