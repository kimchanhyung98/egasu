import DesktopWidgetSupport
import Foundation

enum DesktopWidgetProjection {
    static func state(available: Bool, refreshFailed: Bool, staleAt: Date?, now: Date) -> DesktopWidgetState {
        guard available else { return .unavailable }
        if refreshFailed { return .failed }
        guard let staleAt else { return .waiting }
        return now >= staleAt ? .stale : .current
    }

    /// 저장소가 현재 카탈로그에 맞춰 적재한 캐시만 사용하고, 실시간 응답의 신원도 대조.
    @MainActor
    static func permitsReading(
        profile: AccountProfile?, binding: WidgetDataStore.ClaimRefreshBinding?, local: ProviderSnapshot?
    ) -> Bool {
        guard let profile else { return true }
        guard binding == .account(profile.identityKey) else { return false }
        if let actual = local?.codexSwitchIdentity, profile.family == "codex" {
            return actual == profile.identityKey
        }
        if let key = local?.liveQuotaAccountKey, profile.family == "claude" {
            var identity = profile.identityKey
            if !identity.contains("|"), let verified = local?.legacyClaudeSwitchIdentity {
                guard verified.identityKey.hasPrefix(identity + "|") else { return false }
                identity = verified.identityKey
            }
            return key == UsageTimerObservation.accountKey(family: "claude", identity: identity)
        }
        return true
    }

    static func metric(_ descriptor: WidgetDescriptor, line: DashboardLine?, now: Date) -> DesktopWidgetMetric {
        let id = ProviderAccountID.canonicalMetricID(descriptor.id)
        let name = descriptor.sample.localizedTitle
        guard let line else { return DesktopWidgetMetric(id: id, name: name) }
        let data = line.data.presented(at: now)
        guard data.hasData else { return DesktopWidgetMetric(id: id, name: name) }
        let model = line.dashboardRow(now: now)
        switch model.mark {
        case .bar(let fill, _, let value, let reset, _):
            let date: Date?
            if let forecast = data.forecast {
                date = forecast.refreshFailed ? nil : forecast.deadline
            } else {
                date = data.isFreshSessionWindow(now: now) ? nil : data.resetsAt
            }
            return DesktopWidgetMetric(
                id: id, name: name, value: value, detail: date == nil ? reset : nil, resetsAt: date, fill: fill
            )
        case .value(let value, let detail, _):
            return DesktopWidgetMetric(id: id, name: name, value: value, detail: detail)
        case .chart:
            let point = line.data.chartPoints.last
            return DesktopWidgetMetric(
                id: id, name: name, value: point?.localizedReadout, detail: point?.localizedLabel)
        }
    }

    static func priority(
        _ board: PriorityBoard, enabled: Bool, sources: [DesktopWidgetSource], now: Date
    ) -> DesktopWidgetPriority {
        guard enabled else { return DesktopWidgetPriority(state: .disabled, rows: []) }
        let sourcesByCard = Dictionary(grouping: sources, by: \.cardID)
        func accountID(_ cardID: String, metricID: String? = nil) -> String? {
            let shared = metricID.map(ProviderAccountID.isSharedMetric) ?? false
            return sourcesByCard[cardID]?.first { $0.shared == shared }?.id
        }
        var rows: [DesktopPriorityRow] = []
        func append(
            _ section: DesktopPrioritySection, account: DashboardAccount, line: DashboardLine, item: PriorityItem?
        ) {
            guard let id = accountID(account.id, metricID: line.id) else { return }
            let data = line.data.presented(at: now)
            let spent: Bool =
                switch item?.reason {
                case .usedUp?, .emptyBalance?: true
                default: false
                }
            let estimatedExhaustion = item?.runOutInterval(now: now).map { now.addingTimeInterval($0) }
            let detail = data.resetsAt == nil && data.forecastDeadline == nil ? item?.usedUpNote(now: now) : nil
            rows.append(
                DesktopPriorityRow(
                    section: section, accountID: id, metricID: ProviderAccountID.canonicalMetricID(line.id),
                    title: data.localizedTitle, value: spent ? L10n.dashboard("Used Up") : data.amountText,
                    detail: detail, estimatedExhaustionAt: estimatedExhaustion
                ))
        }
        for pin in board.pinned { append(.pinned, account: pin.account, line: pin.line, item: pin.item) }
        for item in board.attention { append(.runningOut, account: item.account, line: item.line, item: item) }
        for item in board.useItOrLoseIt { append(.useItOrLoseIt, account: item.account, line: item.line, item: item) }
        for notice in board.notices {
            guard let id = accountID(notice.id) else { continue }
            rows.append(
                DesktopPriorityRow(
                    section: .notice, accountID: id, title: L10n.dashboard("Open egasu for details.")
                ))
        }
        for account in board.waiting {
            guard let id = accountID(account.id) else { continue }
            rows.append(
                DesktopPriorityRow(section: .waiting, accountID: id, title: L10n.dashboard("Waiting for Usage")))
        }
        for item in board.usedUp { append(.usedUp, account: item.account, line: item.line, item: item) }
        let state: DesktopPriorityState =
            switch board.summary {
            case .waitingForUsage: .waitingForUsage
            case .noReportedLimits: .noReportedLimits
            case .unavailable: .unavailable
            case .allClear: .allClear
            case .listed: .listed
            }
        return DesktopWidgetPriority(state: state, rows: rows, showsClearRow: board.showsClearRow)
    }
}
