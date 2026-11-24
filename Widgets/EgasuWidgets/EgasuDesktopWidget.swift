import SwiftUI
import WidgetKit

@main
struct EgasuDesktopWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: DesktopWidgetStore.kind, intent: ConfigureUsageWidget.self, provider: UsageWidgetProvider()
        ) { entry in
            UsageWidgetView(entry: entry)
        }
        .configurationDisplayName("egasu")
        .description("Show priority limits or the account metrics you choose.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct UsageWidgetView: View {
    @Environment(\.locale) private var locale
    @Environment(\.widgetFamily) private var family
    let entry: UsageWidgetEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                WidgetProviderMark(id: "egasu")
                Text(entry.mode == .priority ? LocalizedStringKey("Priority") : LocalizedStringKey("All Usage"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if entry.isPlaceholder {
                WidgetStateMessage(title: "Waiting for Usage")
                    .redacted(reason: .placeholder)
            } else {
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.locale, widgetLocale)
        .containerBackground(.background, for: .widget)
        .widgetURL(destination.widgetURL)
    }

    @ViewBuilder private var content: some View {
        switch entry.read {
        case .snapshot(let snapshot):
            switch entry.mode {
            case .priority:
                WidgetPriorityView(content: snapshot.content, date: entry.date, family: family)
            case .allUsage:
                WidgetAccountsView(
                    content: snapshot.content, selections: entry.selections, date: entry.date, family: family)
            }
        case .missing:
            WidgetStateMessage(title: "Waiting for Usage", detail: "Open egasu to load usage.")
        case .unsupportedVersion:
            WidgetStateMessage(title: "Usage Unavailable", detail: "Update egasu to display this widget.")
        case .unreadable:
            WidgetStateMessage(title: "Unable to Read Usage", detail: "Open egasu to refresh usage.")
        }
    }

    private var destination: DesktopWidgetDestination {
        if entry.mode == .allUsage { return .allUsage }
        if case .snapshot(let snapshot) = entry.read, snapshot.content.priority.state == .disabled { return .alerts }
        return .priority
    }

    private var widgetLocale: Locale {
        if case .snapshot(let snapshot) = entry.read { return Locale(identifier: snapshot.content.language) }
        return locale
    }
}

extension DesktopWidgetDestination {
    var widgetURL: URL? {
        guard let scheme = Bundle.main.object(forInfoDictionaryKey: "EgasuWidgetURLScheme") as? String else {
            return nil
        }
        return url(scheme: scheme)
    }
}

struct WidgetProviderMark: View {
    let id: String

    var body: some View {
        Group {
            if let url = Bundle.main.url(forResource: id, withExtension: "svg", subdirectory: "ProviderIcons"),
                let image = NSImage(contentsOf: url)
            {
                Image(nsImage: image).renderingMode(.template).resizable().scaledToFit()
            } else {
                Image(systemName: "square.grid.2x2")
            }
        }
        .frame(width: 13, height: 13)
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

struct WidgetStateMessage: View {
    let title: LocalizedStringKey
    var detail: LocalizedStringKey?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout.weight(.semibold))
            if let detail { Text(detail).font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct WidgetAccountLink<Content: View>: View {
    @Environment(\.widgetFamily) private var family
    let accountID: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        if family != .systemSmall, let url = DesktopWidgetDestination.account(accountID).widgetURL {
            Link(destination: url, label: content)
                .buttonStyle(.plain)
        } else {
            content()
        }
    }
}

extension DesktopWidgetAccount {
    var widgetName: String { name == providerName ? name : "\(providerName) · \(name)" }
}
