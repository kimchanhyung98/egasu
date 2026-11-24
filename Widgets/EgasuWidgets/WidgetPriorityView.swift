import SwiftUI
import WidgetKit

struct WidgetPriorityView: View {
    let content: DesktopWidgetContent
    let date: Date
    let family: WidgetFamily

    var body: some View {
        let board = content.priority
        if board.state == .disabled {
            WidgetStateMessage(title: "Priority Is Off", detail: "Enable Show in Priority in Settings → Alerts.")
        } else if board.rows.isEmpty {
            WidgetStateMessage(title: emptyTitle)
        } else {
            let capacity = family == .systemSmall ? 1 : family == .systemLarge ? 4 : 2
            let rows = orderedRows
            VStack(alignment: .leading, spacing: 4) {
                ForEach(rows.prefix(capacity).indices, id: \.self) { index in
                    if let row = rows[index] {
                        WidgetAccountLink(accountID: row.accountID) { priorityRow(row) }
                    } else {
                        Text("No Matching Limits").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if rows.count > capacity {
                Text("Items +\(rows.count - capacity)").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var orderedRows: [DesktopPriorityRow?] {
        let board = content.priority
        var rows: [DesktopPriorityRow?] = board.rows
        if board.showsClearRow {
            let index = board.rows.prefix { $0.section == .pinned || $0.section == .runningOut }.count
            rows.insert(nil, at: index)
        }
        return rows
    }

    private var emptyTitle: LocalizedStringKey {
        switch content.priority.state {
        case .disabled: "Priority Is Off"
        case .waitingForUsage: "Waiting for Usage"
        case .noReportedLimits: "No Reported Limits"
        case .unavailable: "Usage Unavailable"
        case .allClear, .listed: "No Matching Limits"
        }
    }

    private func priorityRow(_ row: DesktopPriorityRow) -> some View {
        let account = content.accounts.first { $0.id == row.accountID }
        let reset = account?.metrics.first { $0.id == row.metricID }?.resetsAt
        return HStack(spacing: 6) {
            Capsule()
                .fill(row.section.tint)
                .frame(width: 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: family == .systemMedium ? 0 : 2) {
                HStack(spacing: 4) {
                    Text(row.section.title)
                    if family != .systemSmall, let account {
                        Spacer(minLength: 4)
                        WidgetProviderMark(id: account.providerID)
                        Text(verbatim: account.widgetName)
                    }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                HStack(spacing: 3) {
                    Text(verbatim: row.title).font(.callout.weight(.semibold))
                    Spacer(minLength: 1)
                    if let value = row.value {
                        Text(verbatim: value).font(.callout.weight(.semibold)).monospacedDigit()
                    }
                }
                .minimumScaleFactor(0.8)
                if family == .systemSmall, let account {
                    HStack(spacing: 3) {
                        WidgetProviderMark(id: account.providerID)
                        Text(verbatim: account.widgetName)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                HStack(spacing: 4) {
                    if let account { WidgetObservationState(account: account, date: date) }
                    if let forecast = row.upcomingExhaustion(at: date) {
                        Text("Out in \(Text(forecast, style: .relative))").font(.caption2).foregroundStyle(.secondary)
                    } else if let reset, reset <= date || row.detail == nil {
                        WidgetResetText(reset: reset, date: date)
                    } else if let detail = row.detail, !detail.isEmpty {
                        Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .lineLimit(1)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .privacySensitive()
    }
}

private extension DesktopPrioritySection {
    var title: LocalizedStringKey {
        switch self {
        case .pinned: "Pinned"
        case .runningOut: "Running Out"
        case .useItOrLoseIt: "Use It or Lose It"
        case .notice: "Needs Attention"
        case .waiting: "Waiting for Usage"
        case .usedUp: "Used Up"
        }
    }

    var tint: Color {
        switch self {
        case .pinned: .blue
        case .runningOut, .notice: .orange
        case .useItOrLoseIt: .teal
        case .waiting, .usedUp: .secondary
        }
    }
}
