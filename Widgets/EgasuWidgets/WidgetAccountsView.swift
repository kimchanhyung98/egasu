import SwiftUI
import WidgetKit

struct WidgetAccountsView: View {
    let content: DesktopWidgetContent
    let selections: [DesktopWidgetSelection]
    let date: Date
    let family: WidgetFamily

    var body: some View {
        let page = content.selectedAccounts(
            selections, maximumAccounts: family == .systemLarge ? 3 : 2,
            maximumMetrics: family == .systemSmall ? 1 : 2
        )
        if page.accounts.isEmpty {
            WidgetStateMessage(title: "Select Account Metrics", detail: "Edit this widget to choose what to display.")
        } else {
            let layout =
                family == .systemMedium
                ? AnyLayout(HStackLayout(alignment: .top, spacing: 12))
                : AnyLayout(VStackLayout(alignment: .leading, spacing: family == .systemLarge ? 10 : 2))
            layout {
                ForEach(page.accounts) { slot in
                    WidgetAccountLink(accountID: slot.id) { accountView(slot) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            if page.remainingAccounts > 0 || page.remainingMetrics > 0 {
                HStack(spacing: 6) {
                    if page.remainingAccounts > 0 { Text("Accounts +\(page.remainingAccounts)") }
                    if page.remainingMetrics > 0 { Text("Metrics +\(page.remainingMetrics)") }
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func accountView(_ slot: DesktopSelectedAccount) -> some View {
        if let account = slot.account, account.state != .unavailable {
            let state = account.state(at: date)
            let reported = slot.metrics.filter { $0.value != nil || $0.detail != nil }
            VStack(alignment: .leading, spacing: family == .systemSmall ? 0 : 2) {
                HStack(spacing: 4) {
                    WidgetProviderMark(id: account.providerID)
                    Text(verbatim: account.widgetName)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    if family == .systemLarge {
                        Spacer(minLength: 3)
                        WidgetObservationState(account: account, date: date)
                    }
                }
                if state == .waiting {
                    Text("Waiting for Usage").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(reported) { metric in
                        metricLine(metric, showsDetail: family == .systemLarge || state == .current)
                    }
                    if reported.isEmpty && state == .current {
                        Text("No Visible Metrics").font(.caption).foregroundStyle(.secondary)
                    }
                    if family != .systemLarge { WidgetObservationState(account: account, date: date) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .privacySensitive()
        } else {
            Label("Account Unavailable", systemImage: "person.crop.circle.badge.questionmark")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func metricLine(_ metric: DesktopWidgetMetric, showsDetail: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 3) {
                Text(verbatim: metric.name).font(.caption)
                Spacer(minLength: 1)
                if family == .systemLarge { metricDetail(metric) }
                Text(verbatim: metric.value ?? "—")
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
                    .layoutPriority(1)
            }
            .lineLimit(1)
            if family != .systemSmall, let fill = metric.fill {
                GeometryReader { geometry in
                    Capsule().fill(.quaternary).overlay(alignment: .leading) {
                        Capsule().fill(.tint).frame(width: geometry.size.width * fill)
                    }
                }
                .frame(height: 2)
                .padding(.vertical, 2)
                .accessibilityHidden(true)
            }
            if showsDetail && family != .systemLarge { metricDetail(metric) }
        }
    }

    @ViewBuilder private func metricDetail(_ metric: DesktopWidgetMetric) -> some View {
        if let reset = metric.resetsAt {
            WidgetResetText(reset: reset, date: date)
        } else if let detail = metric.detail, !detail.isEmpty {
            Text(verbatim: detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

struct WidgetResetText: View {
    let reset: Date
    let date: Date

    var body: some View {
        Group {
            if reset <= date {
                Text("Reset Due")
            } else {
                Text("Resets in \(Text(reset, style: .relative))")
            }
        }
        .lineLimit(1)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}

struct WidgetObservationState: View {
    let account: DesktopWidgetAccount
    let date: Date

    var body: some View {
        let state = account.state(at: date)
        if state == .stale || state == .failed {
            HStack(spacing: 3) {
                Text(state == .stale ? LocalizedStringKey("Stale") : LocalizedStringKey("Refresh Failed"))
                if let observedAt = account.observedAt {
                    Text("\(Text(observedAt, style: .relative)) ago")
                }
            }
            .font(.caption2)
            .lineLimit(1)
            .foregroundStyle(.secondary)
        }
    }
}
