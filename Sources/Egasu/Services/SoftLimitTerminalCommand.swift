/// 번들에 포함된 검사 명령과 확인된 프로바이더의 기본 CLI 실행 명령.
struct SoftLimitTerminalCommand {
    let check: String
    let launch: String?

    init?(helperPath: String, cardID: String) {
        // 비활성 계정 카드는 egasu 전용 저장본을 사용하므로 터미널 로그인에 연결할 수 없음.
        guard !ProviderAccountID.isAccountCard(cardID) else { return nil }
        let helper = CommandLineToolInstaller.shellQuote(helperPath)
        let card = CommandLineToolInstaller.shellQuote(cardID)
        // 터미널의 테스트 설정 재정의 대신 명령을 복사한 앱의 설정 사용.
        let env = "command /usr/bin/env"
        let environment = "\(env) -u EGASU_DEFAULTS_SUITE -u OPENUSAGE_DEFAULTS_SUITE"
        let check = "\(environment) \(helper) soft-limit check \(card)"
        self.check = check
        // 셸 별칭과 함수 대신 PATH에서 실행 파일을 찾아 같은 인증 환경으로 시작.
        switch cardID {
        case "codex":
            let fileStore = AccountSignInLauncher.codexFileCredentialStoreArguments
                .map(CommandLineToolInstaller.shellQuote).joined(separator: " ")
            launch = "\(check) && \(env) \(card) \(fileStore)"
        case "claude", "kimi": launch = "\(check) && \(env) \(card)"
        default: launch = nil
        }
    }
}
