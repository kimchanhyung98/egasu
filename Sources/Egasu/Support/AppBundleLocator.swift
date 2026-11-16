import Foundation

public struct AppBundleLocator: Sendable {
    public let bundleIdentifier: String
    public let version: String?

    /// 앱은 자체 식별자, 번들 식별자가 없는 CLI는 포함 앱과 설정 도메인 재정의를 사용.
    public static let current: AppBundleLocator = {
        if let identifier = Bundle.main.bundleIdentifier {
            return AppBundleLocator(
                bundleIdentifier: identifier,
                version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            )
        }
        return locate()
    }()

    public static func locate(
        executableURL: URL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> AppBundleLocator {
        for key in ["EGASU_DEFAULTS_SUITE", "OPENUSAGE_DEFAULTS_SUITE"] {
            if let suite = environment[key], !suite.isEmpty {
                return AppBundleLocator(bundleIdentifier: suite, version: nil)
            }
        }

        if let appURL = ContainingAppBundle.url(for: executableURL),
           let info = NSDictionary(contentsOf: appURL.appendingPathComponent("Contents/Info.plist")),
           let bundleIdentifier = info["CFBundleIdentifier"] as? String {
            return AppBundleLocator(
                bundleIdentifier: bundleIdentifier,
                version: info["CFBundleShortVersionString"] as? String
            )
        }

        return AppBundleLocator(bundleIdentifier: "com.kimchanhyung98.openusage", version: nil)
    }
}
