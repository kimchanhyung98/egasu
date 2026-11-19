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
            // 여러 줄의 인용문·heredoc 안에서는 같은 텍스트가 함수 선언의 증거가 아님.
            guard lines[..<first].allSatisfy({ Self.isStandaloneLine(content($0)) }) else {
                throw ClaudeSharedLoginRoute.UnrecognizedSetup()
            }
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

        private static func isStandaloneLine(_ line: String) -> Bool {
            var quote: Character?
            var escaped = false
            var previous: Character?
            for character in line {
                defer { previous = character }
                if escaped {
                    escaped = false
                } else if character == "\\", quote != "'" {
                    escaped = true
                } else if let open = quote {
                    if character == open { quote = nil }
                } else if character == "#" && (previous == nil || previous?.isWhitespace == true) {
                    break
                } else if ["'", "\"", "`"].contains(character) {
                    quote = character
                } else if character == "<", previous == "<" {
                    return false
                }
            }
            return quote == nil && !escaped
        }
    }

    private let shell: Shell
    private let path: URL
    private let target: URL
    private let original: Data
    private let block: Range<Int>
    let configDirectory: String

    var relativePath: String { shell.relativePath }

    var hasConfigDirectorySetting: Bool {
        var outside = original
        outside.removeSubrange(block)
        return outside.split(separator: 0x0a).contains { bytes in
            let line = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#") else { return false }
            return line.range(
                of:
                    #"(?:^|[;\s])(?:CLAUDE_CONFIG_DIR\s*=|(?:export|typeset|declare|set|setenv)\s+[^#;]*\bCLAUDE_CONFIG_DIR\b)"#,
                options: .regularExpression) != nil
        }
    }

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
                bytes = try LocalTextFileAccessor.readRegularFile(target)
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
                guard path.resolvingSymlinksInPath().path == url.path,
                    try LocalTextFileAccessor.readRegularFile(url) == original
                else { throw POSIXError(.ESTALE) }
                let replacement = url.deletingLastPathComponent()
                    .appendingPathComponent(url.lastPathComponent + "." + UUID().uuidString + ".egasu-recovery")
                try files.copyItem(at: url, to: replacement)
                var exchanged = false
                defer { if !exchanged { try? files.removeItem(at: replacement) } }
                var updated = original
                updated.removeSubrange(block)
                // 복사한 일반 파일의 권한·확장 속성을 유지하며 내용만 교체.
                let fd = Darwin.open(replacement.path, O_WRONLY | O_CLOEXEC | O_NONBLOCK | O_NOFOLLOW)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var info = stat()
                guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw POSIXError(.EFTYPE) }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: updated)
                try handle.close()
                guard path.resolvingSymlinksInPath().path == url.path else { throw POSIXError(.ESTALE) }
                try Self.exchange(replacement, with: url)
                exchanged = true
                try Self.verifyDisplacedProfile(at: replacement, target: url, original: original, updated: updated)
            }
        }
        if let coordinatorError { throw coordinatorError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    private static func exchange(_ first: URL, with second: URL) throws {
        guard renamex_np(first.path, second.path, UInt32(RENAME_SWAP)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    static func verifyDisplacedProfile(at displaced: URL, target: URL, original: Data, updated: Data) throws {
        guard (try? LocalTextFileAccessor.readRegularFile(displaced)) == original else {
            // 교환 시점의 실제 파일을 복구. 두 번째 편집이 끼어들면 그 파일도 같은 디렉터리에 보존.
            if (try? LocalTextFileAccessor.readRegularFile(target)) == updated {
                try exchange(displaced, with: target)
                if (try? LocalTextFileAccessor.readRegularFile(displaced)) == updated {
                    try FileManager.default.removeItem(at: displaced)
                }
            }
            throw ClaudeShellLoginMigrationError.concurrentProfileEdit
        }
        try FileManager.default.removeItem(at: displaced)
    }
}
