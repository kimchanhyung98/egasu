import CryptoKit
import Foundation

struct QwenCloudCLI: Sendable {
    var runner: any StreamingProcessRunning = StreamingProcessRunner()
    var environment: @Sendable () -> [String: String] = {
        let process = ProcessInfo.processInfo.environment
        let shell = LoginShellEnvironment.shared.environmentSnapshot() ?? [:]
        let keys = [
            "HOME", "USER", "TMPDIR", "LANG", "LC_ALL", "QWENCLOUD_CONFIG_DIR", "QWENCLOUD_KEYRING",
            "HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY", "http_proxy", "https_proxy",
            "all_proxy", "no_proxy", "NODE_EXTRA_CA_CERTS"
        ]
        var result = process.merging(shell) { current, _ in current }.filter { keys.contains($0.key) }
        result["PATH"] = [process["PATH"], shell["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"]
            .compactMap { $0 }.joined(separator: ":")
        return result
    }
    var hasKeychainItem: @Sendable () -> Bool? = {
        SecurityKeychainAccessor().genericPasswordExists(service: "qwencloud-cli", account: "cli_credentials")
    }

    struct Login {
        let request: StreamingProcessRequest
        let credentialPresent: Bool?
        let identityKey: String?
    }

    func login() throws -> Login {
        var env = environment()
        let path = (env["PATH"] ?? "").split(separator: ":").filter { $0.hasPrefix("/") }
        env["PATH"] = path.joined(separator: ":")
        guard
            let executable = path.lazy.map({ URL(fileURLWithPath: String($0)).appendingPathComponent("qwencloud") })
                .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw QwenCloudError.cliMissing }
        let home =
            env["HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        env["HOME"] = home.path
        let override = env["QWENCLOUD_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = URL(fileURLWithPath: override?.nilIfEmpty ?? ".qwencloud", isDirectory: true, relativeTo: home)
        let credentialURL = config.appendingPathComponent("credentials")
        let saved = FileManager.default.fileExists(atPath: credentialURL.path)
        var fileRevision: String?
        if saved {
            // CLI는 평문 파일을 조회 중에 이전하고 원본을 삭제하므로 암호화 형식만 허용.
            guard let data = try? Data(contentsOf: credentialURL),
                let envelope = try? JSONDecoder().decode(EncryptedCredentialEnvelope.self, from: data),
                envelope.version == 1
            else { throw QwenCloudError.unsafeCredentialFile }
            fileRevision = Data(SHA256.hash(data: data)).base64EncodedString()
        }
        let mode = env["QWENCLOUD_KEYRING"]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        guard mode != "plaintext" else { throw QwenCloudError.plaintextMode }
        let allowKeychain = !["no", "0", "false", "off"].contains(mode)
        let keychainItem = allowKeychain ? hasKeychainItem() : false
        let present = saved ? true : keychainItem
        // 같은 초에 교체한 Keychain 항목은 메타데이터로 구분할 수 없어 CLI의 새 응답만 사용.
        let identity = keychainItem == false ? fileRevision.map { "qwencloud:" + $0 } : nil
        return Login(
            request: StreamingProcessRequest(
                executableURL: executable,
                arguments: ["subscription", "tokenplan", "status", "--edition", "individual", "--format", "json"],
                environment: env, currentDirectoryURL: home, timeout: 45, outputLimit: 256 * 1024,
                captureStandardErrorSeparately: true
            ),
            credentialPresent: present, identityKey: identity
        )
    }

    func fetch(_ login: Login) async throws -> QwenCloudUsage {
        guard login.credentialPresent != false else { throw QwenCloudError.notLoggedIn }
        let result: StreamingProcessResult
        do {
            result = try await runner.run(login.request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw QwenCloudError.commandFailed
        }
        switch result.exitCode {
        case 0: return try QwenCloudUsage.parse(Data(result.output.utf8))
        case 2: throw QwenCloudError.notLoggedIn
        case 3: throw QwenCloudError.network
        default: throw QwenCloudError.commandFailed
        }
    }
}

private struct EncryptedCredentialEnvelope: Decodable {
    let version: Int
    let salt: String
    let nonce: String
    let ciphertext: String
}
