import CryptoKit
import Foundation

/// 저장 위치 이름 — 운영은 "egasu", 표준 개발은 "egasu.dev", 그 외 식별자는 전체 값의 해시로 분리.
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
        if identifier == production + ".dev" {
            name = "egasu.dev"
            return
        }
        let digest = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        name = "egasu.suite.\(digest)"
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
