import SwiftUI

struct SoftLimitThresholdField: View {
    let settings: SoftLimitSettingsStore
    @State private var text: String
    @State private var errorMessage: String?
    @FocusState private var isFocused: Bool

    init(settings: SoftLimitSettingsStore) {
        self.settings = settings
        _text = State(initialValue: String(settings.thresholdPercent))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabeledContent(L10n.settings("Threshold")) {
                HStack(spacing: 4) {
                    TextField(
                        L10n.settings("Soft Limit Threshold Percent"), text: $text, prompt: Text(verbatim: "1–100")
                    )
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 50)
                    .focused($isFocused)
                    .onSubmit { save() }
                    Text("%")
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            if let errorMessage {
                SettingsNote(errorMessage)
            }
        }
        .onChange(of: isFocused) { _, focused in
            if !focused { save() }
        }
        .onChange(of: text) { errorMessage = nil }
        .onChange(of: settings.thresholdPercent) { _, percent in
            if !isFocused { text = String(percent) }
        }
        .onDisappear { save() }
    }

    private func save() {
        guard settings.setThreshold(from: text) else {
            errorMessage = L10n.settings(
                "Enter a whole number from 1 to 100. %d%% is still applied.", settings.thresholdPercent)
            return
        }
        text = String(settings.thresholdPercent)
        errorMessage = nil
    }
}
