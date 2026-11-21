import SwiftUI

struct SettingsLabsTab: View {
    @Environment(AppContainer.self) private var container
    let commandLineTool: CommandLineToolInstaller

    var body: some View {
        SettingsLabsSections(
            settings: container.softLimitSettings,
            accounts: { quotaAccounts },
            commandLineTool: commandLineTool
        )
    }

    private var quotaAccounts: [SoftLimitAccountStatus] {
        let registry = container.registry
        let selection = container.softLimitSettings.window
        let cardIDs = container.orderedAccountCardIDs(registry.providers.map(\.id))
        let now = Date()
        return cardIDs.compactMap { cardID in
            guard container.enablement.isEnabled(cardID), let provider = registry.provider(id: cardID) else {
                return nil
            }
            let descriptors = registry.descriptors(for: cardID).filter {
                $0.softLimitWindows.contains(where: selection.includes)
            }
            guard !descriptors.isEmpty else { return nil }
            let coordinator = container.softLimitCoordinator
            let reading = coordinator.quotaReading(for: cardID)
            let estimateExpiry: Date?
            if case .succeeded? = container.dataStore.refreshResults[cardID],
                let snapshot = container.dataStore.localSnapshots[cardID], snapshot.freshnessDate <= now
            {
                let expiry = snapshot.freshnessDate.addingTimeInterval(RefreshSetting.interval(for: cardID))
                estimateExpiry = expiry > now ? expiry : nil
            } else {
                estimateExpiry = nil
            }
            let estimate =
                reading.state == .unknown && estimateExpiry != nil
                ? descriptors.compactMap { descriptor -> Double? in
                    guard let line = container.dataStore.localSnapshots[cardID]?.line(label: descriptor.metricLabel),
                          descriptor.limitResources.contains(where: { $0.kind == .consumption && $0.estimated && $0.matches(line) }) else {
                        return nil
                    }
                    let data = container.dataStore.data(for: descriptor)
                    guard data.softLimitMarkerFraction != nil, let limit = data.limit, data.used.isFinite,
                        data.used >= 0
                    else { return nil }
                    let fraction = data.used / limit
                    return fraction.isFinite ? fraction : nil
                }.max() : nil
            return SoftLimitAccountStatus(
                id: cardID,
                name: container.dataStore.resolveDisplayName?(cardID) ?? container.displayName(for: provider),
                quota: reading.state, usedFraction: reading.usedFraction,
                estimatedFraction: estimate, cancellation: coordinator.status(for: cardID),
                nextExpiry: estimate == nil ? reading.nextExpiry : estimateExpiry,
                supportsPreflight: descriptors.contains { $0.hasMeasuredSoftLimit(in: selection) }
            )
        }
    }
}

struct SettingsLabsSections: View {
    let settings: SoftLimitSettingsStore
    let accounts: () -> [SoftLimitAccountStatus]
    let commandLineTool: CommandLineToolInstaller

    var body: some View {
        Text(L10n.settings("Experimental features may change or be removed."))
            .font(.caption)
            .foregroundStyle(.secondary)
        SoftLimitSettingsSection(settings: settings, accounts: accounts, commandLineTool: commandLineTool)
        TerminalHelperSettingsSection(commandLineTool: commandLineTool)
    }
}
