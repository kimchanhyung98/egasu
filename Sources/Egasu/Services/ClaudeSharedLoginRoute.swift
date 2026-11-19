import Darwin
import Foundation

/// 이전 설치기가 로그인 셸에 남긴 고정 블록만 해석. 사용자 셸 코드는 실행하지 않음.
enum ClaudeSharedLoginRoute: Hashable, Sendable {
    case plain
    case legacy(configDir: String)

    struct UnrecognizedSetup: LocalizedError, UserPresentableError {
        var presentationMessage: LocalizedMessage {
            .init(
                "egasu could not identify the Claude sign-in location from your shell configuration. Check the old OpenUsage Claude block in your login shell, then try again."
            )
        }

        var errorDescription: String? { presentationMessage.key }
    }

    static func resolve(
        homeDirectory: URL, files: any TextFileAccessing, environment: any EnvironmentReading,
        loginShell: () -> String? = systemLoginShell
    ) throws -> Self {
        guard let shellPath = environment.value(for: "SHELL")?.nilIfEmpty ?? loginShell() else {
            throw UnrecognizedSetup()
        }
        guard let shell = ClaudeLegacyShellProfile.Shell(rawValue: URL(fileURLWithPath: shellPath).lastPathComponent)
        else { return .plain }
        let text: String
        do {
            guard
                let contents = try files.readTextIfPresent(
                    homeDirectory.appendingPathComponent(shell.relativePath).path)
            else { return .plain }
            text = contents
        } catch {
            throw UnrecognizedSetup()
        }
        let configDir = ClaudeLegacyShellProfile.configDirectory(in: homeDirectory)
        return try shell.installedRange(in: Data(text.utf8), configDirectory: configDir) == nil
            ? .plain : .legacy(configDir: configDir)
    }

    private static func systemLoginShell() -> String? {
        var entry = passwd()
        var result: UnsafeMutablePointer<passwd>?
        var buffer = [CChar](repeating: 0, count: max(16384, sysconf(_SC_GETPW_R_SIZE_MAX)))
        return buffer.withUnsafeMutableBufferPointer { storage in
            guard let bytes = storage.baseAddress, getpwuid_r(getuid(), &entry, bytes, storage.count, &result) == 0,
                result != nil, let path = entry.pw_shell
            else { return nil }
            return String(cString: path).nilIfEmpty
        }
    }

    var configDirectory: String? {
        if case .legacy(let configDir) = self { return configDir }
        return nil
    }

    func service(environment: any EnvironmentReading) -> String {
        if let configDirectory {
            return ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: configDirectory, environment: environment)
        }
        return ClaudeAuthStore.baseKeychainServiceName(environment: environment)
    }

    func stateURL(homeDirectory: URL) -> URL {
        (configDirectory.map { URL(fileURLWithPath: $0) } ?? homeDirectory).appendingPathComponent(".claude.json")
    }
}
