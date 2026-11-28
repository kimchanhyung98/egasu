import AppKit
import SwiftUI

enum AccountActionAlert {
    case recommendationChanged
    case switchFailed(AccountProfile, email: String?, error: any Error)
    case signInRequired(AccountProfile, detail: String?, concealedDetail: String?)
    case signInFailed(AccountProfile, issues: [AccountReSignInIssue], allowsRetry: Bool)

    var recoveryProfile: AccountProfile? {
        switch self {
        case .signInRequired(let profile, _, _) where profile.family == "codex": profile
        case .signInFailed(let profile, _, true): profile
        default: nil
        }
    }

    func text(concealsAccountNames: Bool) -> (title: String, message: String) {
        func signInTitle(_ profile: AccountProfile) -> String {
            concealsAccountNames ? L10n.accounts("Sign In Again") : L10n.accounts("Sign In Again to %@", profile.label)
        }
        let switchTitle = L10n.dashboard("Couldn't Switch Account")
        switch self {
        case .recommendationChanged:
            return (switchTitle, L10n.dashboard("Account usage changed. Check the latest recommendation."))
        case .switchFailed(let profile, let email, let error):
            return (
                switchTitle,
                AccountNamePrivacy.switchErrorMessage(
                    error, name: profile.label, email: email, conceals: concealsAccountNames)
            )
        case .signInRequired(let profile, let detail, let concealedDetail):
            let message =
                (concealsAccountNames ? concealedDetail : detail)
                ?? L10n.accounts("Sign in again before switching to this account.")
            return (profile.family == "codex" ? signInTitle(profile) : switchTitle, message)
        case .signInFailed(let profile, let issues, _):
            return (
                signInTitle(profile),
                issues.map { $0.message(concealsAccountNames: concealsAccountNames) }.joined(separator: "\n")
            )
        }
    }
}

/// SwiftUI의 alert는 표시 중인 문구를 유지하므로 개인정보 보호 설정이 바뀌면 같은 NSAlert의 문구를 갱신.
struct DashboardAccountAlertSheet: NSViewRepresentable {
    let alert: AccountActionAlert
    let concealsAccountNames: Bool
    let onDismiss: (AccountProfile?) -> Void

    func makeNSView(context: Context) -> Anchor { Anchor() }

    func updateNSView(_ view: Anchor, context: Context) { view.presentation = self }

    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.presentation = nil }

    final class Anchor: NSView {
        var presentation: DashboardAccountAlertSheet? { didSet { updateSheet() } }
        private var sheet: NSAlert?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            updateSheet()
        }

        private func updateSheet() {
            guard let presentation, let window else {
                if let sheet {
                    self.sheet = nil
                    sheet.window.sheetParent?.endSheet(sheet.window)
                }
                return
            }
            let text = presentation.alert.text(concealsAccountNames: presentation.concealsAccountNames)
            if let sheet {
                if sheet.messageText != text.title || sheet.informativeText != text.message {
                    sheet.messageText = text.title
                    sheet.informativeText = text.message
                    sheet.layout()
                }
                return
            }
            let sheet = NSAlert()
            self.sheet = sheet
            sheet.messageText = text.title
            sheet.informativeText = text.message
            sheet.alertStyle = .informational
            if presentation.alert.recoveryProfile != nil { sheet.addButton(withTitle: L10n.accounts("Sign In Again…")) }
            let ok = sheet.addButton(withTitle: L10n.dashboard("OK"))
            ok.keyEquivalent = "\u{1b}"
            sheet.beginSheetModal(for: window) { [weak self, weak sheet] response in
                guard let self, let sheet, self.sheet === sheet, let current = self.presentation else { return }
                self.sheet = nil
                current.onDismiss(response == .alertFirstButtonReturn ? current.alert.recoveryProfile : nil)
            }
        }
    }
}
