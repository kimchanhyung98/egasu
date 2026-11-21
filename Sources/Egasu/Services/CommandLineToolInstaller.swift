import AppKit
import Foundation
import Observation

/// 번들 CLI를 가리키는 심볼릭 링크를 설치. 기본 경로는 `/usr/local/bin/egasu`.
/// 안정된 앱 내부 경로를 가리키는 심볼릭 링크로 Sparkle 업데이트 후에도 연결 유지.
@MainActor
@Observable
final class CommandLineToolInstaller {
    enum Status: Equatable {
        case notInstalled
        case installed
        case conflict
    }

    enum Operation { case install, uninstall }
    enum OperationResult { case success, cancelled, failure(String, code: Int? = nil) }

    private(set) var status: Status
    private(set) var errorMessage: String?
    private(set) var isVerifying = false
    var isConfirmingRemoval = false

    let destinationPath: String
    var bundledExecutablePath: String? { isExecutableHelper(at: sourcePath) ? sourcePath : nil }
    private let sourcePath: String
    private let fileManager: FileManager
    private let performPrivileged: @MainActor (Operation, String, String) -> OperationResult
    private let waitForVerification: @MainActor () async -> Void

    init(
        sourcePath: String = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/egasu").path,
        destinationPath: String = "/usr/local/bin/egasu",
        fileManager: FileManager = .default,
        waitForVerification: @escaping @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1)) },
        performPrivileged: (@MainActor (Operation, String, String) -> OperationResult)? = nil
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fileManager = fileManager
        self.waitForVerification = waitForVerification
        self.performPrivileged = performPrivileged ?? { operation, source, destination in
            CommandLineToolInstaller.runPrivileged(
                operation: operation,
                sourcePath: source,
                destinationPath: destination
            )
        }
        self.status = Self.currentStatus(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            fileManager: fileManager
        )
    }

    func refreshStatus() {
        status = Self.currentStatus(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            fileManager: fileManager
        )
    }

    func install() async {
        guard !isVerifying else { return }
        refreshStatus()
        guard status != .installed else { return }
        guard status != .conflict else {
            errorMessage = L10n.errors("%@ already exists and wasn't installed by egasu.", destinationPath)
            return
        }
        guard isExecutableHelper(at: sourcePath) else {
            errorMessage = L10n.errors("The bundled terminal helper couldn't be found. Reinstall egasu and try again.")
            AppDiagnostics.record(.cliInstall, result: .failure, category: .storage,
                                  localContext: "Bundled terminal helper is missing or not executable")
            return
        }
        errorMessage = nil
        let result = performPrivileged(.install, sourcePath, destinationPath)
        if case .success = result {
            isVerifying = true
            defer { isVerifying = false }
            await waitForVerification()
            refreshStatus()
            guard status == .installed, isExecutableHelper(at: destinationPath) else {
                errorMessage = L10n.errors(
                    "The terminal helper could not be verified. Check that the shortcut points to the executable bundled with egasu."
                )
                AppDiagnostics.record(
                    .cliInstall, result: .failure, category: .storage,
                    localContext: "Installed terminal helper link or executable could not be verified")
                return
            }
        }
        handle(result, action: "install", operation: .cliInstall)
    }

    func uninstall() {
        guard !isVerifying else { return }
        refreshStatus()
        guard status == .installed else { return }
        errorMessage = nil
        handle(performPrivileged(.uninstall, sourcePath, destinationPath), action: "remove", operation: .cliRemove)
    }

    private func isExecutableHelper(at path: String) -> Bool {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        return fileManager.isExecutableFile(atPath: path)
            && (try? target.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    private func handle(_ result: OperationResult, action: String, operation: DiagnosticOperation) {
        switch result {
        case .success:
            AppDiagnostics.record(operation, result: .success)
            errorMessage = nil
        case .cancelled:
            AppDiagnostics.record(operation, result: .cancelled)
        case .failure(let message, let code):
            let context = "Terminal helper \(action) failed"
                + (code.map { "; error_code=\($0)" } ?? "")
            let category: ErrorCategory
            if let code, (1...255).contains(code) {
                category = .subprocess
            } else if code == -60005 {
                category = .permission
            } else {
                category = .other
            }
            AppDiagnostics.record(operation, result: .failure, category: category, localContext: context)
            errorMessage = action == "install"
                ? L10n.errors("Couldn't install the terminal helper: %@", L10n.errors(message))
                : L10n.errors("Couldn't remove the terminal helper: %@", L10n.errors(message))
        }
        refreshStatus()
    }

    private static func currentStatus(
        sourcePath: String,
        destinationPath: String,
        fileManager: FileManager
    ) -> Status {
        guard let target = try? fileManager.destinationOfSymbolicLink(atPath: destinationPath) else {
            return fileManager.fileExists(atPath: destinationPath) ? .conflict : .notInstalled
        }
        // 설치한 링크는 정확한 절대 경로로 식별. 관리자 권한으로 제거하기 직전 같은 경로인지 재확인.
        return target == sourcePath ? .installed : .conflict
    }

    private static func runPrivileged(
        operation: Operation,
        sourcePath: String,
        destinationPath: String
    ) -> OperationResult {
        let directory = (destinationPath as NSString).deletingLastPathComponent
        let command: String
        switch operation {
        case .install:
            command = """
            if [ -e \(shellQuote(destinationPath)) ] || [ -L \(shellQuote(destinationPath)) ]; then exit 73; fi
            /bin/mkdir -p \(shellQuote(directory)) && /bin/ln -s \(shellQuote(sourcePath)) \(shellQuote(destinationPath))
            """
        case .uninstall:
            command = """
            target=$(/usr/bin/readlink \(shellQuote(destinationPath))) || exit 74
            [ "$target" = \(shellQuote(sourcePath)) ] || exit 75
            /bin/rm \(shellQuote(destinationPath))
            """
        }

        return runPrivileged(command: command)
    }

    static func replacePrivilegedLink(at url: URL, expected: String, target: String) throws {
        switch runPrivileged(command: replacementCommand(at: url, expected: expected, target: target)) {
        case .success: return
        case .cancelled: throw CocoaError(.userCancelled)
        case .failure(let message, let code):
            throw NSError(domain: NSCocoaErrorDomain, code: CocoaError.fileWriteNoPermission.rawValue, userInfo: [
                NSLocalizedDescriptionKey: message,
                NSUnderlyingErrorKey: NSError(domain: NSOSStatusErrorDomain, code: code ?? -1)
            ])
        }
    }

    /// 승인 대기 중 다른 프로세스가 바꾼 링크는 보존. 임시 링크를 같은 파일시스템에서 교체.
    static func replacementCommand(at url: URL, expected: String, target: String) -> String {
        let template = url.deletingLastPathComponent().appendingPathComponent(".egasu-link.XXXXXX").path
        return """
        set -e
        [ -L \(shellQuote(url.path)) ] || exit 74
        [ "$(/usr/bin/readlink \(shellQuote(url.path)))" = \(shellQuote(expected)) ] || exit 75
        temporary=$(/usr/bin/mktemp -d \(shellQuote(template)))
        trap '/bin/rm -rf "$temporary"' EXIT
        /bin/ln -s \(shellQuote(target)) "$temporary/link"
        [ -L \(shellQuote(url.path)) ] || exit 74
        [ "$(/usr/bin/readlink \(shellQuote(url.path)))" = \(shellQuote(expected)) ] || exit 75
        /bin/mv -h -f "$temporary/link" \(shellQuote(url.path))
        """
    }

    private static func runPrivileged(command: String) -> OperationResult {
        let source = "do shell script \(appleScriptStringLiteral(command)) with administrator privileges"
        guard let script = NSAppleScript(source: source) else {
            return .failure("macOS couldn't prepare the authorization request.")
        }
        var errorInfo: NSDictionary?
        script.executeAndReturnError(&errorInfo)
        guard let errorInfo else { return .success }
        if let code = errorInfo[NSAppleScript.errorNumber] as? Int, code == -128 {
            return .cancelled
        }
        return .failure(
            (errorInfo[NSAppleScript.errorMessage] as? String)
                ?? "macOS rejected the authorization request.",
            code: errorInfo[NSAppleScript.errorNumber] as? Int
        )
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptStringLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
