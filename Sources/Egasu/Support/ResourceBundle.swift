import Foundation

extension Bundle {
    /// 프로바이더 SVG·가격 보충표·가격 스냅샷을 담은 리소스 번들.
    /// 배포 앱의 Contents/Resources를 먼저 탐색하여 Bundle.module의 경로 불일치로 인한 종료 방지.
    /// 유효한 후보가 없으면 `Bundle.module` 사용.
    static let egasuResources: Bundle = {
        let bundleName = "Egasu_Egasu.bundle"
        let containingAppResources = Bundle.main.executableURL
            .flatMap(ContainingAppBundle.url(for:))?
            .appendingPathComponent("Contents/Resources", isDirectory: true)
        let searchBases: [URL?] = [
            Bundle.main.resourceURL,                          // packaged .app의 Contents/Resources
            Bundle.main.bundleURL,                            // 앱 루트 옆 bundle
            containingAppResources,                          // 번들된 CLI: helper → 앱 Resources
            Bundle(for: ResourceBundleToken.self).resourceURL,
            Bundle(for: ResourceBundleToken.self).bundleURL
        ]
        for case let base? in searchBases {
            guard let bundle = Bundle(url: base.appendingPathComponent(bundleName)) else { continue }
            if isValidEgasuResourceBundle(bundle) {
                return bundle
            }
            // 가격 보충표가 없는 동명 폴더는 로그에 남기고 다음 위치 탐색.
            AppLog.warn(.config, "ignoring resource bundle at \(base.lastPathComponent): missing expected resources")
        }
        return .module
    }()
}

/// 유효 리소스 번들 판정 — 루트의 가격 보충표 존재 확인.
/// 가격 저장소와 같은 조회 규칙을 사용하여 실제 배포 번들 인식.
private func isValidEgasuResourceBundle(_ bundle: Bundle) -> Bool {
    bundle.url(forResource: "pricing_supplement", withExtension: "json") != nil
}

private final class ResourceBundleToken {}
