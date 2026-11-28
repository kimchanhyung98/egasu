import Foundation

extension ClaudeSharedLoginRoute {
    enum CredentialFallbacks {
        case disabled
        case legacyKeychain
        case legacyKeychainAndFile
    }

    typealias Login = (text: String, source: ClaudeCredentialState.Source, oauth: ClaudeOAuth)

    /// 현재 CLI 경로의 로그인 하나만 선택. Keychain 읽기 실패는 파일 로그인이 있다는 뜻이 아님.
    /// 공유 항목은 CLI 작성 도구로 조회. 잠긴 Keychain의 승인은 도구의 정책을 따름.
    func readCredential(
        keychain: any KeychainAccessing, files: any TextFileAccessing, filePath: String,
        environment: any EnvironmentReading, allowInteraction: Bool, requireCompleteOAuth: Bool = false,
        fallbacks: CredentialFallbacks = .legacyKeychainAndFile
    ) throws -> (login: Login?, currentUserText: String?) {
        typealias Source = ClaudeCredentialState.Source
        func login(_ text: String?, from source: Source) throws -> Login? {
            guard let text else { return nil }
            guard let parsed = ClaudeAuthStore.parseCredentials(text) else {
                if source == .file { throw CocoaError(.fileReadCorruptFile) }
                throw KeychainError.invalidData
            }
            guard let oauth = parsed.claudeAiOauth else { return nil }
            guard oauth.accessToken?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty != nil else {
                if requireCompleteOAuth, oauth.refreshToken?.nilIfEmpty != nil {
                    throw ClaudeShellLoginMigrationError.incompleteOAuth
                }
                return nil
            }
            return (text, source, oauth)
        }

        let service = service(environment: environment)
        let current = try keychain.readCLISharedPassword(service: service, forCurrentUser: true)
        if let credential = try login(current, from: .keychainCurrentUser(service: service)) {
            return (credential, current)
        }
        guard case .plain = self, fallbacks != .disabled else { return (nil, current) }
        let legacy = try keychain.readCLISharedPassword(service: service, forCurrentUser: false)
        if let credential = try login(legacy, from: .keychainLegacy(service: service)) {
            return (credential, current)
        }
        guard fallbacks == .legacyKeychainAndFile else { return (nil, current) }
        return (try login(files.readTextIfPresent(filePath), from: .file), current)
    }
}
