import XCTest
import Egasu
@testable import EgasuCLI

final class CLIArgumentsTests: XCTestCase {
    func testParsesProviderAndForce() throws {
        let parsed = try CLIArguments.parse(["Codex", "--force"])
        XCTAssertEqual(parsed.providerID, "codex")
        XCTAssertTrue(parsed.force)
    }

    func testRejectsUnknownOptionsAndMultipleProviders() {
        XCTAssertThrowsError(try CLIArguments.parse(["--json"]))
        XCTAssertThrowsError(try CLIArguments.parse(["claude", "codex"]))
    }

    func testSoftLimitCheckRequiresOneExactCardAndRejectsForce() throws {
        let parsed = try CLIArguments.parse(["soft-limit", "check", "Codex"])
        XCTAssertEqual(parsed.softLimitCardID, "codex")
        XCTAssertNil(parsed.providerID)
        for arguments in [
            ["soft-limit"], ["soft-limit", "check"], ["soft-limit", "start", "codex"],
            ["soft-limit", "check", ""], ["soft-limit", "check", "--force"],
            ["soft-limit", "check", "codex", "--force"]
        ] {
            XCTAssertThrowsError(try CLIArguments.parse(arguments))
        }
    }

    func testSoftLimitCheckJSONAndExitCodes() throws {
        let results: [(SoftLimitCheckStatus, Int32)] = [(.disabled, 0), (.belowLimit, 0), (.reached, 3), (.unknown, 4)]
        for (status, code) in results {
            let result = SoftLimitCheckOutput(cardId: "codex", status: status)
            let json = try XCTUnwrap(
                JSONSerialization.jsonObject(with: JSONEncoder().encode(result)) as? [String: String])
            XCTAssertEqual(json, ["cardId": "codex", "status": status.rawValue])
            XCTAssertEqual(result.exitCode, code)
        }
    }
}
