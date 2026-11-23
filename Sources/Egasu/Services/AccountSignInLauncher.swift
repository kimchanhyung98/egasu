import Darwin
import Foundation
import os

/// family의 공식 로그인 CLI(`claude auth login`, `codex login`)를 한 home(Sign-In Workspace 또는 첫 계정의 Shared Runtime Home)에 고정해 실행.
/// child는 parent 환경에서 모든 provider auth override 제거 — export된 API 키·token의 로그인 계정 위장 금지. 공식 로그인 전용 — workspace의 일반 세션 시작 금지.
struct AccountSignInLauncher: Sendable {
    var homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    /// 존재 시 저장된 subscription 로그인을 override하는 Claude 변수 — 로그인 child에서만 제거, parent shell 불변.
    static let claudeAuthEnvironmentRemovals = [
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_OAUTH_REFRESH_TOKEN",
        "CLAUDE_CODE_OAUTH_SCOPES",
    ]

    /// Codex 환경 credential은 persisted ChatGPT 로그인보다 우선 — 같은 이유로 로그인 child에서 제거.
    static let codexAuthEnvironmentRemovals = [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
    ]

    /// Codex 로그인의 파일 `auth.json` 저장 강제 — keyring credential은 `CODEX_HOME` 스코프 계약이 없어 workspace 보유 계정을 모호하게 만듦.
    static let codexFileCredentialStoreArguments = [
        "-c",
        "cli_auth_credentials_store=\"file\"",
    ]

    static func loginArguments(family: String) -> [String] {
        switch family {
        case "claude": ["auth", "login"]
        case "codex": codexFileCredentialStoreArguments + ["login"]
        default: []
        }
    }

    /// 로그인 자식 프로세스 환경 — 인증 덮어쓰기 변수 제거, home이 nil이면 기본 홈 사용.
    static func loginEnvironment(
        family: String,
        home: String?,
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = base
        switch family {
        case "claude":
            for key in claudeAuthEnvironmentRemovals { environment.removeValue(forKey: key) }
            environment["CLAUDE_CONFIG_DIR"] = home
        case "codex":
            for key in codexAuthEnvironmentRemovals { environment.removeValue(forKey: key) }
            environment["CODEX_HOME"] = home
        default:
            break
        }
        return environment
    }

    /// 공식 로그인 spawn 후 exit status 반환 — 취소 시 child 종료.
    /// 출력 폐기 — 로그인은 브라우저로 진행, stdout의 계정 상세가 로그에 유입 금지.
    /// `usesLoginShellPATH`: Finder/Dock launch는 launchd PATH만 상속(`~/.local/bin`·Homebrew·npm prefix 부재) — 실행 파일 해석 전 login-shell PATH 적용.
    func runLogin(
        family: String,
        home: String?,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        usesLoginShellPATH: Bool = true
    ) async throws -> Int32 {
        var loginHome = home
        if family == "claude", home == nil {
            loginHome = try ClaudeSharedLoginRoute.resolve(
                homeDirectory: homeDirectory,
                files: LocalTextFileAccessor(),
                environment: ProcessEnvironmentReader(processEnvironment: baseEnvironment)
            ).configDirectory
        }
        var environment = Self.loginEnvironment(family: family, home: loginHome, base: baseEnvironment)
        if usesLoginShellPATH,
           let shellPATH = LoginShellEnvironment.shared.value(for: "PATH")?.nilIfEmpty {
            environment["PATH"] = shellPATH
        }
        AppLog.debug(.subprocess, "account sign-in launch \(family) login")
        let pid = try StreamingProcessRunner.spawn(
            executable: "/usr/bin/env", arguments: [family] + Self.loginArguments(family: family),
            environment: environment, resetSignalState: true)
        let ownsChild = OSAllocatedUnfairLock(initialState: true)
        let exit = ProcessExitSignal()
        StreamingProcessRunner.startWait(pid: pid, signal: exit) { _ in
            ownsChild.withLock { $0 = false }
        }
        // waitid가 종료를 관측한 뒤 같은 잠금에서 소유권을 해제해야 회수된 PID로 지연 신호가 가지 않음.
        @Sendable func signalChild(_ signal: Int32) {
            ownsChild.withLock { owned in
                if owned, Darwin.kill(pid, signal) != 0, errno != ESRCH {
                    AppLog.error(.subprocess, "Failed to signal login child (errno \(errno))")
                }
            }
        }
        return try await withTaskCancellationHandler {
            let result = await exit.wait()
            if let error = result.waitError { throw StreamingProcessRunnerError.processWaitFailed(code: error) }
            return result.exitCode
        } onCancel: {
            signalChild(SIGTERM)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 1) { signalChild(SIGKILL) }
        }
    }
}
