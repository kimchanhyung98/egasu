import Foundation

/// 기기에 저장된 OpenCode Go 자격 증명 조회. 네트워크 접근 없음.
/// `opencode-go` 키로 로컬 로그인 감지와 Go 기간 표시 여부 판단.
struct OpenCodeAuthStore: Sendable {
    var files: TextFileAccessing
    var environment: EnvironmentReading
    var homeDirectory: @Sendable () -> URL

    init(
        files: TextFileAccessing = LocalTextFileAccessor(),
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser }
    ) {
        self.files = files
        self.environment = environment
        self.homeDirectory = homeDirectory
    }

    var dataDirectory: String {
        OpenCodePaths.dataDirectory(environment: environment, homeDirectory: homeDirectory())
    }

    var authFilePath: String {
        OpenCodePaths.authFilePath(dataDirectory: dataDirectory)
    }

    /// 유효한 환경 인증 JSON은 파일을 대체. 선택한 인증의 Go API 키가 개별 환경 변수보다 우선.
    func goAPIKey() throws -> String? {
        let environmentKey = environment.value(for: "OPENCODE_GO_API_KEY")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        if let content = environment.value(for: "OPENCODE_AUTH_CONTENT"), !content.isEmpty {
            if let parsed = try? JSONSerialization.jsonObject(with: Data(content.utf8), options: .fragmentsAllowed) {
                return Self.goKey(in: parsed) ?? environmentKey
            }
            AppLog.warn(LogTag.plugin("opencode"), "OPENCODE_AUTH_CONTENT invalid stage=decode category=decoding")
        }
        do {
            return try fileGoKey() ?? environmentKey
        } catch OpenCodeUsageError.credentialsUnreadable(let detail) {
            guard let environmentKey else { throw OpenCodeUsageError.credentialsUnreadable(detail: detail) }
            AppLog.warn(LogTag.plugin("opencode"), "auth.json unreadable: \(detail)")
            return environmentKey
        }
    }

    private func fileGoKey() throws -> String? {
        let text: String?
        do {
            text = try files.readTextIfPresent(authFilePath)
        } catch {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "stage=read \(AppLog.errorDetails(error))")
        }
        guard let text else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            throw OpenCodeUsageError.credentialsUnreadable(detail: "stage=decode category=decoding")
        }
        return Self.goKey(in: object)
    }

    private static func goKey(in object: Any) -> String? {
        guard let entries = object as? [String: Any], let entry = entries["opencode-go"] as? [String: Any],
            entry["type"] as? String == "api",
            let key = entry["key"] as? String
        else { return nil }
        return key.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
}
