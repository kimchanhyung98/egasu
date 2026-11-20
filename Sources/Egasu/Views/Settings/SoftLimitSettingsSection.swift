import AppKit
import SwiftUI

struct SoftLimitAccountStatus: Identifiable {
    let id: String
    let name: String
    let quota: SoftLimitQuotaState
    let usedFraction: Double?
    let estimatedFraction: Double?
    let cancellation: SoftLimitProviderStatus
    var nextExpiry: Date?
    var supportsPreflight = false

    var usageLabel: String {
        switch quota {
        case .unknown:
            return estimatedFraction.map { L10n.settings("Estimated usage: %@", Self.percent($0)) }
                ?? L10n.settings("Quota not verified")
        case .belowLimit:
            return usedFraction.map { L10n.metrics("%@ used", Self.percent($0)) }
                ?? L10n.settings("Below the soft limit")
        case .reached:
            return usedFraction.map { L10n.settings("%@ used · Soft limit reached", Self.percent($0)) }
                ?? L10n.dashboard("Limit reached")
        }
    }

    private static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(0...1)).rounded(rule: .down).locale(L10n.locale))
    }
}

struct SoftLimitSettingsSection: View {
    let settings: SoftLimitSettingsStore
    let accounts: () -> [SoftLimitAccountStatus]
    let commandLineTool: CommandLineToolInstaller
    @State private var showsStatus = false
    @State private var lastExpiry = Date.distantPast
    @State private var confirmActivation = false
    @State private var commandCopied: Bool?

    var body: some View {
        @Bindable var settings = settings
        let accounts = settings.isActive ? self.accounts() : []
        let nextExpiry = showsStatus ? accounts.compactMap(\.nextExpiry).filter { $0 > lastExpiry }.min() : nil
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
                Button(L10n.settings("Enable")) { settings.enabled = true }
                Button(L10n.settings("Cancel"), role: .cancel) {}
            } message: {
                Text(
                    L10n.settings(
                        "Shows a guide on weekly and monthly quota bars. Use a copied command to check the limit before starting a new CLI session."
                    ))
            }

            if settings.enabled {
                SettingsPicker(
                    L10n.settings("Window"), selection: $settings.window, options: SoftLimitWindowSelection.allCases
                ) {
                    $0.label
                }
                SoftLimitThresholdField(settings: settings)
                terminalCommands(
                    for: accounts.filter {
                        $0.supportsPreflight && !ProviderAccountID.isAccountCard($0.id)
                    })
                DisclosureGroup(L10n.settings("Quota Status"), isExpanded: $showsStatus) {
                    VStack(alignment: .leading, spacing: 8) {
                        if accounts.isEmpty {
                            Text(L10n.settings("No enabled accounts support this period."))
                        } else {
                            let guidesOnly = accounts.allSatisfy { $0.cancellation.phase == .unsupported }
                            ForEach(accounts) { account in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(account.name)
                                        .fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(account.usageLabel)
                                    if !guidesOnly && account.cancellation.phase != .failed {
                                        Text(account.cancellation.message)
                                    }
                                }
                                .accessibilityElement(children: .combine)
                            }
                            if guidesOnly {
                                Text(L10n.settings("Automatic cancellation is unavailable for these accounts."))
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }
            }
        } header: {
            Text(L10n.settings("Soft Limit"))
        } footer: {
            if settings.enabled {
                if commandCopied == false { SettingsNote(L10n.settings("Couldn't copy the terminal command.")) }
                ForEach(accounts.filter { $0.cancellation.phase == .failed }) { account in
                    SettingsNote(L10n.settings("%@: %@", account.name, account.cancellation.message))
                }
            }
        }
        .task(id: nextExpiry) {
            guard let nextExpiry else { return }
            do { try await Task.sleep(for: .seconds(max(0, nextExpiry.timeIntervalSinceNow))) } catch { return }
            lastExpiry = nextExpiry
        }
    }

    @ViewBuilder
    private func terminalCommands(for accounts: [SoftLimitAccountStatus]) -> some View {
        if !accounts.isEmpty {
            LabeledContent {
                if let helper = commandLineTool.bundledExecutablePath {
                    let commands = accounts.compactMap { account in
                        SoftLimitTerminalCommand(helperPath: helper, cardID: account.id).map { (account, $0) }
                    }
                    let launchCommands = commands.compactMap { account, command in
                        command.launch.map { (account, $0) }
                    }
                    Menu(L10n.settings(commandCopied == true ? "Copied" : "Copy Command")) {
                        if !launchCommands.isEmpty {
                            Section(L10n.settings("Start CLI")) {
                                ForEach(launchCommands, id: \.0.id) { account, launch in
                                    Button(account.name) { copyCommand(launch) }
                                }
                            }
                        }
                        Section(L10n.settings("Check Quota")) {
                            ForEach(commands, id: \.0.id) { account, command in
                                Button(account.name) { copyCommand(command.check) }
                            }
                        }
                    }
                } else {
                    Text(L10n.settings("Unavailable")).foregroundStyle(.secondary)
                }
            } label: {
                SettingsTitle(
                    title: L10n.settings("Terminal Commands"),
                    info: L10n.settings(
                        "Paste the command in Terminal. A new session starts only if the quota check allows it.")
                )
            }
        }
    }

    private func copyCommand(_ command: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        commandCopied = pasteboard.setString(command, forType: .string)
    }
}
