import AppKit
import KeyboardShortcuts
import SwiftUI

/// General 탭 — 앱 기본 동작·언어·모양, iCloud 동기화, 업데이트.
struct SettingsGeneralTab: View {
    @Environment(ICloudUsageSyncStore.self) private var iCloudSync
    @Environment(PopoverState.self) private var popover
    @Environment(UsageTimerSetting.self) private var usageTimerSetting
    @AppStorage(DashboardTab.defaultKey) private var defaultTab = DashboardTab.priority
    @AppStorage(LanguageSetting.key) private var language = LanguageSetting.current
    @AppStorage(AppearanceSetting.key) private var appearance = AppearanceSetting.system
    @AppStorage(TimeFormatSetting.key) private var timeFormat = TimeFormatSetting.fallback
    let launchAtLogin: LaunchAtLoginSetting
    let relauncher: AppRelauncher

    var body: some View {
        @Bindable var usageTimerSetting = usageTimerSetting
        Section {
            Toggle(
                L10n.settings("Launch at Login"),
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.update(to: $0) }
                ))
            Toggle(isOn: $usageTimerSetting.isEnabled) {
                SettingsTitle(
                    title: L10n.settings("Auto-Start Subscription Timers"),
                    info: L10n.settings(
                        "Sends a short request to start an unused subscription window for all supported accounts. The request can use some of your quota. Turning this off keeps usage updates on."
                    )
                )
            }
            SettingsPicker(L10n.settings("Default Tab"), selection: $defaultTab, options: DashboardTab.allCases) {
                $0.label
            }
            LabeledContent {
                SettingsShortcutRecorder(name: .togglePopover)
                    .disabled(!popover.popoverShown || popover.screen != .settings)
                    // 화면 이동이나 패널 닫힘 시 입력기를 교체해 녹화 종료 처리 실행.
                    .id(popover.popoverShown && popover.screen == .settings)
            } label: {
                SettingsTitle(title: L10n.settings("Global Shortcut"), info: L10n.settings("Open egasu from anywhere"))
            }
            LanguageSettingsRow(selection: $language, relauncher: relauncher)
        } footer: {
            if let errorMessage = launchAtLogin.errorMessage {
                SettingsNote(errorMessage)
            }
        }
        // 기본 탭을 바꾸면 지금 대시보드 탭도 바로 바꿈.
        .onChange(of: defaultTab) { _, tab in popover.dashboardTab = tab }
        .onChange(of: popover.screen, initial: true) { _, screen in
            if screen == .settings { launchAtLogin.refreshStatus() }
        }
        Section(L10n.settings("Appearance")) {
            SettingsPicker(L10n.settings("Theme"), selection: $appearance, options: AppearanceSetting.allCases) {
                $0.label
            }
            // 패널은 preferredColorScheme을 무시 — 앱 수준으로 적용.
            .onChange(of: appearance) { AppearanceSetting.applyCurrent() }
            SettingsPicker(L10n.settings("Time Format"), selection: $timeFormat, options: TimeFormatSetting.allCases) {
                $0.label
            }
        }
        ICloudSyncSettingsSection(sync: iCloudSync)
        SettingsUpdatesSection()
    }
}

/// 기본 단축키 입력기의 안내 문구를 앱 표시 언어로 맞춤.
struct SettingsShortcutRecorder: NSViewRepresentable {
    let name: KeyboardShortcuts.Name
    private let idleHint = L10n.settings("Record Shortcut")
    private let recordingHint = L10n.settings("Type Shortcut…")

    final class Coordinator {
        var placeholderObservation: NSKeyValueObservation?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> KeyboardShortcuts.RecorderCocoa {
        let recorder = KeyboardShortcuts.RecorderCocoa(for: name)
        let systemIdleHint = recorder.placeholderString
        let idleHint = idleHint
        let recordingHint = recordingHint
        recorder.placeholderString = idleHint
        // 입력기의 시작·종료에서 다시 설정하는 기본 문구를 같은 시점에 현지화.
        context.coordinator.placeholderObservation = recorder.observe(\.placeholderString, options: [.new]) {
            field, _ in
            MainActor.assumeIsolated {
                let hint = field.placeholderString
                guard hint != idleHint, hint != recordingHint else { return }
                field.placeholderString = hint == systemIdleHint ? idleHint : recordingHint
            }
        }
        return recorder
    }

    func updateNSView(_ recorder: KeyboardShortcuts.RecorderCocoa, context: Context) {
        recorder.shortcutName = name
        recorder.isEnabled = context.environment.isEnabled
    }
}

/// 업데이트 설정 — 피드가 없는 빌드에도 표시하며 확인 동작만 비활성.
struct SettingsUpdatesSection: View {
    @Environment(UpdaterController.self) private var updater

    var body: some View {
        @Bindable var updater = updater
        Section(L10n.settings("Updates")) {
            Toggle(L10n.settings("Check Automatically"), isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isActive)
            Toggle(isOn: $updater.betaChannelEnabled) {
                SettingsTitle(
                    title: L10n.settings("Beta Updates"),
                    info: L10n.settings("Shows the Labs tab and includes beta versions when checking for updates.")
                )
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.settings("Check for Updates…")) { updater.checkForUpdates() }
                    .disabled(!updater.canCheckForUpdates)
            }
        }
    }
}
