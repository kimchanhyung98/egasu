import AppKit
import SwiftUI

/// Advanced 탭 — 개인정보, Tokscale, 로그.
struct SettingsAdvancedTab: View {
    @Environment(AppContainer.self) private var container

    var body: some View {
        SettingsAdvancedSections(
            privacy: container.privacy, telemetry: container.telemetry, tokscaleSync: container.tokscaleSync)
    }
}

struct SettingsAdvancedSections: View {
    @Bindable var privacy: MenuBarPrivacyStore
    let telemetry: TelemetryRecorder
    let tokscaleSync: TokscaleSyncStore
    @AppStorage(LogLevelSetting.key) private var logLevel = LogLevelSetting.fallback
    @State private var logActionError: String?

    var body: some View {
        Section(L10n.settings("Privacy")) {
            Toggle(isOn: $privacy.hideUsageWhileScreenSharing) {
                SettingsTitle(
                    title: L10n.settings("Privacy Mode"),
                    info: L10n.settings(
                        "Hides dashboard account names and disables renaming. Dashboard account actions show masked emails. Accounts stays visible and editable. During screen sharing or recording, the menu bar shows only the egasu icon."
                    )
                )
            }
            Toggle(
                isOn: Binding(
                    get: { telemetry.isEnabled },
                    set: { telemetry.setEnabled($0) }
                )
            ) {
                SettingsTitle(
                    title: L10n.settings("Share Anonymous Usage"),
                    info: L10n.settings(
                        "Shares anonymous usage counts and error types to help improve egasu. No account details, credentials, or usage values are sent."
                    )
                )
            }
        }
        TokscaleSettingsSection(store: tokscaleSync)
        debugSection
    }

    /// 로그 수준은 재시작 없이 바로 적용·유지, 로그 파일 경로 복사·Finder에서 보기.
    private var debugSection: some View {
        Section {
            Picker(selection: $logLevel) {
                ForEach(LogLevelSetting.allCases, id: \.self) { Text($0.label).tag($0) }
            } label: {
                SettingsTitle(
                    title: L10n.settings("Log Level"),
                    info: L10n.settings(
                        "How much detail egasu writes to its log file. Choose Debug while you reproduce a problem.")
                )
            }
            .onChange(of: logLevel) {
                AppLog.reloadLevel()
                AppLog.info(.config, "Log level changed to \(logLevel.rawValue)")
            }
            HStack {
                Spacer(minLength: 0)
                Button(L10n.settings("Copy Log Path"), action: copyLogPath)
                Button(L10n.settings("Reveal in Finder")) {
                    NSWorkspace.shared.activateFileViewerSelecting([LogFile.url])
                    logActionError = nil
                }
            }
        } header: {
            Text(L10n.settings("Debug"))
        } footer: {
            if let logActionError {
                SettingsNote(logActionError)
            }
        }
    }

    private func copyLogPath() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(LogFile.url.path, forType: .string) else {
            logActionError = L10n.settings("Couldn't copy the log path to the clipboard.")
            AppLog.warn(.config, "Copy log path failed")
            return
        }
        logActionError = nil
    }
}
