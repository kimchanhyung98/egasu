import SwiftUI

struct SoftLimitAccountStatus: Identifiable {
    let id: String
    let name: String
    let quota: SoftLimitQuotaState
    let usedFraction: Double?
    let estimatedFraction: Double?
    let cancellation: SoftLimitProviderStatus
    var nextExpiry: Date?

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
    @State private var showsStatus = false
    @State private var lastExpiry = Date.distantPast
    @State private var confirmActivation = false

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
                        "Shows a guide on supported weekly and monthly quota bars. Automatic cancellation requires a verified connection to the same account."
                    ))
            }

            if settings.enabled {
                SettingsPicker(
                    L10n.settings("Window"), selection: $settings.window, options: SoftLimitWindowSelection.allCases
                ) {
                    $0.label
                }
                SoftLimitThresholdField(settings: settings)
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
}
