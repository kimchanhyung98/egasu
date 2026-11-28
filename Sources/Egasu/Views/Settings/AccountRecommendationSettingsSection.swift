import SwiftUI

struct AccountRecommendationSettingsSection: View {
    let settings: AccountRecommendationSettingsStore

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle(isOn: $settings.enabled) {
                SettingsTitle(
                    title: L10n.settings("Enabled"),
                    info: L10n.settings(
                        "Suggest another Claude or Codex account. Switching always requires confirmation."))
            }
            .accessibilityLabel(L10n.settings("Enable Account Recommendations"))
            if settings.enabled {
                RecommendationPercentField(
                    title: L10n.settings("Recommend At"),
                    info: L10n.settings("Suggest switching when any current base quota reaches this usage."),
                    value: settings.triggerPercent, save: settings.setTrigger)
                RecommendationPercentField(
                    title: L10n.settings("Candidate Usage Below"),
                    info: L10n.settings("Every applicable base quota on a candidate must be below this usage."),
                    value: settings.candidateLimitPercent, save: settings.setCandidateLimit)

            }
        } header: {
            Text(L10n.settings("Account Recommendations"))
        }
    }
}

private struct RecommendationPercentField: View {
    let title: String
    let info: String
    let value: Int
    let save: (String) -> Bool
    @State private var text: String
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(title: String, info: String, value: Int, save: @escaping (String) -> Bool) {
        self.title = title
        self.info = info
        self.value = value
        self.save = save
        _text = State(initialValue: String(value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent {
                HStack(spacing: 4) {
                    TextField(title, text: $text, prompt: Text(verbatim: "1–100"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 50)
                        .focused($isFocused)
                        .onSubmit { commit() }
                    Text("%")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            } label: {
                SettingsTitle(title: title, info: info)
            }
            if let errorMessage { SettingsNote(errorMessage) }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { commit() }
        }
        .onChange(of: text) { errorMessage = nil }
        .onChange(of: value) { _, percent in
            if !isFocused { text = String(percent) }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        guard save(text) else {
            errorMessage = L10n.settings("Enter a whole number from 1 to 100. %d%% is still applied.", value)
            return
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        errorMessage = nil
    }
}
