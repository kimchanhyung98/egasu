import Foundation
import XCTest
@testable import Egasu

@MainActor
final class LegacyClaudeShellSetupTests: XCTestCase {
    func testFindsPairedClaudeMarkersInBothInstallerLocationsWithoutChangingTheFiles() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let fish = home.appendingPathComponent(".config/fish/config.fish")
        try FileManager.default.createDirectory(at: fish.deletingLastPathComponent(), withIntermediateDirectories: true)
        let dotfile = home.appendingPathComponent("dotfile")
        try FileManager.default.createSymbolicLink(
            at: home.appendingPathComponent(".zshrc"), withDestinationURL: dotfile)
        let source = """
            # >>> OpenUsage claude account switching >>>
            function claude { command claude "$@" }
            # <<< OpenUsage claude account switching <<<
            """
        try Data(source.utf8).write(to: dotfile)
        let fishContents = Data(source.replacingOccurrences(of: "\n", with: "\r\n").utf8)
        try fishContents.write(to: fish)

        let check = await LegacyClaudeShellSetup.check(in: home)

        XCTAssertEqual(check.found, ["~/.zshrc", "~/.config/fish/config.fish"])
        XCTAssertTrue(check.unreadable.isEmpty)
        XCTAssertEqual(try Data(contentsOf: dotfile), Data(source.utf8))
        XCTAssertEqual(try Data(contentsOf: fish), fishContents)
    }

    func testIgnoresOtherProvidersReferencesAndIncompleteOrReversedMarkers() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let source = """
            # >>> OpenUsage codex account switching >>>
            # <<< OpenUsage codex account switching <<<
            echo '# >>> OpenUsage claude account switching >>>'
            # <<< OpenUsage claude account switching <<<
            # >>> OpenUsage claude account switching >>>
            """
        try Data(source.utf8).write(to: home.appendingPathComponent(".zshrc"))

        let check = await LegacyClaudeShellSetup.check(in: home)

        XCTAssertTrue(check.found.isEmpty)
        XCTAssertTrue(check.unreadable.isEmpty)
    }

    func testReportsAnUnreadableProfileAndStillChecksTheOtherProfile() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let zsh = home.appendingPathComponent(".zshrc")
        try FileManager.default.createDirectory(at: zsh, withIntermediateDirectories: true)
        let fish = home.appendingPathComponent(".config/fish/config.fish")
        try FileManager.default.createDirectory(at: fish.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("# >>> OpenUsage claude account switching >>>\n# <<< OpenUsage claude account switching <<<".utf8)
            .write(to: fish)

        let check = await LegacyClaudeShellSetup.check(in: home)

        XCTAssertEqual(check.unreadable, ["~/.zshrc"])
        XCTAssertEqual(check.found, ["~/.config/fish/config.fish"])
    }
}
