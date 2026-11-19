import CryptoKit
import Foundation

private struct ClaudeUsageIdentityEnvironment: EnvironmentReading {
    let base: EnvironmentReading
    let configDir: String?

    func value(for key: String) -> String? {
        key == "CLAUDE_CONFIG_DIR" ? configDir : base.value(for: key)
    }
}

struct ClaudeAuthStore: Sendable {
    private static let defaultClaudeHome = "~/.claude"
    private static let credentialFileName = ".credentials.json"
    private static let keychainServicePrefix = "Claude Code"
    private static let prodBaseAPIURL = "https://api.anthropic.com"
    private static let prodRefreshURL = "https://platform.claude.com/v1/oauth/token"
    private static let prodClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    private static let nonProdClientID = "22422756-60c9-4084-8eb7-27705fd5cf9a"

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var desktop: ClaudeDesktopAuthStore
    var now: @Sendable () -> Date
    let scope: ClaudeCredentialScope
    /// `.standard` store의 Claude Desktop credential 폴백 허용 여부. 추가 계정 카드가 생기면
    /// catalog가 OFF — Desktop 로그인의 소속 카드를 몰라 다른 계정 카드에 usage가 섞일 수 있음.
    let allowsDesktopFallback: Bool
    /// 관리형 기본 카드는 CLI가 쓰는 공유 로그인과 그 경로의 계정 정보만 조회.
    let pinsSharedHome: Bool
    private let sharedLoginHome: URL?

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        desktop: ClaudeDesktopAuthStore? = nil,
        scope: ClaudeCredentialScope = .standard,
        allowsDesktopFallback: Bool = true,
        pinsSharedHome: Bool = false,
        sharedLoginHome: URL? = nil,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.desktop = desktop ?? ClaudeDesktopAuthStore(files: files, now: now)
        self.scope = scope
        self.allowsDesktopFallback = allowsDesktopFallback
        self.pinsSharedHome = pinsSharedHome
        self.sharedLoginHome = sharedLoginHome
        self.now = now
    }

    /// 디스크/keychain의 credential source 전부를 keychain-우선 고정 순서로 반환 — refresh 루프의 폴백 순회용.
    /// 매 refresh마다 재조회, 메모리 캐시 없음.
    func loadCredentialSet(
        allowDesktopInteraction: Bool = false,
        forceDesktopFallback: Bool = false,
        allowAccountInteraction: Bool = false
    ) -> ClaudeCredentialLoad {
        if case .accountSnapshot(let profileID) = scope {
            let desktopStatus: ClaudeDesktopCredentialStatus = forceDesktopFallback ? .notFound : .notChecked
            do {
                let candidate = try loadAccountSnapshot(
                    profileID: profileID, allowInteraction: allowAccountInteraction
                )
                return ClaudeCredentialLoad(candidates: [candidate].compactMap { $0 }, desktopStatus: desktopStatus)
            } catch {
                return ClaudeCredentialLoad(candidates: [], desktopStatus: desktopStatus, credentialError: error)
            }
        }
        let route: ClaudeSharedLoginRoute?
        do {
            route = scope == .standard ? try sharedLoginRoute() : nil
            if let route, pinsSharedHome || route.configDirectory != nil {
                let credential = try route.readCredential(
                    keychain: keychain, files: files, filePath: credentialsPath(),
                    environment: environment, allowInteraction: allowAccountInteraction
                ).login
                let candidates =
                    credential.map {
                        [
                            ClaudeCredentialState(
                                oauth: $0.oauth, source: $0.source, sourceText: $0.text, inferenceOnly: false,
                                accountIdentityKey: usageAccountIdentity(sharedRoute: route),
                                sharedLoginRoute: route
                            )
                        ]
                    } ?? []
                return ClaudeCredentialLoad(
                    candidates: candidates,
                    desktopStatus: forceDesktopFallback ? .notFound : .notChecked
                )
            }
        } catch {
            return ClaudeCredentialLoad(candidates: [], desktopStatus: .notChecked, credentialError: error)
        }
        var stored = orderedStoredCandidates(sharedRoute: route)
        let identity = usageAccountIdentity(sharedRoute: route)
        // 홈 메타데이터는 우선 사용되는 로그인만 식별. 별도 파일의 폴백 토큰까지 같은 계정으로 추정 금지.
        if let index = stored.firstIndex(where: { $0.hasUsableAccessToken && liveUsageAvailability($0) == .available }) {
            stored[index].accountIdentityKey = identity
        }
        var desktopStatus: ClaudeDesktopCredentialStatus = .notChecked
        // CLI 로그인이 source of truth, Desktop은 폴백 전용 — `.configDir` 카드는 Desktop 미조회(다른 카드의 로그인).
        let desktopAllowed = scope == .standard && allowsDesktopFallback
        if forceDesktopFallback, !desktopAllowed {
            // 안전한 Desktop 후보 없음을 알려 원래 CLI auth 에러 보존 — generic "not logged in" 변환 방지.
            desktopStatus = .notFound
        }
        let hasUsableCLILogin = stored.contains {
            $0.hasUsableAccessToken && liveUsageAvailability($0) == .available
        }
        if desktopAllowed, forceDesktopFallback || !hasUsableCLILogin {
            let result = desktop.load(allowInteraction: allowDesktopInteraction)
            desktopStatus = result.status
            if let oauth = result.oauth {
                stored.insert(ClaudeCredentialState(
                    oauth: oauth,
                    source: .desktop,
                        sourceText: nil,
                    inferenceOnly: false,
                    accountIdentityKey: result.accountIdentityKey
                ), at: 0)
            }
        }

        let candidates = applyingEnvironmentToken(to: stored)
        return ClaudeCredentialLoad(candidates: candidates, desktopStatus: desktopStatus)
    }

    func loadCredentialCandidates() -> [ClaudeCredentialState] {
        loadCredentialSet().candidates
    }

    /// keychain secret을 읽지 않는 로컬 로그인 흔적 확인 — 매 실행 seeding probe(`NewProviderSeeder`)용,
    /// 권한 dialog 발생 금지. `.standard` 카드는 `ClaudeProvider.hasLocalCredentials`의 확장 probe 사용.
    func hasCredentialFootprint() -> Bool {
        switch scope {
        case .standard:
            return !loadCredentialSet().candidates.isEmpty
        case .configDir:
            if files.exists(credentialsPath()) { return true }
            return keychainServiceCandidates().contains {
                keychain.genericPasswordExists(service: $0) == true
            }
        case .accountSnapshot(let profileID):
            // 이미 등록된 계정은 일시적인 확인 실패로 활성화 대상에서 제외하지 않음.
            return keychain.genericPasswordExists(
                service: AccountCredentialVault.service(family: "claude", profileID: profileID)
            ) != false
        }
    }

    private func applyingEnvironmentToken(to stored: [ClaudeCredentialState]) -> [ClaudeCredentialState] {
        // ambient env 토큰은 DEFAULT 로그인 소유 — scoped 카드 상속 금지(계정 간 토큰 누출).
        guard case .standard = scope else { return stored }
        guard let envAccessToken = envText("CLAUDE_CODE_OAUTH_TOKEN") else {
            return stored
        }
        // 명시적 `CLAUDE_CODE_OAUTH_TOKEN`은 inference 전용(usage endpoint 403) — 라이브 usage 가능한
        // 저장 로그인을 우선, env 토큰은 후순위 inference 전용 폴백. 저장 로그인 부재 시 유일 후보.
        let liveCapable = stored.filter { liveUsageAvailability($0) == .available }
        // plan 메타데이터는 실제 우선되는 credential에서 차용, source는 `.environment`로 정직하게 표기 —
        // 진단 로그가 실제 source를 가리키고 `save()`가 env 토큰을 keychain에 쓰지 않도록.
        let base = liveCapable.first ?? stored.first
        var oauth = base?.oauth ?? ClaudeOAuth()
        oauth.accessToken = envAccessToken
        let envCandidate = ClaudeCredentialState(
            oauth: oauth,
            source: .environment,
            sourceText: nil,
            inferenceOnly: true
        )
        return liveCapable.isEmpty ? [envCandidate] : liveCapable + [envCandidate]
    }

    func needsRefresh(_ oauth: ClaudeOAuth) -> Bool {
        guard let expiresAt = oauth.expiresAt else { return false }
        return expiresAt - now().timeIntervalSince1970 * 1000 <= 5 * 60 * 1000
    }

    func credentialGeneration(
        forceDesktopFallback: Bool = false, allowAccountInteraction: Bool = false
    ) throws -> ClaudeCredentialGeneration {
        let load = loadCredentialSet(
            forceDesktopFallback: forceDesktopFallback, allowAccountInteraction: allowAccountInteraction
        )
        if let error = load.credentialError { throw error }
        return ClaudeCredentialGeneration(load.candidates)
    }

    final class ManagedRotation: Sendable {
        private let sharedLock: SingleInstanceLock.Token?

        fileprivate init(sharedLock: SingleInstanceLock.Token?) {
            self.sharedLock = sharedLock
        }

        deinit { AccountCredentialMutationLock.endClaudeRotation() }
    }

    func beginManagedRotation(
        for state: ClaudeCredentialState, ifUnchanged expected: ClaudeCredentialGeneration,
        allowAccountInteraction: Bool
    ) throws -> ManagedRotation? {
        let home = sharedRotationHome(for: state)
        switch scope {
        case .standard where pinsSharedHome || home != nil, .accountSnapshot:
            let sharedLock = try home.map { try ClaudeLegacyShellMigration.acquireSharedLoginLock(home: $0) }
            try AccountCredentialMutationLock.beginClaudeRotation {
                if let home { try ClaudeLegacyShellMigration.checkPendingSharedLoginChanges(home: home) }
                guard try credentialGeneration(allowAccountInteraction: allowAccountInteraction) == expected
                else { throw ClaudeAuthError.credentialsChanged }
            }
            return ManagedRotation(sharedLock: sharedLock)
        default:
            return nil
        }
    }

    /// 같은 CLI 인증을 소비하는 갱신은 OAuth 요청부터 저장까지 운영·개발 앱과 직렬화.
    private func sharedRotationHome(for state: ClaudeCredentialState) -> URL? {
        guard scope == .standard, let home = sharedLoginHome else { return nil }
        if state.sharedLoginRoute != nil { return home }
        switch state.source {
        case .keychainCurrentUser(let service), .keychainLegacy(let service):
            return service == Self.baseKeychainServiceName(environment: environment) ? home : nil
        case .file:
            guard let override = claudeHomeOverride() else { return home }
            let resolved = URL(fileURLWithPath: (override as NSString).expandingTildeInPath).resolvingSymlinksInPath()
            return resolved.path == home.appendingPathComponent(".claude").resolvingSymlinksInPath().path ? home : nil
        default:
            return nil
        }
    }

    /// 유효 후보 집합이 그대로일 때만 OAuth rotation 저장 — generation 전체 비교로 상위 source 추가까지 감지.
    /// 저장소에 원자적 compare-and-swap이 없어 best-effort.
    func save(
        _ state: ClaudeCredentialState, ifUnchanged expected: ClaudeCredentialGeneration,
        allowAccountInteraction: Bool = false
    ) throws -> Bool {
        AccountCredentialMutationLock.acquire(family: "claude")
        defer { AccountCredentialMutationLock.release(family: "claude") }
        let current = loadCredentialSet(allowAccountInteraction: allowAccountInteraction)
        if let error = current.credentialError { throw error }
        guard ClaudeCredentialGeneration(current.candidates) == expected,
            let saved = current.candidates.first(where: { $0.source == state.source }),
            let sourceText = saved.sourceText,
            var document = ProviderParse.jsonObjectWithHexFallback(sourceText),
            var oauth = document["claudeAiOauth"] as? [String: Any]
        else { return false }

        // 같은 저장소에서 다시 읽은 원문에 회전한 값만 적용 — MCP 인증과 CLI 확장 필드 보존.
        if state.oauth.accessToken != saved.oauth.accessToken { oauth["accessToken"] = state.oauth.accessToken }
        if state.oauth.refreshToken != saved.oauth.refreshToken { oauth["refreshToken"] = state.oauth.refreshToken }
        if state.oauth.expiresAt != saved.oauth.expiresAt { oauth["expiresAt"] = state.oauth.expiresAt }
        document["claudeAiOauth"] = oauth
        let data = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
        let text = String(decoding: data, as: UTF8.self)

        switch state.source {
        case .file:
            try files.writeText(credentialsPath(), text)
        case .keychainCurrentUser(let service):
            try keychain.writeCLISharedPassword(service: service, value: text, forCurrentUser: true)
        case .keychainLegacy(let service):
            try keychain.writeCLISharedPassword(service: service, value: text, forCurrentUser: false)
        case .accountSnapshot(let profileID):
            try AccountCredentialVault(keychain: keychain).replaceCredential(
                text,
                family: "claude",
                profileID: profileID,
                allowInteraction: allowAccountInteraction
            )
        case .desktop:
            return false
        case .environment:
            return false
        }
        // credential blob·토큰 로깅 금지 — rotation 발생 사실과 대상 source만 기록.
        AppLog.debug(LogTag.auth("claude"), "persisted rotated credentials (source=\(state.source.label))")
        return true
    }

    /// credential의 라이브 usage endpoint(`/api/oauth/usage`) 호출 가능 여부 — usage 조회에는 `user:profile` scope 필요.
    enum LiveUsageAvailability: Equatable, Sendable {
        case available
        /// 명시적 `CLAUDE_CODE_OAUTH_TOKEN` — 설계상 inference 전용, spend 타일은 로컬 로그로 유지.
        case inferenceOnlyToken
        /// `user:profile` scope 없는 저장 로그인 — `claude` 재로그인 전까지 session/weekly 바 조회 불가.
        case missingProfileScope
    }

    /// usage endpoint 필수 scope — 없으면 inference 인증만 가능.
    static let usageScope = "user:profile"

    func liveUsageAvailability(_ state: ClaudeCredentialState) -> LiveUsageAvailability {
        if state.inferenceOnly { return .inferenceOnlyToken }
        // scopes 필드 이전의 구버전 credential은 "unknown, allow" 처리 — 권한 있는 토큰의 usage 억제 방지(없으면 403이 loudly 표면화).
        guard let scopes = state.oauth.scopes, !scopes.isEmpty else { return .available }
        return scopes.contains(Self.usageScope) ? .available : .missingProfileScope
    }

    func claudeHomeOverride() -> String? {
        pinsSharedHome ? nil : envText("CLAUDE_CONFIG_DIR")
    }

    // URL 검증 전의 resolved OAuth endpoint 문자열 — suffix는 URL 유효성과 무관해 non-throwing keychain 경로에서 사용 가능.
    private struct ResolvedOAuthEndpoints {
        var baseAPI: String
        var refreshURL: String
        var clientID: String
        var suffix: String
    }

    private func resolveOAuthEndpoints() -> ResolvedOAuthEndpoints {
        Self.resolveOAuthEndpoints(environment: environment)
    }

    private static func resolveOAuthEndpoints(environment: EnvironmentReading) -> ResolvedOAuthEndpoints {
        var baseAPI = Self.prodBaseAPIURL
        var refreshURL = Self.prodRefreshURL
        var clientID = Self.prodClientID
        var suffix = ""

        let isAntUser = envText(environment, "USER_TYPE") == "ant"
        if isAntUser, envFlag(environment, "USE_LOCAL_OAUTH") {
            let base = (envText(environment, "CLAUDE_LOCAL_OAUTH_API_BASE") ?? "http://localhost:8000").trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-local-oauth"
        } else if isAntUser, envFlag(environment, "USE_STAGING_OAUTH") {
            baseAPI = "https://api-staging.anthropic.com"
            refreshURL = "https://platform.staging.ant.dev/v1/oauth/token"
            clientID = Self.nonProdClientID
            suffix = "-staging-oauth"
        }

        if let custom = envText(environment, "CLAUDE_CODE_CUSTOM_OAUTH_URL") {
            let base = custom.trimmingTrailingSlashes
            baseAPI = base
            refreshURL = "\(base)/v1/oauth/token"
            suffix = "-custom-oauth"
        }
        if let override = envText(environment, "CLAUDE_CODE_OAUTH_CLIENT_ID") {
            clientID = override
        }

        return ResolvedOAuthEndpoints(baseAPI: baseAPI, refreshURL: refreshURL, clientID: clientID, suffix: suffix)
    }

    /// 이 환경의 Claude Code가 쓰는 keychain service 이름 — scoped store와 config-dir discovery의
    /// 단일 원천(비프로덕션 OAuth suffix로 인한 probe/refresh 이름 불일치 방지).
    static func baseKeychainServiceName(environment: EnvironmentReading) -> String {
        "\(keychainServicePrefix)\(resolveOAuthEndpoints(environment: environment).suffix)-credentials"
    }

    static func scopedKeychainServiceName(forConfigDirLiteral literal: String, environment: EnvironmentReading) -> String {
        "\(baseKeychainServiceName(environment: environment))-\(hashSuffix(literal))"
    }

    // env 유래 URL은 system-boundary 입력 — 잘못된 값은 loudly 실패. force-unwrap 금지,
    // prod 폴백 금지(오설정 은폐 + 사용자 토큰의 production 전송 위험).
    func oauthConfig() throws -> ClaudeOAuthConfig {
        let endpoints = resolveOAuthEndpoints()
        return ClaudeOAuthConfig(
            usageURL: try validatedOAuthURL("\(endpoints.baseAPI)/api/oauth/usage"),
            refreshURL: try validatedOAuthURL(endpoints.refreshURL),
            clientID: endpoints.clientID
        )
    }

    /// 원격 OAuth는 HTTPS 필수. HTTP는 명시적 loopback 개발 주소만 허용.
    private func validatedOAuthURL(_ value: String) throws -> URL {
        guard let url = URL(string: value) else {
            throw ClaudeAuthError.invalidOAuthURL
        }
        let scheme = url.scheme?.lowercased()
        let host = url.host?.lowercased() ?? ""
        let isLoopback = ["localhost", "127.0.0.1", "::1"].contains(host)
        guard !host.isEmpty, scheme == "https" || (scheme == "http" && isLoopback) else {
            throw ClaudeAuthError.invalidOAuthURL
        }
        return url
    }

    private func sharedLoginRoute() throws -> ClaudeSharedLoginRoute {
        try ClaudeSharedLoginRoute.resolve(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser, files: files, environment: environment
        )
    }

    func keychainServiceCandidates(sharedRoute: ClaudeSharedLoginRoute? = nil) -> [String] {
        // suffix만 필요(실패 없음) — throwing URL 경로와 분리해 커스텀 OAuth URL 오류에도 credential 로딩 유지.
        let base = "\(Self.keychainServicePrefix)\(resolveOAuthEndpoints().suffix)-credentials"
        switch scope {
        case .configDir(_, let keychainLiteral):
            // 이 카드의 항목만 — 기본 service는 다른 계정의 로그인.
            return ["\(base)-\(hashSuffix(keychainLiteral))"]
        case .standard:
            guard let route = try? sharedRoute ?? sharedLoginRoute() else { return [] }
            if case .legacy = route { return [route.service(environment: environment)] }
            if let configDir = claudeHomeOverride() {
                return ["\(base)-\(hashSuffix(configDir))", base]
            }
            return [route.service(environment: environment)]
        case .accountSnapshot:
            return []
        }
    }

    static func parseCredentials(_ text: String) -> ClaudeCredentialsFile? {
        ProviderParse.decodeJSONWithHexFallback(text, as: ClaudeCredentialsFile.self)
    }

    /// keychain-우선 고정 순서의 credential 후보. keychain이 macOS의 source of truth — stale 파일이
    /// 늦은 만료 시각만으로 keychain을 앞서면 안 됨(#738); 파일 폴백은 refresh 루프 담당(#687).
    private func orderedStoredCandidates(sharedRoute: ClaudeSharedLoginRoute?) -> [ClaudeCredentialState] {
        var candidates: [ClaudeCredentialState] = []
        if let keychain = loadKeychainCredentials(sharedRoute: sharedRoute) { candidates.append(keychain) }
        if let file = loadFileCredentials() { candidates.append(file) }

        if candidates.count > 1 {
            let labels = candidates.map(\.source.label).joined(separator: ", ")
            AppLog.debug(LogTag.auth("claude"), "credential candidates (keychain first): \(labels)")
        } else if let only = candidates.first {
            AppLog.debug(LogTag.auth("claude"), "credential source: \(only.source.label)")
        }
        return candidates
    }

    private func loadFileCredentials() -> ClaudeCredentialState? {
        let path = credentialsPath()
        guard files.exists(path),
              let text = try? files.readText(path),
              let parsed = Self.parseCredentials(text),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(oauth: oauth, source: .file, sourceText: text, inferenceOnly: false)
    }

    private func loadKeychainCredentials(sharedRoute: ClaudeSharedLoginRoute?) -> ClaudeCredentialState? {
        // Keychain service 이름에는 사용자별 경로 해시가 포함되므로 조회 결과와 출처만 기록.
        for service in keychainServiceCandidates(sharedRoute: sharedRoute) {
            if scope == .standard, claudeHomeOverride() != nil,
               service == Self.baseKeychainServiceName(environment: environment) {
                guard let identity = usageAccountIdentity(),
                      usageAccountIdentity(useDefaultHome: true) == identity else { continue }
            }
            if let state = credentialState(
                from: try? keychain.readGenericPasswordForCurrentUser(service: service),
                source: .keychainCurrentUser(service: service)
            ) {
                return state
            }
            if let state = credentialState(
                from: try? keychain.readGenericPassword(service: service),
                source: .keychainLegacy(service: service)
            ) {
                return state
            }
        }
        AppLog.debug(LogTag.auth("claude"), "no usable Keychain credential")
        return nil
    }

    private func loadAccountSnapshot(profileID: String, allowInteraction: Bool = false) throws -> ClaudeCredentialState? {
        guard let entry = try AccountCredentialVault(keychain: keychain).load(
            family: "claude",
            profileID: profileID,
            allowInteraction: allowInteraction
        ),
        let parsed = Self.parseCredentials(entry.credential),
        let oauth = parsed.claudeAiOauth,
        oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        return ClaudeCredentialState(
            oauth: oauth,
            source: .accountSnapshot(profileID: profileID),
            sourceText: entry.credential,
            inferenceOnly: false,
            accountIdentityKey: AccountCredentialSwitcher().identity(of: entry, family: "claude")?.identityKey
        )
    }

    private func usageAccountIdentity(useDefaultHome: Bool = false, sharedRoute: ClaudeSharedLoginRoute? = nil)
        -> String?
    {
        var observer = DefaultAccountObserver(
            environment: environment, files: files, keychain: keychain, pinsClaudeSharedHome: pinsSharedHome
        )
        var route = sharedRoute
        if useDefaultHome {
            observer.environment = ClaudeUsageIdentityEnvironment(base: environment, configDir: nil)
            observer.pinsClaudeSharedHome = false
            route = .plain
        } else if case .configDir(let path, _) = scope {
            observer.environment = ClaudeUsageIdentityEnvironment(base: environment, configDir: path)
            observer.pinsClaudeSharedHome = false
            route = .plain
        }
        guard case .resolved(let key, _, _) = observer.observeClaude(sharedRoute: route)
        else { return nil }
        return key
    }

    /// 사용할 수 있는 OAuth 토큰이 있는 Keychain 항목만 인증 후보로 채택.
    private func credentialState(
        from value: String?,
        source: ClaudeCredentialState.Source
    ) -> ClaudeCredentialState? {
        guard let value,
              let parsed = Self.parseCredentials(value),
              let oauth = parsed.claudeAiOauth,
              oauth.accessToken?.isEmpty == false
        else {
            return nil
        }
        AppLog.debug(LogTag.auth("claude"), "read Keychain credential source=\(source.label)")
        return ClaudeCredentialState(oauth: oauth, source: source, sourceText: value, inferenceOnly: false)
    }

    private func credentialsPath() -> String {
        if case .configDir(let path, _) = scope {
            return "\(path)/\(Self.credentialFileName)"
        }
        return "\(claudeHomeOverride() ?? Self.defaultClaudeHome)/\(Self.credentialFileName)"
    }

    private func envText(_ name: String) -> String? {
        Self.envText(environment, name)
    }

    private static func envText(_ environment: EnvironmentReading, _ name: String) -> String? {
        guard let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty
        else {
            return nil
        }
        return value
    }

    private func envFlag(_ name: String) -> Bool {
        Self.envFlag(environment, name)
    }

    private static func envFlag(_ environment: EnvironmentReading, _ name: String) -> Bool {
        guard let value = envText(environment, name)?.lowercased() else { return false }
        return !["0", "false", "no", "off"].contains(value)
    }

    private func hashSuffix(_ value: String) -> String {
        Self.hashSuffix(value)
    }

    private static func hashSuffix(_ value: String) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(8))
    }
}
