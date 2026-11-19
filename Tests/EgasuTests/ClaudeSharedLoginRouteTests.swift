import Foundation
import XCTest
@testable import Egasu

func legacyClaudeZshBlock(home: URL) -> String {
    let config = home.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(".claude").path
        .replacingOccurrences(of: "'", with: "'\\''")
    return """
        # >>> OpenUsage claude account switching >>>
        unalias claude 2>/dev/null
        function claude {
          env -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN -u CLAUDE_CODE_OAUTH_TOKEN -u CLAUDE_CODE_OAUTH_REFRESH_TOKEN -u CLAUDE_CODE_OAUTH_SCOPES CLAUDE_CONFIG_DIR='\(config)' command claude "$@"
        }
        # <<< OpenUsage claude account switching <<<
        """
}

final class ClaudeSharedLoginRouteTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/fixture")
    private let config = "/Users/fixture/.claude"
    private var zsh: String { legacyClaudeZshBlock(home: home) }

    func testExactInstallerBlockUsesItsLiteralServiceAndStateInTheConfiguredShell() throws {
        let fish = zsh.replacingOccurrences(of: "unalias", with: "functions -e")
            .replacingOccurrences(of: "claude {", with: "claude")
            .replacingOccurrences(of: "\"$@\"", with: "$argv")
            .replacingOccurrences(of: "\n}", with: "\nend")
            .replacingOccurrences(of: "\n", with: "\r\n")
        for (shell, path, block) in [
            ("/bin/zsh", ".zshrc", zsh), ("/opt/homebrew/bin/fish", ".config/fish/config.fish", fish)
        ] {
            let files = FakeFiles([home.appendingPathComponent(path).path: "before\n" + block + "\nafter\n"])
            let environment = FakeEnvironment(["SHELL": shell])
            let route = try ClaudeSharedLoginRoute.resolve(homeDirectory: home, files: files, environment: environment)
            XCTAssertEqual(route, .legacy(configDir: config))
            XCTAssertEqual(route.stateURL(homeDirectory: home).path, config + "/.claude.json")
            XCTAssertNotEqual(
                route.service(environment: environment),
                ClaudeAuthStore.baseKeychainServiceName(environment: environment))
            XCTAssertEqual(
                route.service(environment: environment),
                ClaudeAuthStore.scopedKeychainServiceName(forConfigDirLiteral: config, environment: environment))
        }
    }

    func testPlainLoginIgnoresOtherShellsWrapperAndAmbientDirectory() throws {
        let files = FakeFiles([home.appendingPathComponent(".zshrc").path: zsh])
        let environment = FakeEnvironment(["SHELL": "/opt/homebrew/bin/fish", "CLAUDE_CONFIG_DIR": "/other"])
        let route = try ClaudeSharedLoginRoute.resolve(homeDirectory: home, files: files, environment: environment)
        XCTAssertEqual(route, .plain)
        XCTAssertEqual(route.stateURL(homeDirectory: home).path, "/Users/fixture/.claude.json")
        XCTAssertEqual(
            route.service(environment: environment), ClaudeAuthStore.baseKeychainServiceName(environment: environment))
    }

    func testMissingShellVariableUsesTheSystemLoginShell() throws {
        let files = FakeFiles([home.appendingPathComponent(".zshrc").path: zsh])
        let route = try ClaudeSharedLoginRoute.resolve(
            homeDirectory: home, files: files, environment: FakeEnvironment(), loginShell: { "/opt/homebrew/bin/fish" })
        XCTAssertEqual(route, .plain)
    }

    func testModifiedIncompleteAndDuplicateBlocksStopBeforeChoosingACredential() {
        for block in [
            zsh.replacingOccurrences(of: config, with: "/other"),
            zsh.replacingOccurrences(of: "# ", with: "  # "),
            String(zsh.split(separator: "\n").dropLast().joined(separator: "\n")),
            zsh + "\n" + zsh, ClaudeLegacyShellProfile.endMarker
        ] {
            let files = FakeFiles([home.appendingPathComponent(".zshrc").path: block])
            XCTAssertThrowsError(
                try ClaudeSharedLoginRoute.resolve(
                    homeDirectory: home, files: files, environment: FakeEnvironment(["SHELL": "/bin/zsh"])
                )
            ) { XCTAssertTrue($0 is ClaudeSharedLoginRoute.UnrecognizedSetup) }
        }
    }
}
