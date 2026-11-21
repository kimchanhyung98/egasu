import Foundation

/// 메뉴 막대에 올릴 지표 — 자동 후보 또는 사용자가 고정한 지표만.
enum MenuBarSelection: String, Hashable, Sendable, CaseIterable {
    case runningOut
    case priority
    case pinnedOnly

    var label: String {
        switch self {
        case .runningOut: L10n.dashboard("Running Out")
        case .priority: L10n.dashboard("Priority")
        case .pinnedOnly: L10n.settings("Pinned Only")
        }
    }
}

/// 메뉴 막대에 그리는 최대 항목 수 — 0이면 앱 아이콘만.
enum MenuBarLimit: String, Hashable, Sendable, CaseIterable {
    case iconOnly
    case upToOne
    case upToTwo
    case upToThree
    case upToFour
    case upToFive

    var count: Int {
        switch self {
        case .iconOnly: 0
        case .upToOne: 1
        case .upToTwo: 2
        case .upToThree: 3
        case .upToFour: 4
        case .upToFive: 5
        }
    }

    /// 개수에 맞는 선택지 — 범위 밖은 가장 가까운 끝으로.
    init(count: Int) {
        self = Self.allCases.last { $0.count <= max(count, 0) } ?? .iconOnly
    }

    var label: String {
        self == .iconOnly ? L10n.settings("App Icon Only") : L10n.settings("Up to %d", count)
    }
}
