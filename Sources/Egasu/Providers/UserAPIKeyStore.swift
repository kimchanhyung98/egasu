import Foundation

/// OpenRouter와 Z.ai에서 설정 파일과 환경 변수의 API 키를 읽고 관리하는 공통 저장소.
struct UserAPIKeyStore: Sendable {
    /// 각 프로바이더의 사용자 안내에 필요한 저장·삭제 실패 유형.
    enum Failure { case missingKey, saveFailed, deleteFailed }

    static let unreadableKeyMessage = LocalizedMessage(
        "Couldn't read the saved API key. Check the configuration file permissions.")
    private static let keyFields = ["apiKey", "api_key", "key"]

    private struct UnreadableKey: LocalizedError, UserPresentableError, CategorizedError {
        let presentationMessage = UserAPIKeyStore.unreadableKeyMessage
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
            let path = configPaths[0]
            var fields = try readConfigText(path).flatMap { Self.configValue($0) as? [String: Any] } ?? [:]
            for field in Self.keyFields where fields[field] is String {
                fields.removeValue(forKey: field)
            }
            fields["apiKey"] = trimmed
            let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
            try files.writeText(path, String(decoding: data, as: UTF8.self))
        } catch {
            recordFileFailure(.credentialSave, error: error, context: "API key config write")
            throw makeError(.saveFailed)
        }
        AppDiagnostics.record(.credentialSave, result: .success, providerID: providerID)
    }

    /// 모든 경로를 확인한 뒤 대체 키부터 제거. JSON에서 인증 외 필드 보존.
    func deleteKey() throws {
        do {
            let candidates = try configPaths.reversed().compactMap {
                path -> (path: String, before: String, after: String?)? in
                guard let text = try readConfigText(path), Self.keyFromConfigText(text) != nil else { return nil }
                var remaining = Self.configValue(text) as? [String: Any] ?? [:]
                for field in Self.keyFields where remaining[field] is String {
                    remaining.removeValue(forKey: field)
                }
                let replacement =
                    remaining.isEmpty
                    ? nil : try JSONSerialization.data(withJSONObject: remaining, options: [.sortedKeys])
                return (path, text, replacement.map { String(decoding: $0, as: UTF8.self) })
            }
            guard !candidates.isEmpty else { return }
            for candidate in candidates {
                guard try readConfigText(candidate.path) == candidate.before else {
                    throw CocoaError(.fileWriteUnknown)
                }
                if let text = candidate.after {
                    try files.writeText(candidate.path, text)
                } else {
                    try files.remove(candidate.path)
                }
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
                if let text = try readConfigText(path), let key = Self.keyFromConfigText(text) {
                    return (key, nil)
                }
            } catch {
                if readError == nil { readError = error }
            }
        }
        return (nil, readError)
    }

    private func readConfigText(_ path: String) throws -> String? {
        guard let data = try files.readDataIfPresent(path) else { return nil }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return text
    }

    private static func configValue(_ text: String) -> Any? {
        try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// JSON 객체 또는 공백 없는 한 개의 plain-text 키 지원.
    static func keyFromConfigText(_ text: String) -> String? {
        if let value = configValue(text) {
            guard let object = value as? [String: Any] else { return nil }
            for field in keyFields {
                if let value = (object[field] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                    !value.isEmpty
                {
                    return value
                }
            }
            return nil
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("["), !trimmed.contains("{"),
            trimmed.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
        else { return nil }
        return trimmed
    }
}
