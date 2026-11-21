import Darwin
import Foundation
import Egasu

@main
struct EgasuCLI {
    static func main() async {
        do {
            let arguments = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
            if arguments.showHelp {
                print(help)
                return
            }

            let app = AppBundleLocator.current
            if arguments.showVersion {
                print(app.version.map { "egasu \($0)" } ?? "egasu (development build)")
                return
            }

            guard let defaults = UserDefaults(suiteName: app.bundleIdentifier) else {
                throw CLIError.appDefaultsUnavailable
            }
            AppLog.reloadLevel(defaults: defaults)
            if let account = arguments.account {
                let code = try AccountCommandRunner(defaults: defaults).run(account)
                exit(code)
            }
            let reader = UsageReader(userDefaults: defaults)
            if let cardID = arguments.softLimitCardID {
                let status = try await reader.checkSoftLimit(cardID: cardID)
                let result = SoftLimitCheckOutput(cardId: cardID, status: status)
                writeJSON(try JSONEncoder().encode(result))
                exit(result.exitCode)
            }
            let result = try await reader.read(
                providerID: arguments.providerID,
                force: arguments.force
            )
            writeJSON(result.data)
            if !result.warnings.isEmpty {
                result.warnings.forEach { writeError("warning: \($0)") }
                exit(4)
            }
        } catch CLIError.usage(let message) {
            fail("\(message)\nRun 'egasu --help' for usage.", code: 2)
        } catch CLIError.appDefaultsUnavailable {
            fail("Could not open the egasu settings domain.", code: 4)
        } catch let error as AccountProfileError {
            switch error {
            case .registryUnreadable:
                fail(accountErrorMessage(error), code: 4)
            default:
                fail(accountErrorMessage(error), code: 2)
            }
        } catch UsageReaderError.unknownProvider(let providerID) {
            fail("Unknown provider: \(providerID)", code: 2)
        } catch {
            fail(error.localizedDescription, code: 4)
        }
    }

    private static func writeJSON(_ data: Data) {
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func writeError(_ message: String) {
        FileHandle.standardError.write(Data("egasu: \(message)\n".utf8))
    }

    private static func fail(_ message: String, code: Int32) -> Never {
        writeError(message)
        exit(code)
    }

    private static let help = """
        Usage: egasu [provider] [--force]
               egasu account <command> ...
               egasu soft-limit check <card-id>

        Provider lookup prints limits as JSON and uses egasu's shared cache (5 minutes; Claude: 15 minutes).

        Options:
          --force      Skip fresh cache; Claude rate-limit waits still apply
          -v, --version
          -h, --help

        Account commands (read-only; manage and switch accounts in egasu Settings):
          account list [claude|codex] [--json]
          account current [claude|codex]

        Soft Limit preflight prints the active card's weekly or monthly quota status as JSON.
          Exit 0: disabled or below limit. 3: threshold reached. 4: quota unknown. 2: invalid input.
        """
}

struct SoftLimitCheckOutput: Encodable {
    let cardId: String
    let status: SoftLimitCheckStatus

    var exitCode: Int32 {
        switch status {
        case .disabled, .belowLimit: 0
        case .reached: 3
        case .unknown: 4
        }
    }
}
