import Foundation

/// 메뉴 막대 스트립 내용 — Priority 보드에서 고른 항목, 넘친 개수, 업데이트 점.
struct MenuBarContent: Equatable {
    struct Item: Equatable, Identifiable {
        let id: String
        let icon: IconSource
        let providerName: String
        /// 같은 프로바이더 계정이 여럿일 때만 계정 이니셜.
        let badge: String?
        let label: String
        let shortLabel: String
        let value: String
        var fraction: Double? = nil
    }

    let items: [Item]
    var overflow = 0
    var updateAvailable = false
    /// 시간만으로 내용이 바뀌는 가장 이른 시각 — 순위 재계산(30초)·예측 기한.
    var nextInvalidation: Date?

    var isEmpty: Bool { items.isEmpty }

    func showingExtraIndicators(_ show: Bool) -> Self {
        var content = self
        if !show {
            content.overflow = 0
            content.updateAvailable = false
        }
        return content
    }

    /// 그림이 같은지 — `nextInvalidation`은 다음 재렌더 시각일 뿐 그림에 영향 없음(렌더 캐시 키).
    func drawsSame(as other: MenuBarContent) -> Bool {
        items == other.items && overflow == other.overflow && updateAvailable == other.updateAvailable
    }

    var accessibilityText: String {
        let shown = items.map { "\($0.providerName) \($0.label) \($0.value)" }
        let more = overflow > 0 ? [L10n.dashboard("%lld more", overflow)] : []
        let update = updateAvailable ? [L10n.dashboard("Update Available")] : []
        return (shown + more + update).joined(separator: "; ")
    }
}

/// 계정 이니셜 배지 — 단어 첫 글자, 여러 단어면 첫·마지막 단어 첫 글자("Attention Machine 1" → "A1").
enum AccountInitials {
    static func tag(for name: String) -> String {
        let initials = name.split(whereSeparator: \.isWhitespace).compactMap(\.first)
        guard let first = initials.first else { return "" }
        let letters = initials.count > 1 ? [first, initials[initials.count - 1]] : [first]
        return String(letters).uppercased()
    }
}

@MainActor
enum MenuBarContentBuilder {
    private static let genericWords: Set<String> = ["models", "bot", "usage"]
    static let rankingTick: TimeInterval = 30

    /// 소진 임박·Priority·고정만 중 선택 — 고정 전용은 사용자가 저장한 계정·지표 순서 유지.
    /// 데이터 없는 행(실패한 예측 등)은 자리를 차지하지 않음. 계정 배지는 `multiAccountFamilies`의 패밀리에만.
    /// Priority 모드에서 고정하지 않은 소진됨은 남는 칸에만 표시하고 `+N`에 세지 않음.
    static func build(
        board: PriorityBoard, limit: MenuBarLimit, selection: MenuBarSelection = .runningOut,
        multiAccountFamilies: Set<String> = [], style: MenuBarStyle = .text, now: Date = Date()
    ) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let counted: [(DashboardAccount, DashboardLine)] = switch selection {
        case .runningOut: board.runningOut.map { ($0.account, $0.line) }
        case .priority:
            board.pinned.map { ($0.account, $0.line) }
                + (board.attention + board.useItOrLoseIt).map { ($0.account, $0.line) }
        case .pinnedOnly: board.pinned.map { ($0.account, $0.line) }
        }
        let usedUp = selection == .priority ? board.usedUp.map { ($0.account, $0.line) } : []
        func withData(_ candidates: [(DashboardAccount, DashboardLine)]) -> [(DashboardAccount, DashboardLine, WidgetData)] {
            candidates.compactMap { account, line in
                let presented = line.data.presented(at: now)
                guard presented.hasData, style != .bars || presented.isBounded else { return nil }
                return (account, line, presented)
            }
        }
        let countedEntries = withData(counted)
        let shownEntries = (countedEntries + withData(usedUp)).prefix(limit.count)
        let items = shownEntries.map { account, line, presented in
            let label = line.data.localizedTitle
            let isSibling = multiAccountFamilies.contains(AppContainer.dashboardFamilyID(for: account.id))
            let badge = isSibling ? account.name.map(AccountInitials.tag).flatMap { $0.isEmpty ? nil : $0 } : nil
            return MenuBarContent.Item(
                id: line.id,
                icon: account.provider.icon,
                providerName: account.fullName,
                badge: badge,
                label: label,
                shortLabel: shortLabel(label),
                value: presented.menuBarValue,
                fraction: presented.isBounded ? presented.fraction : nil
            )
        }
        // 갱신에 실패한 예측은 기한에 사라지므로 넘친 항목 수도 다시 계산.
        let deadlines = countedEntries.compactMap { $0.2.forecastDeadline }.filter { $0 > now }
        let ranked = selection == .runningOut ? board.runningOut : board.attention
        let tick =
            selection != .pinnedOnly && PriorityBoard.requiresRankingClock(for: ranked, at: now)
            ? [now.addingTimeInterval(rankingTick)] : []
        let priorityDeadline = selection == .priority ? board.nextUseItOrLoseItChange : nil
        return MenuBarContent(
            items: items,
            overflow: max(0, countedEntries.count - items.count),
            nextInvalidation: (deadlines + tick + [priorityDeadline].compactMap { $0 }).min()
        )
    }

    /// 계정이 둘 이상인 패밀리 — 메뉴 막대에서 계정 이니셜 배지로 구분.
    static func multiAccountFamilies(_ accounts: [DashboardAccount]) -> Set<String> {
        let counts = Dictionary(grouping: accounts, by: { AppContainer.dashboardFamilyID(for: $0.id) }).mapValues(\.count)
        return Set(counts.filter { $0.value > 1 }.keys)
    }

    /// 라벨 끝의 일반 단어(models, bot, usage) 생략 — "Premium Usage" → "Premium".
    static func shortLabel(_ label: String) -> String {
        var words = label.split(separator: " ")
        guard words.count > 1, let last = words.last, genericWords.contains(last.lowercased()) else { return label }
        words.removeLast()
        return words.joined(separator: " ")
    }
}
