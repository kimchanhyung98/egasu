import SwiftUI

/// Display 탭 — 메뉴 막대, All Usage 레이아웃, 사용량 표시.
struct SettingsDisplayTab: View {
    @Environment(WidgetDataStore.self) private var dataStore
    @AppStorage(TotalSpendSetting.key) private var showTotalSpend = true

    var body: some View {
        @Bindable var store = dataStore
        @Bindable var display = dataStore.displaySettings
        Section {
            PriorityIconsPreview()
            SettingsPicker(
                L10n.settings("Icon Style"), selection: $display.menuBarStyle, options: MenuBarStyle.allCases
            ) { $0.label }
            .disabled(display.menuBarLimit == .iconOnly)
            SettingsPicker(
                L10n.settings("Max Items In Menu Bar"), selection: $display.menuBarLimit, options: MenuBarLimit.allCases
            ) { $0.label }
            SettingsPicker(
                L10n.settings("Menu Bar Items"), selection: $display.menuBarSelection,
                options: MenuBarSelection.allCases,
                info: L10n.settings(
                    "Choose Priority or Pinned Only, then pin metrics in All Usage to show them in the menu bar.")
            ) { $0.label }
            .disabled(display.menuBarLimit == .iconOnly)
            Toggle(isOn: $display.showsMenuBarExtras) {
                SettingsTitle(
                    title: L10n.settings("Show Extra Indicators"),
                    info: L10n.settings("Show the +N count and update indicator in the menu bar")
                )
            }
        } header: {
            Text(L10n.settings("Menu Bar Icons"))
        }
        Section(L10n.settings("Appearance")) {
            SettingsPicker(
                L10n.settings("All Usage Layout"), selection: $display.dashboardLayout,
                options: DashboardLayoutStyle.allCases
            ) { $0.label }
        }
        Section(L10n.settings("Usage")) {
            SettingsPicker(
                L10n.settings("Show Usage As"), selection: $store.meterStyle, options: WidgetDisplayMode.allCases
            ) { $0.label }
            SettingsPicker(
                L10n.settings("Reset Times"), selection: $store.resetDisplayMode, options: ResetDisplayMode.allCases
            ) { $0.label }
            Toggle(isOn: $display.showsPaceMarks) {
                SettingsTitle(
                    title: L10n.settings("Pace Marks"), info: L10n.settings("Where usage would be at an even pace"))
            }
            Toggle(isOn: $showTotalSpend) {
                SettingsTitle(
                    title: L10n.settings("Show Total Spend"),
                    info: L10n.settings("Combined spend across your providers at the top of the dashboard")
                )
            }
        }
    }
}

/// 메뉴 막대 미리보기 — 고른 개수만큼 샘플 항목, 지금 소진 중인 지표와 무관하게 선택지마다 다르게 보임.
struct PriorityIconsPreview: View {
    @Environment(WidgetDataStore.self) private var dataStore

    private static let height: CGFloat = 30
    private static let scale: CGFloat = 0.8
    private static let samples: [(provider: String, badge: String?, label: String, value: String, fraction: Double)] = [
        ("claude", "P", "Weekly", "38%", 0.38), ("claude", "A1", "Session", "26%", 0.26),
        ("codex", nil, "Weekly", "31%", 0.31),
        ("cursor", nil, "Extra Usage", "$310", 0.62),
        ("antigravity", nil, AntigravityMetric.sessionLabel, "12%", 0.12),
        ("grok", nil, "Weekly", "9%", 0.09),
        ("copilot", nil, "Credits", "7%", 0.07)
    ]

    static func sample(limit: MenuBarLimit) -> MenuBarContent {
        guard limit != .iconOnly else { return MenuBarContent(items: []) }
        let shown = samples.prefix(limit.count).enumerated().map { index, sample in
            let label = L10n.metrics(sample.label)
            return MenuBarContent.Item(
                id: "sample.\(index)", icon: .providerMark(sample.provider), providerName: sample.provider,
                badge: sample.badge, label: label,
                shortLabel: MenuBarContentBuilder.shortLabel(label, metricLabel: sample.label),
                value: sample.value, fraction: sample.fraction
            )
        }
        return MenuBarContent(items: shown, overflow: samples.count - shown.count)
    }

    var body: some View {
        let content = Self.sample(limit: dataStore.displaySettings.menuBarLimit)
            .showingExtraIndicators(dataStore.displaySettings.showsMenuBarExtras)
        Color.primary
            .frame(height: Self.height)
            .mask {
                Group {
                    if content.isEmpty {
                        Image(nsImage: MenuBarStripRenderer.appIcon)
                    } else {
                        switch dataStore.displaySettings.menuBarStyle {
                        case .text:
                            MenuBarTextStrip(content: content)
                        case .bars:
                            MenuBarBarsStrip(content: content, fractions: content.items.compactMap(\.fraction))
                        }
                    }
                }
                .scaleEffect(Self.scale)
            }
            .accessibilityLabel(L10n.settings("Menu Bar Preview"))
    }
}
