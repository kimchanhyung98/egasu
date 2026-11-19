import Foundation

/// OpenRouter와 Z.ai에서 설정 파일과 환경 변수의 API 키를 읽고 관리하는 공통 저장소.
struct UserAPIKeyStore: Sendable {
    /// 각 프로바이더의 사용자 안내에 필요한 저장·삭제 실패 유형.
    enum Failure { case missingKey, saveFailed, deleteFailed }

    private struct UnreadableKey: LocalizedError, UserPresentableError, CategorizedError {
        let presentationMessage = LocalizedMessage(
            "Couldn't read the saved API key. Check the configuration file permissions.")
        let errorCategory = ErrorCategory.credentialAccess
        var errorDescription: String? { presentationMessage.key }
    }

    let providerID: String
    let configPaths: [String]
    let environmentNames: [String]
    var files: TextFileAccessing
    var environment: EnvironmentReading
    let makeError: @Sendable (Failure) -> Error

    /// 설정 파일을 먼저 확인하고, 읽기 실패는 대체할 환경 변수 키도 없을 때 전달.
    func loadKey() throws -> String? {
        let config = keyFromConfigFile()
        if let key = config.key ?? keyFromEnvironment() { return key }
        if let readError = config.readError {
            AppDiagnostics.record(
                .credentialRead, result: .failure, category: .credentialAccess, providerID: providerID,
                error: readError, localContext: "API key config read")
            throw UnreadableKey()
        }
        return nil
    }

    /// 저장 파일과 환경 변수에 키가 있는지 확인해 편집 화면의 상태 결정.
    func keyStatus() -> APIKeyStatus {
        let config = keyFromConfigFile()
        let hasConfig = config.key != nil
        let hasEnv = keyFromEnvironment() != nil
        switch (hasConfig, hasEnv) {
        case (true, true): return .overrideActive
        case (true, false): return .saved
        case (false, true): return .fromEnvironment
        case (false, false): return config.readError == nil ? .notSet : .unreadable
        }
    }

    /// 저장된 키가 환경 변수보다 우선하므로 첫 설정 파일에만 기록.
    func saveKey(_ key: String) throws {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw makeError(.missingKey) }
        do {
            let data = try JSONSerialization.data(withJSONObject: ["apiKey": trimmed], options: [.sortedKeys])
            try files.writeText(configPaths[0], String(decoding: data, as: UTF8.self))
        } catch {
            recordFileFailure(.credentialSave, error: error, context: "API key config write")
            throw makeError(.saveFailed)
        }
        AppDiagnostics.record(.credentialSave, result: .success, providerID: providerID)
    }

    /// 키를 확인한 파일만 삭제. 읽을 수 없는 파일이 있으면 변경 전에 중단.
    func deleteKey() throws {
        do {
            let candidates = try configPaths.filter { path in
                guard let text = try files.readTextIfPresent(path) else { return false }
                return Self.keyFromConfigText(text) != nil
            }
            guard !candidates.isEmpty else { return }
            for path in candidates {
                try files.remove(path)
            }
        } catch {
            recordFileFailure(.credentialRemove, error: error, context: "API key config removal")
            throw makeError(.deleteFailed)
        }
        AppDiagnostics.record(.credentialRemove, result: .success, providerID: providerID)
    }

    private func recordFileFailure(_ operation: DiagnosticOperation, error: Error, context: String) {
        let category: ErrorCategory
        if let posix = error as? POSIXError {
            category = [.EACCES, .EPERM].contains(posix.code) ? .permission : .storage
        } else {
            category = ErrorCategory.classify(error)
        }
        AppDiagnostics.record(
            operation, result: .failure, category: category, providerID: providerID, error: error, localContext: context
        )
    }

    private func keyFromEnvironment() -> String? {
        for name in environmentNames {
            if let value = environment.value(for: name)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private func keyFromConfigFile() -> (key: String?, readError: (any Error)?) {
        var readError: (any Error)?
        for path in configPaths {
            do {
                if let text = try files.readTextIfPresent(path), let key = Self.keyFromConfigText(text) {
                    return (key, nil)
                }
            } catch {
                if readError == nil { readError = error }
            }
        }
        return (nil, readError)
    }

    /// `apiKey` / `api_key` / `key`를 가진 JSON 객체 또는 key만 담긴 plain-text 파일 허용.
    static func keyFromConfigText(_ text: String) -> String? {
        if let data = text.data(using: .utf8),
           let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            for field in ["apiKey", "api_key", "key"] {
                if let value = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !value.isEmpty {
                    return value
                }
            }
            return nil
        }

        // 앞뒤 공백을 제거한 텍스트를 키 원문으로 해석. 빈 문자열이나 여는 중괄호가 있으면 거부.
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.contains("{") ? nil : trimmed
    }
}
