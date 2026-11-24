import Foundation
import WidgetKit

struct UsageWidgetEntry: TimelineEntry {
    let date: Date
    let mode: UsageWidgetMode
    let selections: [DesktopWidgetSelection]
    let read: DesktopWidgetRead
    let isPlaceholder: Bool
}

struct UsageWidgetProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageWidgetEntry {
        UsageWidgetEntry(date: .now, mode: .priority, selections: [], read: .missing, isPlaceholder: true)
    }

    func snapshot(for configuration: ConfigureUsageWidget, in context: Context) async -> UsageWidgetEntry {
        if context.isPreview { return galleryEntry(mode: configuration.mode, at: .now) }
        return currentEntry(for: configuration)
    }

    func timeline(for configuration: ConfigureUsageWidget, in context: Context) async -> Timeline<UsageWidgetEntry> {
        timeline(startingWith: currentEntry(for: configuration))
    }

    private func currentEntry(for configuration: ConfigureUsageWidget) -> UsageWidgetEntry {
        UsageWidgetEntry(
            date: .now, mode: configuration.mode,
            selections: (configuration.items ?? []).compactMap { DesktopWidgetSelection(id: $0.id) },
            read: DesktopWidgetStore().read(), isPlaceholder: false
        )
    }

    func timeline(startingWith current: UsageWidgetEntry) -> Timeline<UsageWidgetEntry> {
        guard case .snapshot(let snapshot) = current.read else {
            return Timeline(entries: [current], policy: .after(current.date.addingTimeInterval(15 * 60)))
        }

        let transitions: [Date]
        switch current.mode {
        case .priority:
            transitions = snapshot.content.priorityTimelineDates(after: current.date)
        case .allUsage:
            let scope = Dictionary(grouping: current.selections, by: \.accountID)
                .mapValues { Set($0.map(\.metricID)) }
            transitions = snapshot.content.timelineDates(after: current.date, including: scope)
        }
        let scheduled = transitions.prefix(16)
        let future = scheduled.map { date in
            UsageWidgetEntry(
                date: date, mode: current.mode, selections: current.selections, read: current.read, isPlaceholder: false
            )
        }
        // 남은 시점이 있으면 마지막 엔트리에서 이어서 예약. 새 관측값은 호스트가 게시.
        return Timeline(entries: [current] + future, policy: scheduled.count < transitions.count ? .atEnd : .never)
    }

    private func galleryEntry(mode: UsageWidgetMode, at date: Date) -> UsageWidgetEntry {
        let personalID = DesktopWidgetAccountID.profile(providerID: "codex", profileID: "example-personal")
        let workID = DesktopWidgetAccountID.profile(providerID: "codex", profileID: "example-work")
        let weekly = String(localized: "Weekly")
        let session = String(localized: "Session")
        let personal = DesktopWidgetAccount(
            id: personalID, providerID: "codex", providerName: "Codex", name: String(localized: "Personal"),
            state: .current, observedAt: date,
            metrics: [
                DesktopWidgetMetric(id: "weekly", name: weekly, value: "74%", fill: 0.74),
                DesktopWidgetMetric(id: "session", name: session, value: "91%", fill: 0.91)
            ]
        )
        let work = DesktopWidgetAccount(
            id: workID, providerID: "codex", providerName: "Codex", name: String(localized: "Work"),
            state: .current, observedAt: date,
            metrics: [DesktopWidgetMetric(id: "weekly", name: weekly, value: "48%", fill: 0.48)]
        )
        let priority = DesktopWidgetPriority(
            state: .listed,
            rows: [
                DesktopPriorityRow(
                    section: .pinned, accountID: personalID, metricID: "weekly", title: weekly, value: "74%"),
                DesktopPriorityRow(
                    section: .runningOut, accountID: personalID, metricID: "session", title: session, value: "91%"),
                DesktopPriorityRow(
                    section: .useItOrLoseIt, accountID: workID, metricID: "weekly", title: weekly, value: "48%")
            ])
        let content = DesktopWidgetContent(
            accounts: [personal, work], priority: priority, language: Bundle.main.preferredLocalizations.first ?? "en"
        )
        return UsageWidgetEntry(
            date: date, mode: mode, selections: [DesktopWidgetSelection(accountID: workID, metricID: "weekly")],
            read: .snapshot(DesktopWidgetSnapshot(content: content, generatedAt: date)), isPlaceholder: false
        )
    }
}
