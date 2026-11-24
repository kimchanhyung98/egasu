import Foundation

/// 위젯 링크는 탐색 대상만 전달하며 계정 정보는 호스트가 현재 카탈로그에서 해석.
public enum DesktopWidgetDestination: Equatable, Sendable {
    case priority
    case allUsage
    case alerts
    case account(String)

    public func url(scheme: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "widget"
        switch self {
        case .priority: components.path = "/priority"
        case .allUsage: components.path = "/all-usage"
        case .alerts: components.path = "/alerts"
        case .account(let id):
            guard !id.isEmpty else { return nil }
            components.path = "/account"
            components.queryItems = [URLQueryItem(name: "id", value: id)]
        }
        return components.url
    }

    public init?(url: URL, scheme: String) {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false),
            link.scheme?.lowercased() == scheme.lowercased(), link.host?.lowercased() == "widget",
            link.user == nil, link.password == nil, link.port == nil, link.fragment == nil
        else { return nil }
        switch (link.path, link.queryItems) {
        case ("/priority", nil): self = .priority
        case ("/all-usage", nil): self = .allUsage
        case ("/alerts", nil): self = .alerts
        case ("/account", let items?):
            guard items.count == 1, let item = items.first, item.name == "id",
                let id = item.value, !id.isEmpty
            else { return nil }
            self = .account(id)
        default: return nil
        }
    }
}
