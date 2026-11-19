import Darwin
import Foundation

/// 셸을 실행하지 않고 이전 설치기의 원본 블록과 제거할 바이트 범위 확인.
struct ClaudeLegacyShellProfile {
    static let startMarker = "# >>> OpenUsage claude account switching >>>"
    static let endMarker = "# <<< OpenUsage claude account switching <<<"

    enum Shell: String, CaseIterable {
        case zsh, fish

        var relativePath: String {
            self == .zsh ? ".zshrc" : ".config/fish/config.fish"
        }

        func installedRange(in bytes: Data, configDirectory: String) throws -> Range<Int>? {
            let start = ClaudeLegacyShellProfile.startMarker
            let end = ClaudeLegacyShellProfile.endMarker
            let lines = bytes.split(separator: 0x0A, omittingEmptySubsequences: false)
            func content(_ line: Data) -> String {
                String(decoding: line.last == 0x0D ? line.dropLast() : line, as: UTF8.self)
            }

            let markers = lines.indices.filter {
                let trimmed = content(lines[$0]).trimmingCharacters(in: .whitespaces)
                return trimmed == start || trimmed == end
            }
            guard !markers.isEmpty else { return nil }
            guard markers.count == 2 else { throw ClaudeSharedLoginRoute.UnrecognizedSetup() }
            let first = markers[0]
            let last = markers[1]
            let quoted = "'" + configDirectory.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let removals = AccountSignInLauncher.claudeAuthEnvironmentRemovals.map { "-u \($0)" }.joined(separator: " ")
            let command = "  env \(removals) CLAUDE_CONFIG_DIR=\(quoted) command claude"
            let expected =
                self == .zsh
                ? [start, "unalias claude 2>/dev/null", "function claude {", command + " \"$@\"", "}", end]
                : [start, "functions -e claude 2>/dev/null", "function claude", command + " $argv", "end", end]
            guard lines[first...last].map(content) == expected else { throw ClaudeSharedLoginRoute.UnrecognizedSetup() }
            // 끝 마커 뒤의 줄바꿈만 포함해 앞뒤 설정의 빈 줄과 줄바꿈 형식 보존.
            let upperBound = min(lines[last].endIndex + 1, bytes.endIndex)
            return lines[first].startIndex..<upperBound
        }
    }

    private let shell: Shell
    private let path: URL
    private let target: URL
    private let original: Data
    private let block: Range<Int>
    let configDirectory: String

    var relativePath: String { shell.relativePath }

    static func configDirectory(in home: URL) -> String {
        home.resolvingSymlinksInPath().standardizedFileURL.appendingPathComponent(".claude").path
    }

    static func find(in home: URL) throws -> [Self] {
        let directory = configDirectory(in: home)
        return try Shell.allCases.compactMap { shell in
            let path = home.appendingPathComponent(shell.relativePath)
            let target = path.resolvingSymlinksInPath()
            let bytes: Data
            do {
                bytes = try readRegularFile(target)
            } catch let error as POSIXError where error.code == .ENOENT {
                return nil
            }
            guard let block = try shell.installedRange(in: bytes, configDirectory: directory) else { return nil }
            return Self(
                shell: shell, path: path, target: target, original: bytes, block: block, configDirectory: directory)
        }
    }

    /// 인증 이전 중 바뀐 설정은 덮어쓰지 않고 다음 실행에서 다시 확인.
    func remove() throws {
        var coordinatorError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinatorError) { url in
            result = Result {
                let files = FileManager.default
                let temp = try files.url(
                    for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: url, create: true)
                defer { try? files.removeItem(at: temp) }
                let replacement = temp.appendingPathComponent("profile")
                var updated = original
                updated.removeSubrange(block)
                try updated.write(to: replacement)
                guard path.resolvingSymlinksInPath().path == url.path, try Self.readRegularFile(url) == original
                else { throw POSIXError(.ESTALE) }
                // 원래 대상의 권한·확장 속성을 승계하며 심볼릭 링크의 대상 파일만 교체.
                _ = try files.replaceItemAt(url, withItemAt: replacement)
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    private static func readRegularFile(_ url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
        return try handle.readToEnd() ?? Data()
    }
}
