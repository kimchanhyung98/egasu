import Foundation

/// 이전 설치기가 쓴 두 파일에서 짝이 맞는 Claude 블록 마커만 확인.
struct LegacyClaudeShellSetup: Sendable {
    var found: [String] = []
    var unreadable: [String] = []

    @concurrent
    static func check(in home: URL = FileManager.default.homeDirectoryForCurrentUser) async -> Self {
        var result = Self()
        for path in [".zshrc", ".config/fish/config.fish"] {
            guard !Task.isCancelled else { break }
            let file = home.appendingPathComponent(path).resolvingSymlinksInPath()
            do {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                    throw POSIXError(.EFTYPE)
                }
                var sawStart = false
                for try await line in file.lines {
                    if line == "# >>> OpenUsage claude account switching >>>" {
                        sawStart = true
                    } else if sawStart && line == "# <<< OpenUsage claude account switching <<<" {
                        result.found.append("~/\(path)")
                        break
                    }
                }
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile {
                continue
            } catch {
                guard !Task.isCancelled else { break }
                result.unreadable.append("~/\(path)")
                AppDiagnostics.failure(
                    .accountReconcile, error: error, providerID: "claude", localContext: "legacy shell setup check")
            }
        }
        return result
    }
}
