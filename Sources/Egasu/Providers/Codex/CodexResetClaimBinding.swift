import Foundation

/// 표시한 사용량의 인증 출처·주체를 고정. 신원 미해석 토큰은 같은 인증 사본에만 소비 허용.
struct CodexResetClaimBinding: Hashable, Sendable {
    let source: CodexAuthState.Source
    private let accountID: String?
    private let identity: Identity

    private enum Identity: Hashable, Sendable {
        case account(String)
        case credential(Data)
    }

    init?(authState: CodexAuthState) {
        guard let identity = Self.identity(for: authState.auth) else { return nil }
        source = authState.source
        accountID = authState.auth.tokens?.accountID
        self.identity = identity
    }

    private static func identity(for auth: CodexAuth) -> Identity? {
        guard let tokens = auth.tokens, tokens.accessToken?.isEmpty == false else { return nil }
        let payloads = [tokens.accessToken, tokens.idToken].compactMap { $0.flatMap(ProviderParse.jwtPayload) }
        let subjects = payloads.compactMap { ($0["sub"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty }
        let accounts = ([tokens.accountID] + payloads.map { DefaultAccountObserver.chatGPTAccountID(inIDTokenPayload: $0) })
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty?.lowercased() }
        guard Set(subjects).count <= 1, Set(accounts).count <= 1 else { return nil }
        // ID 토큰은 충돌 검사에만 사용. 액세스 토큰이 증명하지 못한 주체로 토큰 교체를 허용하지 않음.
        var accessIdentity = auth
        accessIdentity.tokens?.idToken = nil
        if let account = CodexWeeklyTimerIdentity.accountKey(for: accessIdentity) {
            return .account(account)
        } else if let fingerprint = CodexWeeklyTimerIdentity.generationFingerprint(for: auth) {
            return .credential(fingerprint)
        } else {
            return nil
        }
    }

    /// 액세스 토큰에서 검증한 계정만 사용. 자격 증명 사본의 지문은 계정 간 비교에서 제외.
    var verifiedAccountKey: String? {
        guard case .account(let key) = identity else { return nil }
        return key
    }

    /// 저장 원문도 조회와 같은 사용자·워크스페이스 규칙으로 대조.
    static func verifiedAccountKey(for credential: String) -> String? {
        guard let auth = CodexAuthStore.parseAuth(credential), case .account(let key) = identity(for: auth) else {
            return nil
        }
        return key
    }

    func matches(_ authState: CodexAuthState) -> Bool {
        Self(authState: authState) == self
    }
}
