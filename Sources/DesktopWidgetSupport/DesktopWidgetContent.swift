import Foundation

public struct DesktopWidgetContent: Codable, Equatable, Sendable {
    public let accounts: [DesktopWidgetAccount]
    public let priority: DesktopWidgetPriority
    public let language: String

    public init(accounts: [DesktopWidgetAccount], priority: DesktopWidgetPriority, language: String) {
        self.accounts = accounts
        self.priority = priority
        self.language = language
    }

    public func priorityTimelineDates(after date: Date) -> [Date] {
        let metrics = Dictionary(grouping: priority.rows, by: \.accountID)
            .mapValues { Set($0.compactMap(\.metricID)) }
        let forecasts = priority.rows.compactMap { $0.upcomingExhaustion(at: date) }
        return Set(timelineDates(after: date, including: metrics)).union(forecasts).sorted()
    }

    /// 새 관측 없이 상태나 초기화 시각 표시가 바뀌는 시점.
    public func timelineDates(after date: Date, including metricsByAccount: [String: Set<String>]? = nil) -> [Date] {
        var dates = Set<Date>()
        for account in accounts {
            let metrics = metricsByAccount?[account.id]
            if metricsByAccount != nil && metrics == nil { continue }
            if account.state == .current, let staleAt = account.staleAt, staleAt > date {
                dates.insert(staleAt)
            }
            for metric in account.metrics where metrics?.contains(metric.id) != false {
                if let reset = metric.resetsAt, reset > date { dates.insert(reset) }
            }
        }
        return dates.sorted()
    }
}

public enum DesktopWidgetAccountID {
    public static func profile(providerID: String, profileID: String) -> String {
        "\(providerID)/profile/\(profileID)"
    }

    public static func current(providerID: String) -> String { "\(providerID)/current" }
    public static func shared(providerID: String) -> String { "\(providerID)/shared" }
}

public enum DesktopWidgetState: String, Codable, Sendable {
    case current, waiting, stale, failed, unavailable
}

public struct DesktopWidgetAccount: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let providerID: String
    public let providerName: String
    public let name: String
    public let state: DesktopWidgetState
    public let observedAt: Date?
    public let staleAt: Date?
    public let metrics: [DesktopWidgetMetric]

    public init(
        id: String, providerID: String, providerName: String? = nil, name: String, state: DesktopWidgetState,
        observedAt: Date? = nil, staleAt: Date? = nil, metrics: [DesktopWidgetMetric]
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName ?? providerID
        self.name = name
        self.state = state
        self.observedAt = observedAt
        self.staleAt = staleAt
        self.metrics = metrics
    }

    public func state(at date: Date) -> DesktopWidgetState {
        if state == .current, let staleAt, date >= staleAt { return .stale }
        return state
    }
}

public struct DesktopWidgetMetric: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let value: String?
    public let detail: String?
    public let resetsAt: Date?
    public let fill: Double?

    public init(
        id: String, name: String, value: String? = nil, detail: String? = nil, resetsAt: Date? = nil,
        fill: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.value = value
        self.detail = detail
        self.resetsAt = resetsAt
        self.fill = fill
    }
}

public enum DesktopPriorityState: String, Codable, Sendable {
    case disabled, waitingForUsage, noReportedLimits, unavailable, allClear, listed
}

public enum DesktopPrioritySection: String, Codable, Sendable {
    case pinned, runningOut, useItOrLoseIt, notice, waiting, usedUp
}

public struct DesktopWidgetPriority: Codable, Equatable, Sendable {
    public let state: DesktopPriorityState
    public let rows: [DesktopPriorityRow]
    public let showsClearRow: Bool

    public init(state: DesktopPriorityState, rows: [DesktopPriorityRow], showsClearRow: Bool = false) {
        self.state = state
        self.rows = rows
        self.showsClearRow = showsClearRow
    }
}

public struct DesktopPriorityRow: Codable, Equatable, Sendable {
    public let section: DesktopPrioritySection
    public let accountID: String
    public let metricID: String?
    public let title: String
    public let value: String?
    public let detail: String?
    public let estimatedExhaustionAt: Date?

    public func upcomingExhaustion(at date: Date) -> Date? {
        guard let estimatedExhaustionAt, date < estimatedExhaustionAt else { return nil }
        return estimatedExhaustionAt
    }

    public init(
        section: DesktopPrioritySection, accountID: String, metricID: String? = nil, title: String,
        value: String? = nil, detail: String? = nil, estimatedExhaustionAt: Date? = nil
    ) {
        self.section = section
        self.accountID = accountID
        self.metricID = metricID
        self.title = title
        self.value = value
        self.detail = detail
        self.estimatedExhaustionAt = estimatedExhaustionAt
    }
}
