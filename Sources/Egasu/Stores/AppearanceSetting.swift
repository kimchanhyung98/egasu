import AppKit

/// 앱 전체 테마 설정 — system은 macOS 설정 상속.
/// 패널이 SwiftUI preferredColorScheme을 따르지 않으므로 NSApp.appearance에 적용.
/// applyCurrent()의 변경 알림으로 메뉴 막대 패널도 동기화.
enum AppearanceSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case system
    case light
    case dark

    static let key = "appearance"
    static var fallback: AppearanceSetting { .system }

    /// 앱 테마 적용 후 변경 알림 게시 — 패널 소유자가 같은 테마 반영.
    static let didChangeNotification = Notification.Name("AppearanceSettingDidChange")

    var label: String {
        switch self {
        case .system: return L10n.settings("System")
        case .light: return L10n.settings("Light")
        case .dark: return L10n.settings("Dark")
        }
    }

    /// system은 nil — OS 설정을 상속하여 테마 변경 즉시 반영.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }

    // 저장된 선택값 current는 UserDefaultsBacked에서 제공 — 미설정 시 system.

    /// 저장된 테마를 앱 전역에 적용 — 시작 시 한 번, 설정 변경 시마다 호출.
    @MainActor
    static func applyCurrent() {
        NSApplication.shared.appearance = current.nsAppearance
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
