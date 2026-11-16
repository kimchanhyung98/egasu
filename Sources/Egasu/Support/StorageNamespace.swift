import Foundation

/// egasu 소유 저장 위치의 이름 — 운영 번들은 "egasu", 다른 번들(개발 빌드 등)은 접미사를 붙여 운영 데이터와 분리.
/// "OpenUsage" 이름은 저장소 이전 원본과 구버전이 공유하는 실행 잠금에 유지.
struct StorageNamespace: Equatable, Sendable {
    static let productionBundleIdentifier = "com.kimchanhyung98.openusage"
    static let legacyName = "OpenUsage"
    static let current = StorageNamespace(bundleIdentifier: AppBundleLocator.current.bundleIdentifier)

    /// Application Support·`~/.config` 폴더 이름이자 Keychain 항목 접두어.
    let name: String

    init(bundleIdentifier: String?) {
        let production = Self.productionBundleIdentifier
        guard let identifier = bundleIdentifier, identifier != production else {
            name = "egasu"
            return
        }
        let suffix =
            identifier.hasPrefix(production + ".") ? String(identifier.dropFirst(production.count + 1)) : identifier
        name = "egasu.\(suffix)"
    }

    var isProduction: Bool { name == "egasu" }

    /// `~/Library/Application Support/<name>/`
    func applicationSupportDirectory(fileManager: FileManager = .default) -> URL {
        Self.applicationSupportRoot(fileManager).appendingPathComponent(name, isDirectory: true)
    }

    /// 사용자가 직접 만들 수 있는 설정 파일 — `~/.config/<name>/<file>`.
    func configPath(_ file: String) -> String { "~/.config/\(name)/\(file)" }

    static func applicationSupportRoot(_ fileManager: FileManager = .default) -> URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Application Support", isDirectory: true)
    }
}
