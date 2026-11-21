import Foundation
import Network

/// 프로바이더 HTTP 요청의 선택 프록시 — ~/.openusage/config.json의 proxy 설정 사용.
/// 최초 사용 시 한 번 로드 — 설정 변경은 재시작 후 적용, 없거나 읽기 불가·무효·비활성이면 사용 안 함.
struct ProxyConfig: Equatable, Sendable {
    enum Scheme: String, Equatable, Sendable {
        case socks5
        case http
        case https

        var defaultPort: UInt16 {
            switch self {
            case .socks5: return 1080
            case .http: return 80
            case .https: return 443
            }
        }
    }

    var scheme: Scheme
    var host: String
    var port: UInt16
    var username: String?
    var password: String?

    static let configPath = "~/.openusage/config.json"

    /// 앱 전역 프록시 — 첫 사용 시 디스크에서 한 번 읽기.
    static let current: ProxyConfig? = load(
        text: try? String(
            contentsOfFile: NSString(string: configPath).expandingTildeInPath,
            encoding: .utf8
        )
    )

    /// proxy.enabled가 true이고 유효한 socks5·http·https URL일 때만 설정 생성 — 나머지는 nil.
    static func load(text: String?) -> ProxyConfig? {
        guard let text,
              let data = text.data(using: .utf8),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let proxy = root["proxy"] as? [String: Any],
              proxy["enabled"] as? Bool == true,
              let urlString = proxy["url"] as? String,
              let url = URL(string: urlString),
              let schemeRaw = url.scheme?.lowercased(),
              let scheme = Scheme(rawValue: schemeRaw),
              let host = url.host(), !host.isEmpty
        else { return nil }

        return ProxyConfig(
            scheme: scheme,
            host: host,
            port: url.port.flatMap { UInt16(exactly: $0) } ?? scheme.defaultPort,
            username: url.user(percentEncoded: false),
            password: url.password(percentEncoded: false)
        )
    }

    /// URL의 인증 정보를 적용한 Network 프록시 — localhost·127.0.0.1·::1은 항상 우회.
    func proxyConfiguration() -> ProxyConfiguration {
        let endpoint = NWEndpoint.hostPort(host: .init(host), port: .init(rawValue: port)!)
        var configuration: ProxyConfiguration
        switch scheme {
        case .socks5:
            configuration = ProxyConfiguration(socksv5Proxy: endpoint)
        case .http:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: nil)
        case .https:
            configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
        }
        if let username, let password {
            configuration.applyCredential(username: username, password: password)
        }
        configuration.excludedDomains = ["localhost", "127.0.0.1", "::1"]
        return configuration
    }
}
