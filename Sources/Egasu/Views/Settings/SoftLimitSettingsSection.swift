import SwiftUI

/// Soft Limit 실험 기능 설정 — 켜기 전 확인, 기준 기간·임계값, 취소 연결 상태와 연결 경고 툴팁.
struct SoftLimitSettingsSection: View {
    let settings: SoftLimitSettingsStore
    let coordinator: SoftLimitCoordinator
    let providers: [Provider]
    @State private var confirmActivation = false

    var body: some View {
        @Bindable var settings = settings
        let connectionWarning = L10n.settings(
            "The Codex cancellation connection has been tested, but automatic cancellation is unavailable until account scope is verified. Other Codex sessions and other providers are not protected yet."
        )
        Section {
            Toggle(
                L10n.settings("Enabled"),
                isOn: Binding(
                    get: { settings.enabled },
                    set: { if $0 { confirmActivation = true } else { settings.enabled = false } }
                )
            )
            .accessibilityLabel(L10n.settings("Enable Soft Limit"))
            .alert(L10n.settings("Enable Soft Limit?"), isPresented: $confirmActivation) {
                Button(L10n.settings("Enable"), role: .destructive) { settings.enabled = true }
                Button(L10n.settings("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    L10n.settings(
                        "Shows the limit guide and allows cancellation only for verified client/account connections. The current Codex connection is not account-verified and will not cancel tasks. Unconnected sessions and unsupported providers are not protected."
                    ))
            }

            if settings.enabled {
                Picker(L10n.settings("Window"), selection: $settings.window) {
                    ForEach(SoftLimitWindow.allCases, id: \.self) { window in
                        Text(window.label).tag(window)
                    }
                }
                SoftLimitThresholdField(settings: settings)
                DisclosureGroup(L10n.settings("Cancellation Status")) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(providers) { provider in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName).font(.caption.weight(.semibold))
                                Text(coordinator.status(for: provider.id).message)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
                }
            }
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L10n.settings("Start the local server, then open a Codex terminal connected to it:"))
                    Text("codex app-server daemon start\ncodex --remote unix://")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Text(
                        L10n.settings(
                            "Existing independent CLI, app, and IDE sessions are not connected automatically. egasu does not restart them."
                        ))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 8)
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.settings("Codex"))
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.notice)
                        .hoverTooltip(connectionWarning)
                        .accessibilityLabel(connectionWarning)
                }
            }
        } header: {
            Text(L10n.settings("Soft Limit"))
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                if settings.enabled {
                    SettingsNote(
                        L10n.settings(
                            "Uses fresh quota data after the next successful refresh. Cancellation requires a verified client/account connection and must preserve apps, terminals, and conversations."
                        ))
                    ForEach(providers.filter { coordinator.status(for: $0.id).phase == .failed }) { provider in
                        SettingsNote(
                            L10n.settings("%@: %@", provider.displayName, coordinator.status(for: provider.id).message))
                    }
                }
            }
        }
    }
}
