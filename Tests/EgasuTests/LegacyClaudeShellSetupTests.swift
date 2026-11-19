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

        try XCTUnwrap(ClaudeLegacyShellProfile.find(in: home).first).remove()

        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: rc.path), target.path)
        XCTAssertEqual(try Data(contentsOf: rc), prefix + suffix)
        let attributes = try FileManager.default.attributesOfItem(atPath: target.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
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
