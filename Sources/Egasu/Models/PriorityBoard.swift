import Foundation

/// Priority 보드의 한도 하나와 올라간 이유.
struct PriorityItem: Identifiable {
    enum Reason: Equatable {
        /// 남은 양 기준 — 막대 색과 같은 규칙.
        case low(WidgetData.MeterSeverity, remaining: Double, runway: TimeInterval?)
        /// 현재 속도로 초기화 전 소진.
        case burningFast(runway: TimeInterval)
        case usedUp(resetsAt: Date?)
        case emptyBalance
        /// 하루 안에 초기화되는데 절반 넘게 남음 — Use It or Lose It 알림과 같은 규칙.
        case useItOrLoseIt(resetsAt: Date)

        enum Section { case runningOut, usedUp, useItOrLoseIt }

        /// 여러 조건이 겹치면 표시할 잔량 구간, 빠른 소진, 초기화 전 사용 순으로 선택.
        init?(
            _ line: DashboardLine, now: Date, visibleLevels: Set<WidgetData.MeterSeverity>,
            burningFast: BurningFast?, useItOrLoseIt: Bool
        ) {
            let data = line.data.presented(at: now)
            if let balance = line.descriptor.balance(in: data), balance <= 0 {
                self = .emptyBalance
                return
            }
            guard data.hasData, data.isQuotaMeter, data.valueTextOverride == nil else { return nil }
            if case .spent = data.meterState(now: now) {
                self = .usedUp(resetsAt: data.resetsAt)
                return
            }
            if visibleLevels.contains(data.severity) {
                self = .low(data.severity, remaining: data.remainingFraction, runway: data.runway(now: now))
                return
            }
            if burningFast?.contains(line, now: now) == true, let runway = data.runway(now: now) {
                self = .burningFast(runway: runway)
                return
            }
            guard useItOrLoseIt, PaceNotificationLogic.isUnusedNearReset(data, now: now), let resetsAt = data.resetsAt
            else { return nil }
            self = .useItOrLoseIt(resetsAt: resetsAt)
        }

        fileprivate var section: Section {
            switch self {
            case .low, .burningFast: .runningOut
            case .usedUp, .emptyBalance: .usedUp
            case .useItOrLoseIt: .useItOrLoseIt
            }
        }

        /// 오름차순 — 가장 먼저 소진될 것, 속도로 판단 못 하면 남은 양 순.
        fileprivate var rank: (tier: Int, closeness: Double) {
            switch self {
            case .low(_, _, let runway?), .burningFast(let runway): (0, runway)
            case .low(_, let remaining, nil): (1, remaining)
            case .usedUp(let resetsAt): (2, resetsAt?.timeIntervalSinceReferenceDate ?? .infinity)
            case .emptyBalance: (2, .infinity)
            case .useItOrLoseIt(let resetsAt): (3, resetsAt.timeIntervalSinceReferenceDate)
            }
        }
    }

    let account: DashboardAccount
    let line: DashboardLine
    let reason: Reason
    /// 고정한 지표는 상태와 관계없이 Pinned에만 표시.
    let isPinned: Bool

    var id: String { line.id }
    var data: WidgetData { line.data }
    var severity: WidgetData.MeterSeverity {
        switch reason {
        case .usedUp, .emptyBalance: .critical
        case .low(let severity, _, _): severity
        case .burningFast, .useItOrLoseIt: data.fillSeverity
        }
    }

    func runOutText(now: Date) -> String? {
        guard case .burningFast(let runway) = reason, let resetsAt = data.resetsAt,
              runway < resetsAt.timeIntervalSince(now), let duration = Formatters.compactDuration(runway)
        else { return nil }
        return L10n.dashboard("Out in %@", duration)
    }

    func resetsInText(now: Date) -> String? {
        guard case .useItOrLoseIt(let resetsAt) = reason,
              let duration = Formatters.countdown(to: resetsAt, now: now)
        else { return nil }
        return L10n.metrics("Resets in %@", duration)
    }

    func usedUpNote(now: Date) -> String? {
        guard case .emptyBalance = reason else { return data.compactResetText(now: now) }
        return data.unboundedDetail
    }

}

/// 사용자가 고정한 지표와 해당 계정.
struct PinnedMetric: Identifiable {
    let account: DashboardAccount
    let line: DashboardLine
    let item: PriorityItem?

    var id: String { line.id }
    var data: WidgetData { line.data }
}

/// 확인이 필요한 한도를 급한 순서로 — 메뉴 막대와 Priority 탭이 공유.
struct PriorityBoard {
    enum Summary: Equatable {
        case waitingForUsage
        case noReportedLimits
        case unavailable
        case allClear
        case listed
    }

    enum ReadStatus {
        case waiting, current, unavailable(String)
    }

    struct AccountNotice: Identifiable {
        let account: DashboardAccount
        let message: String
        var id: String { account.id }
    }

    /// 저장된 계정·지표 순서 유지 — 소진 완료를 포함해 다른 구역으로 이동하지 않음.
    let pinned: [PinnedMetric]
    /// 메뉴 막대 자동 선택용 전체 소진 임박 항목 — 고정 여부와 무관하게 급한 순서.
    let runningOut: [PriorityItem]
    let attention: [PriorityItem]
    let usedUp: [PriorityItem]
    /// 절반 넘게 남은 채 하루 안에 초기화되는 한도, 빠른 초기화 순.
    let useItOrLoseIt: [PriorityItem]
    let notices: [AccountNotice]
    /// 첫 응답을 받기 전의 계정 — 대시보드 순서로 로딩 행 표시.
    let waiting: [DashboardAccount]
    let summary: Summary
    /// 모든 계정이 보고했고 소진 임박이 없음.
    let showsClearRow: Bool
    /// 초기화 전 사용 목록이 시간에 따라 바뀌는 다음 시각.
    let nextUseItOrLoseItChange: Date?

    /// 새 읽기 없이도 기간이 지나며 순위가 바뀌거나 빠른 소진이 풀릴 수 있음 — 30초 재계산 필요 여부.
    static func requiresRankingClock(for items: [PriorityItem], at now: Date) -> Bool {
        if items.contains(where: { if case .burningFast = $0.reason { true } else { false } }) { return true }
        return items.count > 1
            && items.contains { item in
                guard let reset = item.data.resetsAt, let period = item.data.periodDurationMs else { return false }
                return reset > now && period > 0
            }
    }

    /// `accounts`는 사용자 저장 순서 — 동률은 이 순서로 결정.
    static func make(
        accounts: [DashboardAccount], pinned pinnedIDs: Set<String> = [],
        visibleLevels: Set<WidgetData.MeterSeverity> = [.warning, .critical], burningFast: BurningFast? = nil,
        useItOrLoseIt: Bool = false, now: Date,
        status: (DashboardAccount) -> ReadStatus = { $0.waitingMetricIDs.isEmpty ? .current : .waiting }
    ) -> PriorityBoard {
        let lines = accounts.flatMap { account in account.lines.map { (account, $0) } }
        let readings = lines.map { account, line in
            let isPinned = pinnedIDs.contains(line.id)
            let item = PriorityItem.Reason(
                line, now: now, visibleLevels: visibleLevels, burningFast: burningFast, useItOrLoseIt: useItOrLoseIt
            ).map {
                PriorityItem(account: account, line: line, reason: $0, isPinned: isPinned)
            }
            return (pin: isPinned ? PinnedMetric(account: account, line: line, item: item) : nil, item: item)
        }
        let ranked = readings.compactMap(\.item).enumerated().sorted { lhs, rhs in
            let (left, right) = (lhs.element.reason.rank, rhs.element.reason.rank)
            return (left.tier, left.closeness, lhs.offset) < (right.tier, right.closeness, rhs.offset)
        }.map(\.element)

        var waiting: [DashboardAccount] = []
        var notices: [AccountNotice] = []
        for account in accounts {
            switch status(account) {
            case .waiting: waiting.append(account)
            case .unavailable(let message): notices.append(AccountNotice(account: account, message: message))
            case .current: break
            }
        }
        let awaitingUsage = accounts.isEmpty || !waiting.isEmpty
        let reportsLimit = lines.contains { $0.1.data.hasData && $0.1.data.isQuotaMeter }
        let summary: Summary =
            if !ranked.isEmpty {
                .listed
            } else if !notices.isEmpty {
                .unavailable
            } else if awaitingUsage {
                .waitingForUsage
            } else if reportsLimit {
                .allClear
            } else {
                .noReportedLimits
            }
        let runningOut = ranked.filter { $0.reason.section == .runningOut }
        let nextUseItOrLoseItChange: Date? =
            useItOrLoseIt
            ? lines.compactMap { _, line in
                let data = line.data
                guard !pinnedIDs.contains(line.id), data.isQuotaMeter, data.valueTextOverride == nil,
                    !visibleLevels.contains(data.severity), let reset = data.resetsAt
                else { return nil }
                let start = reset.addingTimeInterval(-PaceNotificationLogic.useItOrLoseItLead)
                guard PaceNotificationLogic.isUnusedNearReset(data, now: max(start, now)) else { return nil }
                return start > now ? start : reset
            }.min() : nil
        return PriorityBoard(
            pinned: readings.compactMap(\.pin),
            runningOut: runningOut,
            attention: runningOut.filter { !$0.isPinned },
            usedUp: ranked.filter { $0.reason.section == .usedUp && !$0.isPinned },
            useItOrLoseIt: ranked.filter { $0.reason.section == .useItOrLoseIt && !$0.isPinned },
            notices: notices, waiting: waiting, summary: summary,
            showsClearRow: reportsLimit && !awaitingUsage && notices.isEmpty && runningOut.isEmpty,
            nextUseItOrLoseItChange: nextUseItOrLoseItChange
        )
    }

    /// 복사할 만한 행이 있는지 — 고정 지표 포함.
    var hasRows: Bool { summary == .listed || !pinned.isEmpty }
}
