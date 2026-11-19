import Foundation

/// 추가 Claude 로그인 경로 탐색. 계정 신원과 자격 증명 흔적이 모두 있는 경로만 채택.
/// 인증 파일이나 Keychain 메타데이터를 확인하며 Keychain 비밀값은 읽지 않음.
struct ClaudeConfigDirDiscovery {
    /// 승인된 커스텀 config-dir 로그인 1건 — 카드화/기존 계정 귀속 판단은 assembly 소관.
    struct Finding: Equatable, Sendable {
        var identityKey: String
        var label: String?
        /// 확장된 config-dir 경로 — 카드의 credential home이자 spend 로그 root.
        var anchorPath: String
        /// keychain 항목 이름을 만드는 해시 원문 문자열(`ClaudeCredentialScope` 참고).
        var keychainLiteral: String
    }

    struct Result: Sendable {
        var findings: [Finding] = []
        /// 진단 로그에는 탐색 결과와 자격 증명 출처만 기록.
        var notes: [String] = []
    }

    var environment: EnvironmentReading
    var files: TextFileAccessing
    var keychain: KeychainAccessing
    var homeDirectory: @Sendable () -> URL
    var listSubdirectories: @Sendable (URL) -> [URL]
    /// 탐색 시간 제한. 초과 시 확인한 결과만 반환.
    var timeBudget: TimeInterval
    var now: @Sendable () -> Date

    init(
        environment: EnvironmentReading = ProcessEnvironmentReader(),
        files: TextFileAccessing = LocalTextFileAccessor(),
        keychain: KeychainAccessing = SecurityKeychainAccessor(),
        homeDirectory: @escaping @Sendable () -> URL = { FileManager.default.homeDirectoryForCurrentUser },
        listSubdirectories: @escaping @Sendable (URL) -> [URL] = Self.filesystemSubdirectories,
        timeBudget: TimeInterval = 0.4,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.environment = environment
        self.files = files
        self.keychain = keychain
        self.homeDirectory = homeDirectory
        self.listSubdirectories = listSubdirectories
        self.timeBudget = timeBudget
        self.now = now
    }

    func run(additionalDirectories: [URL] = [], observedDefaultHome: String? = nil) -> Result {
        let started = now()
        var result = Result()
        let excluded = Set(defaultClaudeConfigDirs(observedDefaultHome: observedDefaultHome).map(canonical))
        var visited: Set<String> = []

        // 등록된 home은 정확한 계정 handle — bounded ambient 스캔보다 우선, launch 예산 안에서 카드 바인딩 필수.
        for candidate in additionalDirectories + candidateDirectories() {
            if now().timeIntervalSince(started) > timeBudget {
                result.notes.append("claude config-dir scan hit its \(Int(timeBudget * 1000))ms budget; finishing with partial results")
                break
            }
            let canonicalPath = canonical(candidate.path)
            guard visited.insert(canonicalPath).inserted,
                  !excluded.contains(canonicalPath) else { continue }
            if let finding = claudeCandidate(at: candidate, notes: &result.notes) {
                result.findings.append(finding)
            }
        }
        return result
    }

    /// 지정된 config dir 1개의 identity + credential 조회 — 관리 profile sign-in probe.
    /// launch 스캔과 동일한 엄격 검증(후보 gating·시간 예산만 제외); 기본 home 경로는
    /// `DefaultAccountObserver`로 라우팅 — 여기서는 항상 dir 내부의 state 파일 조회.
    func inspect(configDir url: URL) -> Finding? {
        var notes: [String] = []
        let finding = claudeCandidate(at: url, notes: &notes)
        for note in notes {
            AppLog.debug(.config, note)
        }
        return finding
    }

    // MARK: - Candidates

    /// `~`의 dot-dir + `~/.config` 하위 dir, 안정적 경로 순서.
    private func candidateDirectories() -> [URL] {
        let home = homeDirectory()
        var candidates = listSubdirectories(home).filter { $0.lastPathComponent.hasPrefix(".") }
        candidates += listSubdirectories(home.appendingPathComponent(".config"))
        return candidates.sorted { $0.path < $1.path }
    }

    private static func filesystemSubdirectories(of url: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )) ?? []
        return contents.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }
    }

    /// 계정 정보와 자격 증명을 모두 확인한 디렉터리만 채택. 계정 파일이 있는 후보만 진단에 기록.
    private func claudeCandidate(at url: URL, notes: inout [String]) -> Finding? {
        guard let identityText = try? files.readTextIfPresent(url.path + "/.claude.json") else {
            return nil
        }
        guard let parsed = try? JSONDecoder().decode(
                  DefaultAccountObserver.ClaudeStateFile.self, from: Data(identityText.utf8)
              ),
              let account = parsed.oauthAccount,
              let key = DefaultAccountObserver.claudeIdentityKey(account)
        else {
            notes.append("claude config discovery: skipped candidate without account identity")
            return nil
        }

        // credential 형태: dir의 `.credentials.json` 또는 계산된 keychain 항목 —
        // 가능한 경로 표기 전부를 attributes-only로 probe(secret·prompt 없음).
        let fileBacked = (try? files.readTextIfPresent(url.path + "/.credentials.json"))
            .flatMap { $0 }
            .flatMap { ClaudeAuthStore.parseCredentials($0) }?
            .claudeAiOauth?.accessToken?.nilIfEmpty != nil

        var matchedLiteral: String?
        let literals = keychainLiterals(for: url)
        for literal in literals {
            let service = ClaudeAuthStore.scopedKeychainServiceName(
                forConfigDirLiteral: literal,
                environment: environment
            )
            if keychain.genericPasswordExists(service: service) == true {
                matchedLiteral = literal
                break
            }
        }
        guard fileBacked || matchedLiteral != nil else {
            notes.append("claude config discovery: skipped candidate without file or Keychain credentials")
            return nil
        }

        notes.append("claude config discovery: accepted source=\(fileBacked ? "file" : "keychain")")
        return Finding(
            identityKey: key,
            label: DefaultAccountObserver.claudeIdentityLabel(account),
            anchorPath: url.path,
            keychainLiteral: matchedLiteral ?? url.path
        )
    }

    /// Claude Code가 해시했을 수 있는 이 dir의 경로 표기 전부 — 원본·symlink 해소·`~` 축약 조합.
    private func keychainLiterals(for url: URL) -> [String] {
        let home = homeDirectory()
        let homePaths = Array(Set([home.path, home.resolvingSymlinksInPath().path]))
        var candidates = [url.path, url.resolvingSymlinksInPath().path]
        for candidate in candidates {
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                let suffix = candidate.dropFirst(homePath.count)
                candidates += homePaths.map { $0 + suffix }
            }
        }
        var literals: [String] = []
        for candidate in candidates {
            literals.append(candidate)
            for homePath in homePaths where candidate.hasPrefix(homePath + "/") {
                literals.append("~" + candidate.dropFirst(homePath.count))
            }
        }
        var seen = Set<String>()
        return literals.filter { seen.insert($0).inserted }
    }

    // MARK: - Default homes (the exclusion set)

    /// 셸 함수가 환경 변수를 덮어쓰면 관찰한 기본 홈만 추가 계정 탐색에서 제외.
    private func defaultClaudeConfigDirs(observedDefaultHome: String?) -> [String] {
        if let raw = environment.value(for: "CLAUDE_CONFIG_DIR")?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return [observedDefaultHome ?? expandTilde(raw)]
        }
        let home = homeDirectory()
        let xdg = environment.value(for: "XDG_CONFIG_HOME")?.nilIfEmpty.map(expandTilde)
            ?? home.appendingPathComponent(".config").path
        return [xdg + "/claude", home.appendingPathComponent(".claude").path]
    }

    // MARK: - Path helpers

    private func expandTilde(_ path: String) -> String {
        guard path == "~" || path.hasPrefix("~/") else { return path }
        return homeDirectory().path + String(path.dropFirst(1))
    }

    private func canonical(_ path: String) -> String {
        URL(fileURLWithPath: expandTilde(path)).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
