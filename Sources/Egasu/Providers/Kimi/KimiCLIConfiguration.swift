import CryptoKit
import Foundation
import TOMLDecoder

struct KimiService: Sendable, Equatable {
    let baseURL: String
    let oauthHost: String

    static let standard = KimiService(
        baseURL: "https://api.kimi.com/coding/v1",
        oauthHost: "https://auth.kimi.com"
    )

    var usageURL: URL {
        var components = URLComponents(string: baseURL)!
        components.path = "/coding/v1/usages"
        return components.url!
    }

    var refreshURL: URL {
        URL(string: oauthHost + "/api/oauth/token")!
    }

    var credentialKey: String {
        guard self != .standard else { return "oauth/kimi-code" }
        // CLI의 JSON 키 순서와 비이스케이프 슬래시 유지.
        let input = #"{"oauthHost":"\#(oauthHost)","baseUrl":"\#(baseURL)"}"#
        let digest = SHA256.hash(data: Data(input.utf8))
            .map { String(format: "%02x", $0) }.joined()
        return "oauth/kimi-code-env-" + digest.prefix(16)
    }
}

struct KimiCLIConfiguration {
    var service: KimiService
    var apiKey: String?
    var allowsLegacy: Bool

    static func resolve(
        _ text: String?,
        environment: any EnvironmentReading,
        requiresDefaultModel: Bool
    ) throws -> KimiCLIConfiguration? {
        // CLI는 환경 변수로 선언한 임시 모델을 TOML 기본 모델보다 먼저 선택.
        if requiresDefaultModel, environment.value(for: "KIMI_MODEL_NAME")?.isEmpty == false {
            return nil
        }
        try validateEnvironment(environment)
        let document: Document
        if let text {
            do {
                document = try TOMLDecoder(isLenient: false).decode(Document.self, from: text)
            } catch {
                throw KimiAuthError.configurationInvalid
            }
        } else {
            document = Document(defaultModel: nil, models: nil, providers: nil)
        }

        guard let providers = document.providers else {
            guard !requiresDefaultModel else { return nil }
            let service = try oauthService(baseURL: nil, oauth: nil, environment: environment)
            return KimiCLIConfiguration(service: service, apiKey: nil, allowsLegacy: service == .standard)
        }
        guard
            let selected = try selectProvider(
                document, providers: providers, requiresDefaultModel: requiresDefaultModel
            )
        else { return nil }
        let configuration = try resolveCredential(selected, environment: environment)
        if requiresDefaultModel {
            guard let name = document.defaultModel, let model = document.models?[name],
                model.usesEndpoint(configuration.service.baseURL),
                terminalHeadersMatch(provider: selected.provider, environment: environment)
            else { return nil }
        }
        return configuration
    }

    private static func resolveCredential(
        _ selected: SelectedProvider, environment: any EnvironmentReading
    ) throws -> KimiCLIConfiguration {
        let provider = selected.provider
        let inlineKey = nonempty(provider.apiKey)
        let keyEnvironment = nonempty(provider.apiKeyEnvironment)
        let fallbackKey = nonempty(provider.fallbackAPIKey)
        if inlineKey != nil && keyEnvironment != nil {
            throw KimiAuthError.configurationInvalid
        }

        if let oauth = provider.oauth {
            guard inlineKey == nil, keyEnvironment == nil, fallbackKey == nil else {
                throw KimiAuthError.configurationInvalid
            }
            guard !oauth.key.isEmpty, oauth.storage == "file" || oauth.storage == "keyring" else {
                throw KimiAuthError.configurationInvalid
            }
            let service = try oauthService(
                baseURL: selected.baseURL, oauth: oauth, environment: environment
            )
            let hasOverride = environmentBaseURL(environment) != nil || environmentOAuthHost(environment) != nil
            if !hasOverride, oauth.key == service.credentialKey, oauth.storage == "keyring" {
                throw KimiAuthError.unsupportedConfiguration
            }
            return KimiCLIConfiguration(service: service, apiKey: nil, allowsLegacy: false)
        }

        let key: String?
        if let keyEnvironment {
            key = nonempty(environment.value(for: keyEnvironment))
        } else {
            key = inlineKey ?? fallbackKey
        }
        guard let key else { throw KimiAuthError.apiKeyMissing }
        let baseURL = selected.baseURL ?? KimiService.standard.baseURL
        guard let host = allowedBaseHost(baseURL) else {
            throw KimiAuthError.unsupportedConfiguration
        }
        let oauthHost = host == "api.kimi.ai" ? "https://auth.kimi.ai" : KimiService.standard.oauthHost
        return KimiCLIConfiguration(
            service: KimiService(baseURL: normalizedEndpoint(baseURL), oauthHost: oauthHost),
            apiKey: key,
            allowsLegacy: false
        )
    }

    static func validateEnvironment(_ environment: any EnvironmentReading) throws {
        if let baseURL = environmentBaseURL(environment), allowedBaseHost(baseURL) == nil {
            throw KimiAuthError.unsupportedConfiguration
        }
        if let oauthHost = environmentOAuthHost(environment), !isAllowedOAuthHost(oauthHost) {
            throw KimiAuthError.unsupportedConfiguration
        }
    }

    private static func selectProvider(
        _ document: Document, providers: [String: CLIProvider], requiresDefaultModel: Bool
    ) throws -> SelectedProvider? {
        func selection(_ name: String) -> SelectedProvider? {
            guard let provider = providers[name] else { return nil }
            let baseURL =
                nonempty(provider.baseURL)
                ?? nonempty(provider.fallbackBaseURL)
                ?? (name == "managed:kimi-code" ? KimiService.standard.baseURL : nil)
            return SelectedProvider(provider: provider, baseURL: baseURL)
        }

        if let defaultModel = document.defaultModel,
            let providerName = document.models?[defaultModel]?.provider,
            let selected = selection(providerName),
            let baseURL = selected.baseURL, isCodeHost(baseURL),
            !requiresDefaultModel || allowedBaseHost(baseURL) != nil
        {
            return selected
        }
        guard !requiresDefaultModel else { return nil }
        if let selected = selection("managed:kimi-code") { return selected }
        let candidates = providers.keys.compactMap(selection).filter { selected in
            selected.baseURL.map { allowedBaseHost($0) != nil } ?? false
        }
        guard !candidates.isEmpty else { throw KimiAuthError.unsupportedConfiguration }
        guard candidates.count == 1 else { throw KimiAuthError.configurationInvalid }
        return candidates[0]
    }

    private static func terminalHeadersMatch(provider: CLIProvider, environment: any EnvironmentReading) -> Bool {
        func permits(_ name: String) -> Bool {
            let name = name.trimmingCharacters(in: .whitespaces).lowercased()
            let token = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789!#$%&'*+-.^_`|~")
            return !name.isEmpty && name.unicodeScalars.allSatisfy(token.contains)
                && name != "authorization" && name != "x-api-key"
        }
        if let headers = provider.customHeaders {
            guard case .headers(let values) = headers,
                values.allSatisfy({ permits($0.key) && !$0.value.contains(where: \.isNewline) })
            else { return false }
        }
        let raw = environment.value(for: "KIMI_CODE_CUSTOM_HEADERS") ?? ""
        for line in raw.split(whereSeparator: \.isNewline) where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let colon = line.firstIndex(of: ":"), permits(String(line[..<colon])) else { return false }
        }
        return true
    }

    private static func oauthService(
        baseURL: String?, oauth: OAuthReference?, environment: any EnvironmentReading
    ) throws -> KimiService {
        let overrideBase = environmentBaseURL(environment)
        let overrideHost = environmentOAuthHost(environment)
        let hasOverride = overrideBase != nil || overrideHost != nil
        let selectedBase = overrideBase ?? baseURL ?? KimiService.standard.baseURL
        let selectedHost =
            hasOverride
            ? overrideHost ?? KimiService.standard.oauthHost
            : nonempty(oauth?.oauthHost) ?? KimiService.standard.oauthHost
        guard allowedBaseHost(selectedBase) != nil, isAllowedOAuthHost(selectedHost) else {
            throw KimiAuthError.unsupportedConfiguration
        }
        return KimiService(
            baseURL: normalizedEndpoint(selectedBase), oauthHost: normalizedEndpoint(selectedHost)
        )
    }

    private static func environmentBaseURL(_ environment: any EnvironmentReading) -> String? {
        nonempty(environment.value(for: "KIMI_CODE_BASE_URL"))
    }

    private static func environmentOAuthHost(_ environment: any EnvironmentReading) -> String? {
        nonempty(environment.value(for: "KIMI_CODE_OAUTH_HOST"))
            ?? nonempty(environment.value(for: "KIMI_OAUTH_HOST"))
    }

    private static func allowedBaseHost(_ value: String) -> String? {
        guard let components = endpointComponents(value),
            let host = components.host?.lowercased(),
            ["api.kimi.com", "api.kimi.ai"].contains(host),
            ["/coding", "/coding/v1"].contains(components.percentEncodedPath.trimmingTrailingSlashes)
        else { return nil }
        return host
    }

    private static func isCodeHost(_ value: String) -> Bool {
        guard let host = URLComponents(string: normalizedEndpoint(value))?.host?.lowercased() else { return false }
        return ["api.kimi.com", "api.kimi.ai"].contains(host)
    }

    private static func isAllowedOAuthHost(_ value: String) -> Bool {
        guard let components = endpointComponents(value),
            let host = components.host?.lowercased(),
            ["auth.kimi.com", "auth.kimi.ai"].contains(host),
            components.percentEncodedPath.trimmingTrailingSlashes.isEmpty
        else { return false }
        return true
    }

    private static func endpointComponents(_ value: String) -> URLComponents? {
        guard let components = URLComponents(string: normalizedEndpoint(value)),
            components.scheme?.lowercased() == "https",
            components.port == nil,
            components.user == nil, components.password == nil,
            components.query == nil, components.fragment == nil
        else { return nil }
        return components
    }

    private static func normalizedEndpoint(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingTrailingSlashes
    }

    private static func nonempty(_ value: String?) -> String? {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private struct SelectedProvider {
        let provider: CLIProvider
        let baseURL: String?
    }

    private struct Document: Decodable {
        let defaultModel: String?
        let models: [String: Model]?
        let providers: [String: CLIProvider]?

        enum CodingKeys: String, CodingKey {
            case defaultModel = "default_model"
            case models, providers
        }
    }

    /// 터미널에만 쓰이는 설정의 누락과 해석 실패 구분. 대시보드의 인증 선택과는 독립.
    private enum TerminalField: Decodable {
        case text(String)
        case headers([String: String])
        case invalid

        init(from decoder: Decoder) {
            if let scalar = try? decoder.singleValueContainer() {
                self = (try? scalar.decode(String.self)).map(Self.text) ?? .invalid
            } else {
                self = (try? [String: String](from: decoder)).map(Self.headers) ?? .invalid
            }
        }
    }

    private struct Model: Decodable {
        let provider: String?
        let routeProtocol: TerminalField?
        let baseURL: TerminalField?

        func usesEndpoint(_ endpoint: String) -> Bool {
            // 모델의 protocol과 base_url을 함께 지정할 때만 프로바이더의 주소를 재정의.
            guard let baseURL, let routeProtocol else { return true }
            guard case .text(let url) = baseURL, case .text(let name) = routeProtocol, nonempty(name) != nil,
                let modelHost = allowedBaseHost(url)
            else { return false }
            return modelHost == allowedBaseHost(endpoint)
        }

        enum CodingKeys: String, CodingKey {
            case provider
            case routeProtocol = "protocol"
            case baseURL = "base_url"
        }
    }

    private struct CLIProvider: Decodable {
        let type: String?
        let baseURL: String?
        let apiKey: String?
        let apiKeyEnvironment: String?
        let oauth: OAuthReference?
        let customHeaders: TerminalField?
        let environment: [String: String]?

        var fallbackAPIKey: String? {
            environmentPrefix.flatMap { environment?["\($0)_API_KEY"] }
        }

        var fallbackBaseURL: String? {
            environmentPrefix.flatMap { environment?["\($0)_BASE_URL"] }
        }

        private var environmentPrefix: String? {
            switch type {
            case "kimi": "KIMI"
            case "anthropic": "ANTHROPIC"
            case "openai", "openai_responses": "OPENAI"
            default: nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case type
            case baseURL = "base_url"
            case apiKey = "api_key"
            case apiKeyEnvironment = "api_key_env"
            case oauth
            case customHeaders = "custom_headers"
            case environment = "env"
        }
    }

    private struct OAuthReference: Decodable {
        let storage: String
        let key: String
        let oauthHost: String?

        enum CodingKeys: String, CodingKey {
            case storage, key
            case oauthHost = "oauth_host"
        }
    }
}
