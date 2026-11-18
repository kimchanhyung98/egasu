import Foundation

/// 메뉴 막대 지표 표시 형식 — 텍스트 또는 막대.
/// `DisplaySettingsStore`가 저장하며 기본값은 `.text`.
enum MenuBarStyle: String, Hashable, Sendable, CaseIterable {
    case text
    case bars

    var label: String {
        switch self {
        case .text: return L10n.settings("Text")
        case .bars: return L10n.settings("Bars")
        }
    }
}
