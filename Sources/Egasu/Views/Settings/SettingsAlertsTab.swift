import AppKit
import SwiftUI

/// Alerts 탭 — 경고 기준·Priority 표시 조건, 사용량 알림 4종, Codex Reset Watch.
/// 알림을 하나라도 켰는데 macOS 권한이 없으면 마지막 행에 안내와 권한 버튼.
struct SettingsAlertsTab: View {
    @Environment(AppContainer.self) private var container
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(PopoverState.self) private var popover
    @State private var authorization: Authorization = .authorized

    private enum Authorization { case authorized, denied, notDetermined }

    var body: some View {
        @Bindable var display = dataStore.displaySettings
        @Bindable var notifications = container.notificationSettings
        Section(L10n.settings("Thresholds")) {
            levelPicker(
                L10n.settings("Warning"), info: L10n.settings("When a limit turns into a priority"), severity: .warning,
                selection: $display.priorityLimits.warning, options: PriorityLimits.warningOptions
            )
            levelPicker(
                L10n.settings("Critical"), info: L10n.settings("When a limit turns critically low"),
                severity: .critical,
                selection: $display.priorityLimits.critical, options: PriorityLimits.criticalOptions
            )
        }
        SettingsAlertConditionsSection(display: display, notifications: notifications)
        Section {
            Toggle(isOn: $notifications.codexResetWatch) {
                SettingsTitle(
                    title: CodexResetWatchNotificationEvaluator.settingLabel,
                    info: L10n.settings("Alert when Reset Watch expects Codex limits to reset soon")
                )
            }
            if notifications.anyEnabled, authorization != .authorized {
                permissionNotice
            }
        } header: {
            Text(L10n.settings("Other Notifications"))
        }
        .onChange(of: notifications.anyEnabled) { _, isOn in
            // 첫 알림을 켤 때 권한 요청(미결정일 때만 묻는 창) 후 상태 갱신.
            if isOn {
                Self.requestAuthorization { await refreshAuthorization() }
            } else {
                Task { await refreshAuthorization() }
            }
        }
        .onChange(of: popover.screen) { _, screen in
            if screen == .settings { Task { await refreshAuthorization() } }
        }
        .task { await refreshAuthorization() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshAuthorization() }
        }
    }

    private func levelPicker(
        _ title: String, info: String, severity: WidgetData.MeterSeverity, selection: Binding<Int>, options: [Int]
    ) -> some View {
        Picker(selection: selection) {
            ForEach(options, id: \.self) { Text(L10n.settings("%lld%% left", $0)).tag($0) }
        } label: {
            limitLabel(title, info: info) {
                Circle().fill(Theme.severityColor(severity)).frame(width: 8, height: 8)
            }
        }
    }

    /// Priority 기준 행 라벨 — 표시 기호, 제목, ⓘ.
    private func limitLabel(_ title: String, info: String, @ViewBuilder mark: () -> some View) -> some View {
        HStack(spacing: 8) {
            mark().frame(width: 8)
            SettingsTitle(title: title, info: info)
        }
    }

    /// 거부면 시스템 설정의 egasu 알림 페이지를 열고 패널을 닫음, 미결정이면 권한 요청.
    @ViewBuilder
    private var permissionNotice: some View {
        if authorization == .denied {
            Button {
                AppNotifications.shared.openSystemNotificationsSettings()
                MenuBarPopover.dismiss(fallback: nil)
            } label: {
                Self.notificationsOffText
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.notice)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 6) {
                SettingsNote(L10n.settings("egasu needs permission to send alerts."))
                Button(L10n.settings("Allow Notifications")) {
                    Self.requestAuthorization { await refreshAuthorization() }
                }
            }
        }
    }

    /// "…in **System Settings**." — 언어마다 링크 위치가 달라 `%@` 자리에 강조색 링크 문구를 끼움.
    static var notificationsOffText: Text {
        let parts = L10n.settings("Notifications are off for egasu in %@.").components(separatedBy: "%@")
        let link = Text(L10n.settings("System Settings")).foregroundColor(.accentColor)
        guard parts.count == 2 else { return Text(parts.joined()) + link }
        return Text(parts[0]) + link + Text(parts[1])
    }

    /// 공유 권한 요청의 응답을 기다린 뒤 현재 설정에 맞춰 안내 갱신.
    @discardableResult
    static func requestAuthorization(
        request: () -> Task<Bool, Never> = { AppNotifications.shared.requestAuthorization() },
        refresh: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let response = request()
        return Task {
            _ = await response.value
            await refresh()
        }
    }

    private func refreshAuthorization() async {
        guard container.notificationSettings.anyEnabled else {
            authorization = .authorized
            return
        }
        switch await AppNotifications.shared.authorizationStatus() {
        case .denied: authorization = .denied
        case .notDetermined: authorization = .notDetermined
        default: authorization = .authorized
        }
    }
}

/// 조건별 Priority 표시와 macOS 알림을 독립 설정.
struct SettingsAlertConditionsSection: View {
    @Bindable var display: DisplaySettingsStore
    @Bindable var notifications: NotificationSettingsStore

    private let columnWidth: CGFloat = 72

    var body: some View {
        Section {
            conditionRow(
                L10n.settings("Warning"), info: L10n.settings("When a limit turns into a priority"),
                shown: nil, notify: $notifications.warning
            ) {
                Circle().fill(Theme.severityColor(.warning)).frame(width: 8, height: 8)
            }
            conditionRow(
                L10n.settings("Critical"), info: L10n.settings("When a limit turns critically low"),
                shown: nil, notify: $notifications.critical
            ) {
                Circle().fill(Theme.severityColor(.critical)).frame(width: 8, height: 8)
            }
            conditionRow(
                L10n.dashboard("Burning Fast"), info: L10n.settings("Will run out before it resets"),
                shown: $display.showsBurningFast, notify: $notifications.closeToRunningOut
            ) {
                Image(systemName: "flame.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.severityColor(.warning))
            }
            conditionRow(
                L10n.dashboard("Use It or Lose It"), info: L10n.settings("Over 50% left a day before its reset"),
                shown: $display.showsUseItOrLoseIt, notify: $notifications.useItOrLoseIt
            ) {
                Image(systemName: "hourglass.tophalf.filled")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.severityColor(.normal))
            }
        } header: {
            HStack(spacing: 8) {
                Text(L10n.settings("Condition"))
                    .frame(maxWidth: .infinity, alignment: .leading)
                columnTitle("Show in Priority")
                columnTitle("Receive Alerts")
            }
            .font(.system(size: 11))
            .textCase(nil)
        }
    }

    private func columnTitle(_ key: String) -> some View {
        Text(L10n.settings(key))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: columnWidth)
    }

    private func conditionRow(
        _ title: String, info: String, shown: Binding<Bool>?, notify: Binding<Bool>,
        @ViewBuilder mark: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                mark().frame(width: 8)
                SettingsTitle(title: title, info: info)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                if let shown {
                    conditionToggle(title, column: "Show in Priority", isOn: shown)
                } else {
                    Text(L10n.settings("Always Shown"))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(Text("\(title), \(L10n.settings("Always Shown"))"))
                }
            }
            .frame(width: columnWidth)
            conditionToggle(title, column: "Receive Alerts", isOn: notify)
                .frame(width: columnWidth)
        }
    }

    private func conditionToggle(_ title: String, column: String, isOn: Binding<Bool>) -> some View {
        Toggle("\(title), \(L10n.settings(column))", isOn: isOn)
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
}
