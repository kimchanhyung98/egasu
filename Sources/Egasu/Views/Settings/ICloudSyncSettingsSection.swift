import SwiftUI

/// iCloud 동기화 설정 — 기기별 마지막 갱신 시각과 하단 오류 표시.
struct ICloudSyncSettingsSection: View {
    @Bindable var sync: ICloudUsageSyncStore

    var body: some View {
        Section {
            Toggle(isOn: $sync.enabled) {
                HStack(spacing: 7) {
                    SettingsTitle(
                        title: L10n.settings("Sync Across Macs"),
                        info: L10n.settings("Shares usage history through iCloud, so you can see one combined summary for all your Macs.")
                    )
                    if sync.enabled, sync.isSyncing, sync.serviceError == nil {
                        ProgressView()
                            .controlSize(.small)
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                            .accessibilityLabel(L10n.settings("Syncing usage history"))
                    }
                }
                .animation(Motion.spring, value: sync.isSyncing)
            }
            if sync.enabled {
                enabledContent
            }
        } header: {
            SettingsTitle(
                title: L10n.settings("iCloud Sync"),
                info: L10n.settings("egasu calculates costs and tokens for Claude, Codex, and other providers from files stored on each Mac. Account limits, credentials, and logs are never shared.")
            )
        } footer: {
            if let error = sync.enabled ? sync.serviceError : sync.deletionError {
                SettingsNote(error)
            }
        }
    }

    @ViewBuilder
    private var enabledContent: some View {
        if sync.displayedDocuments.isEmpty, !sync.isSyncing, sync.serviceError == nil {
            Text(L10n.settings("Waiting for this Mac’s first iCloud update…"))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            ForEach(sync.displayedDocuments) { document in
                deviceRow(document, isThisMac: document.deviceID == sync.deviceID)
            }
        }
    }

    private func deviceRow(_ document: UsageHistoryDocument, isThisMac: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isThisMac ? "laptopcomputer" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(document.deviceName)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if isThisMac {
                        Text(L10n.settings("This Mac"))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.secondary.opacity(0.12), in: Capsule())
                            .fixedSize()
                    }
                }
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    Text(L10n.settings("Updated %@", relativeAge(document.updatedAt, now: context.date)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func relativeAge(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return L10n.settings("just now") }
        if seconds < 3_600 { return L10n.settings("%dm ago", max(1, Int(seconds / 60))) }
        if seconds < 86_400 { return L10n.settings("%dh ago", max(1, Int(seconds / 3_600))) }
        return L10n.settings("%dd ago", max(1, Int(seconds / 86_400)))
    }
}
