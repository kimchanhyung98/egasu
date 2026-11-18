import SwiftUI

/// 언어 행 — 바꾸면 다시 시작해야 적용, 그동안 재시작 안내와 Restart Now 행을 붙임.
struct LanguageSettingsRow: View {
    @Binding var selection: LanguageSetting
    var activeLanguage: LanguageSetting = .active
    let relauncher: AppRelauncher

    var pickerSelection: Binding<LanguageSetting> {
        Binding(
            get: { selection },
            set: { language in
                guard language != selection else { return }
                relauncher.clearError()
                selection = language
            }
        )
    }

    var body: some View {
        Picker(L10n.settings("Language"), selection: pickerSelection) {
            ForEach(LanguageSetting.allCases, id: \.self) { language in
                Text(language.nativeName).tag(language)
            }
        }
        .disabled(relauncher.isRestarting)

        if selection != activeLanguage {
            VStack(alignment: .leading, spacing: 6) {
                SettingsNote(L10n.settings("Restart egasu to apply the language change."))
                Button(L10n.settings("Restart Now"), action: relauncher.restart)
                    .disabled(relauncher.isRestarting)
                if let errorMessage = relauncher.errorMessage {
                    SettingsNote(errorMessage)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
