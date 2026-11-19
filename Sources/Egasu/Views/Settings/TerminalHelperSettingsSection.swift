import AppKit
import SwiftUI

struct TerminalHelperSettingsSection: View {
    @Bindable var commandLineTool: CommandLineToolInstaller

    var body: some View {
        Section {
            LabeledContent {
                if commandLineTool.isVerifying {
                    Text(L10n.settings("Verifying…"))
                        .foregroundStyle(.secondary)
                } else {
                    switch commandLineTool.status {
                    case .installed:
                        Button(L10n.settings("Uninstall")) { commandLineTool.isConfirmingRemoval = true }
                    case .notInstalled:
                        Button(L10n.settings("Install…")) { Task { await commandLineTool.install() } }
                    case .conflict:
                        Text(L10n.settings("Unavailable"))
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                SettingsTitle(
                    title: L10n.settings("Terminal Helper"),
                    info: L10n.settings("Adds a global egasu command agents can use to monitor limits.")
                )
            }
        } header: {
            Text(L10n.settings("Command Line"))
        } footer: {
            if let errorMessage = commandLineTool.errorMessage {
                SettingsNote(errorMessage)
            } else if commandLineTool.status == .conflict {
                SettingsNote(
                    L10n.settings("%@ already exists and wasn't installed by egasu.", commandLineTool.destinationPath))
            }
        }
        .alert(L10n.settings("Remove Terminal Helper?"), isPresented: $commandLineTool.isConfirmingRemoval) {
            Button(L10n.settings("Remove"), role: .destructive) { commandLineTool.uninstall() }
            Button(L10n.settings("Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.settings("The egasu command will no longer work in Terminal."))
        }
        .onAppear { commandLineTool.refreshStatus() }
        .onDisappear { commandLineTool.isConfirmingRemoval = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            commandLineTool.refreshStatus()
        }
    }
}
