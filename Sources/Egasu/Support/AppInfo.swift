import Foundation

/// 대시보드 푸터, 로그, 사용 통계에 사용하는 앱 버전.
/// `CFBundleShortVersionString`을 그대로 읽음. 버전이 없으면 `0.0.0-dev` 사용.
enum AppInfo {
    static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0-dev"
    }
}
