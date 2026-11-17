import Foundation
import os

enum UsageTimerCLIConfiguration: Sendable {
    case claude(accessToken: String)
    case kimi(accessToken: String, baseURL: String = KimiAuthStore.defaultBaseURL)
    case antigravity(model: String)
    case zai(apiKey: String)

    var executable: String {
        switch self {
        case .claude, .zai: "claude"
        case .kimi: "kimi"
        case .antigravity: "agy"
        }
    }
}

@MainActor
protocol UsageTimerCLIExecuting {
    func execute(
        _ configuration: UsageTimerCLIConfiguration,
        canLaunch: @escaping @MainActor () async -> Bool
    ) async -> UsageTimerExecutionResult
}

/// 공식 CLI에 도구 없는 짧은 요청 전달. 응답 본문·자격 증명은 로그에 기록하지 않음.
@MainActor
final class UsageTimerCLIExecutor: UsageTimerCLIExecuting {
    static let prompt = "Reply with OK. Do not use tools."
    private let runner: any StreamingProcessRunning
    private let resolve: @MainActor (String) -> URL?
    private let baseDirectory: URL

    init(
        runner: any StreamingProcessRunning = StreamingProcessRunner(),
        resolve: @escaping @MainActor (String) -> URL? = UsageTimerCLIExecutor.resolveExecutable,
        baseDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        self.runner = runner
        self.resolve = resolve
        self.baseDirectory = baseDirectory
    }

    func execute(
        _ configuration: UsageTimerCLIConfiguration,
        canLaunch: @escaping @MainActor () async -> Bool
    ) async -> UsageTimerExecutionResult {
        guard let executable = resolve(configuration.executable) else {
            return failure("Usage timer requires the provider's current CLI. Install or update it and refresh.")
        }
        let directory = baseDirectory.appendingPathComponent(
            "\(StorageNamespace.current.name).UsageTimer-\(UUID().uuidString)")
        var result: UsageTimerExecutionResult
        let launchState = OSAllocatedUnfairLock(initialState: false)
        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            var request = try makeRequest(configuration, executable: executable, directory: directory)
            var helpRequest = request
            helpRequest.arguments = ["--help"]
            helpRequest.standardInput = Data()
            helpRequest.timeout = 5
            let help = try await runner.run(helpRequest)
            let helpText = help.output + "\n" + help.standardError
            let required =
                configuration.executable == "kimi"
                ? ["--prompt", "--agent-file", "--output-format"]
                : ["--print", "--output-format", "--model"]
            guard help.exitCode == 0, required.allSatisfy({ helpText.contains($0) }) else {
                throw ExecutorError.unsupportedCLI
            }
            if case .antigravity(let prefix) = configuration {
                var modelRequest = helpRequest
                modelRequest.arguments = ["models"]
                let listing = try await runner.run(modelRequest)
                guard listing.exitCode == 0 else { throw ExecutorError.modelListingFailed }
                guard
                    let model = listing.output.split(whereSeparator: \.isNewline)
                        .compactMap({ $0.split(whereSeparator: \.isWhitespace).first.map(String.init) })
                        .first(where: { model in
                            model.hasPrefix(prefix) && !model.split(separator: "-").contains("argon")
                                && model.allSatisfy {
                                    $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == ".")
                                }
                        }),
                    let index = request.arguments.firstIndex(of: "--model")
                else { throw ExecutorError.modelUnavailable }
                request.arguments[index + 1] = model
            }
            try Task.checkCancellation()
            guard await canLaunch(), !Task.isCancelled else { throw UsageTimerError.accountChanged }
            // 시작 직후 취소·시간 초과도 전송 가능성이 있는 시도로 유지.
            let response = try await runner.run(
                request, onLaunch: { launchState.withLock { $0 = true } }, onOutput: { _ in }
            )
            let completed = response.exitCode == 0 && Self.completed(response.output, configuration: configuration)
            result = UsageTimerExecutionResult(
                launched: true, completed: completed,
                failureDescription: completed
                    ? nil : "Usage timer message did not complete. Check the provider's CLI login and refresh."
            )
        } catch {
            AppDiagnostics.failure(
                .weeklyTimer, error: error,
                localContext: "Usage timer CLI failed")
            let message =
                switch error {
                case ExecutorError.unsupportedCLI:
                    "Usage timer requires the provider's current CLI. Install or update it and refresh."
                case ExecutorError.modelListingFailed:
                    "Usage timer could not load the CLI model list. Check the CLI login and refresh."
                case ExecutorError.modelUnavailable: "Usage timer could not select the requested model."
                case let error as UsageTimerError: error.errorDescription!
                default: "Usage timer CLI execution failed. Refresh to try again."
                }
            result = failure(message, launched: launchState.withLock { $0 })
        }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            AppDiagnostics.failure(.weeklyTimer, error: error, localContext: "Usage timer workspace cleanup failed")
            result.failureDescription = "Usage timer temporary files could not be removed."
            result.verificationCanClearFailure = false
        }
        return result
    }

    func makeRequest(
        _ configuration: UsageTimerCLIConfiguration, executable: URL, directory: URL
    ) throws -> StreamingProcessRequest {
        let path =
            LoginShellEnvironment.shared.value(for: "PATH")
            ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        var environment = ["PATH": path, "LANG": "en_US.UTF-8", "TERM": "dumb", "NO_COLOR": "1"]
        var arguments: [String]
        switch configuration {
        case .claude(let accessToken):
            environment["HOME"] = directory.path
            environment["CLAUDE_CONFIG_DIR"] = directory.path
            environment["CLAUDE_CODE_OAUTH_TOKEN"] = accessToken
            environment["CLAUDE_CODE_MAX_OUTPUT_TOKENS"] = "32"
            arguments = Self.claudeArguments + ["--model", "haiku"]
        case .zai(let apiKey):
            environment["HOME"] = directory.path
            environment["ANTHROPIC_API_KEY"] = apiKey
            environment["ANTHROPIC_BASE_URL"] = "https://api.z.ai/api/anthropic"
            arguments = Self.claudeArguments + ["--bare", "--model", "glm-4.7"]
        case .antigravity(let model):
            environment["HOME"] = directory.path
            // CLI 설정·기록은 격리하고 기존 macOS 로그인 Keychain만 참조.
            let library = directory.appendingPathComponent("Library")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(
                at: library.appendingPathComponent("Keychains"),
                withDestinationURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Keychains")
            )
            let settings = directory.appendingPathComponent(".gemini/antigravity-cli/settings.json")
            try FileManager.default.createDirectory(
                at: settings.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(#"{"toolPermission":"strict","historySize":0,"disableSlashCommands":true}"#.utf8).write(
                to: settings)
            arguments = ["--print", Self.prompt, "--output-format", "json", "--model", model]
        case .kimi(let token, let baseURL):
            environment["HOME"] = directory.path
            environment["KIMI_CODE_HOME"] = directory.path
            environment["EGASU_KIMI_TOKEN"] = token
            environment["KIMI_DISABLE_TELEMETRY"] = "1"
            let config = """
                default_model = "timer"
                auto_session_title = false
                builtin_product_skills = false
                merge_all_available_skills = false
                [providers.timer]
                type = "kimi"
                base_url = "\(baseURL)"
                api_key_env = "EGASU_KIMI_TOKEN"
                [models.timer]
                provider = "timer"
                model = "kimi-for-coding"
                max_context_size = 262144
                [loop_control]
                max_attempts_per_step = 1
                [task]
                print_background_mode = "exit"
                [[permission.rules]]
                decision = "deny"
                pattern = "*"
                """
            try Data(config.utf8).write(to: directory.appendingPathComponent("config.toml"))
            let agent = directory.appendingPathComponent("timer.md")
            try Data(
                "---\nname: timer\ndescription: Reply once without tools\ntools: []\n---\nReply with OK. Do not use tools.\n"
                    .utf8
            ).write(to: agent)
            arguments = [
                "--prompt", Self.prompt, "--agent-file", agent.path, "--output-format", "stream-json",
                "--skills-dir", directory.path
            ]
        }
        return StreamingProcessRequest(
            executableURL: executable, arguments: arguments, environment: environment,
            currentDirectoryURL: directory, timeout: 60, outputLimit: 32_768,
            captureStandardErrorSeparately: true
        )
    }

    private static let claudeArguments = [
        "--print", prompt, "--output-format", "json", "--tools", "", "--strict-mcp-config",
        "--mcp-config", #"{"mcpServers":{}}"#, "--setting-sources", "",
        "--settings", #"{"disableAllHooks":true,"autoMemoryEnabled":false}"#,
        "--disable-slash-commands", "--no-session-persistence"
    ]

    private static func completed(_ output: String, configuration: UsageTimerCLIConfiguration) -> Bool {
        switch configuration {
        case .claude, .zai:
            guard let object = ProviderParse.jsonObject(Data(output.utf8)) else { return false }
            return object["type"] as? String == "result" && object["is_error"] as? Bool == false
        case .antigravity:
            return ProviderParse.jsonObject(Data(output.utf8))?["status"] as? String == "SUCCESS"
        case .kimi:
            // CLI 정상 종료와 실제 assistant 출력 모두 필요. 서버 타이머는 별도 재조회로 확인.
            return output.split(separator: "\n").contains { line in
                guard let object = ProviderParse.jsonObject(Data(line.utf8)) else { return false }
                return object["role"] as? String == "assistant" || object["type"] as? String == "assistant"
            }
        }
    }

    private func failure(_ message: String, launched: Bool = false) -> UsageTimerExecutionResult {
        .init(launched: launched, completed: false, failureDescription: message)
    }

    private static func resolveExecutable(_ name: String) -> URL? {
        let path =
            LoginShellEnvironment.shared.value(for: "PATH")
            ?? ProcessInfo.processInfo.environment["PATH"] ?? "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        return path.split(separator: ":").filter { $0.hasPrefix("/") }.map {
            URL(fileURLWithPath: String($0)).appendingPathComponent(name)
        }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private enum ExecutorError: Error { case unsupportedCLI, modelListingFailed, modelUnavailable }
}
