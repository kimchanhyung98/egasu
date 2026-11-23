import SwiftUI

struct AccountRecommendationRow: View {
    @Environment(AppContainer.self) private var container
    @Environment(\.concealsAccountNames) private var concealsNames
    let family: String
    let onError: (AccountActionAlert?) -> Void
    @State private var pending: AccountSwitchRecommendation?
    @State private var selection: AccountProfile?

    var body: some View {
        let now = Date()
        let deadlines = container.dataStore.localSnapshots.values
            .filter { ProviderAccountID.family(of: $0.providerID) == family }
            .flatMap { $0.recommendationDeadlines(after: now) }
        return TimelineView(.explicit([now] + Set(deadlines).sorted())) { context in
            let suggestion = container.accountRecommendation(for: family, at: max(context.date, .now))
            Group {
                if let suggestion {
                    controls(for: suggestion)
                }
            }
            .onChange(of: suggestion) { _, current in
                guard !container.accountSwitch.isSwitching, container.popover.signingInAgainAccountID == nil else {
                    return
                }
                if current == nil {
                    pending = nil
                    selection = nil
                }
            }
        }
        .accountSwitchConfirmation(
            selection: $selection, onError: onError,
            validateTarget: { [pending] entry in
                guard let pending else { throw AccountSwitchRecommendation.NoLongerAvailable() }
                try pending.validateTarget(entry)
            },
            validateDeparture: { [pending] identity in
                guard let pending else { throw AccountSwitchRecommendation.NoLongerAvailable() }
                try pending.validate(
                    departure: identity,
                    latest: container.accountRecommendation(for: family, at: .now, confirming: pending.target.id))
            })
    }

    private func controls(for suggestion: AccountSwitchRecommendation) -> some View {
        let target = suggestion.target
        let name = AccountNamePrivacy.displayName(
            target.label, email: container.accountLoginEmail(for: target), conceals: concealsNames)
        return AccountRecommendationControls(name: name) {
            guard container.accountRecommendation(for: family, at: .now) == suggestion else { return }
            pending = suggestion
            selection = target
        } dismiss: {
            container.dismissAccountRecommendation(suggestion, at: .now)
        }
    }
}

struct AccountRecommendationControls: View {
    let name: String
    let select: () -> Void
    let dismiss: () -> Void

    var body: some View {
        let title = L10n.dashboard("Switch to %@", name)
        // 언어별 동작 문구는 유지하고 계정명만 한 줄로 줄임.
        let parts = L10n.dashboard("Switch to %@").components(separatedBy: "%@")
        return HStack(spacing: 6) {
            Text(L10n.dashboard("Suggested"))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 64, alignment: .leading)
            Button(action: select) {
                HStack(spacing: 0) {
                    Text(verbatim: parts.first ?? "").fixedSize()
                    Text(verbatim: name).lineLimit(1).truncationMode(.tail)
                    Text(verbatim: parts.last ?? "").fixedSize()
                }
            }
            .controlSize(.small)
            .accessibilityLabel(title)
            .frame(maxWidth: .infinity)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.dashboard("Dismiss"))
            .frame(width: 64, alignment: .trailing)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(.secondary.opacity(0.35), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .padding(.top, 7)
        .padding(.bottom, 4)
    }
}
