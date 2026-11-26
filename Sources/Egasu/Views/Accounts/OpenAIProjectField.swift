import SwiftUI

struct OpenAIProjectField: View {
    @Binding var input: String

    var body: some View {
        TextField(
            L10n.accounts("Project IDs"), text: $input,
            prompt: Text(L10n.accounts("Empty for the whole organization"))
        )
        .textFieldStyle(.roundedBorder)
        .accessibilityHint(L10n.accounts("Separate project IDs with commas."))
    }
}
