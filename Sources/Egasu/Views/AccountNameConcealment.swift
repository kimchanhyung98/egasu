import SwiftUI

extension EnvironmentValues {
    /// Privacy Mode가 켜진 대시보드나 흐림을 요청한 공유 이미지에서 true. Accounts 화면은 예외.
    @Entry var concealsAccountNames = false
}

/// 이름을 가려야 하는 메뉴·확인창은 별명 대신 마스킹한 로그인 이메일 사용.
enum AccountNamePrivacy {
    static func concealsAccountNames(on screen: PopoverScreen, isEnabled: Bool) -> Bool {
        screen == .dashboard && isEnabled
    }

    static func displayName(_ name: String, email: String?, conceals: Bool) -> String {
        guard conceals else { return name }
        return maskedEmail(email) ?? L10n.dashboard("Account")
    }

    static func switchErrorMessage(_ error: Swift.Error, name: String, email: String?, conceals: Bool) -> String {
        let shownName = displayName(name, email: email, conceals: conceals)
        var shownError = error
        if conceals, let switchError = error as? AccountCredentialSwitcher.Error {
            switch switchError {
            case .missingSnapshot:
                shownError = AccountCredentialSwitcher.Error.missingSnapshot(shownName)
            case .snapshotIdentityMismatch:
                shownError = AccountCredentialSwitcher.Error.snapshotIdentityMismatch(shownName)
            case .switchVerificationFailed:
                shownError = AccountCredentialSwitcher.Error.switchVerificationFailed(shownName)
            default:
                break
            }
        }
        return L10n.accounts("Couldn't switch to %@: %@", shownName, UserFacingErrors.message(shownError))
    }

    static func maskedEmail(_ email: String?) -> String? {
        guard let email = email?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        guard email.rangeOfCharacter(from: .whitespacesAndNewlines.union(.controlCharacters)) == nil else { return nil }
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else { return nil }
        let domainLabels = parts[1].split(separator: ".", omittingEmptySubsequences: false)
        guard domainLabels.count >= 2, domainLabels.allSatisfy({ !$0.isEmpty }) else { return nil }
        let domain = (domainLabels.dropLast().map(maskedLabel) + [String(domainLabels.last!)]).joined(separator: ".")
        return "\(maskedLabel(parts[0]))@\(domain)"
    }

    private static func maskedLabel(_ label: Substring) -> String {
        if label.count == 1 { return "*" }
        if label.count == 2 { return "\(label.prefix(1))*" }
        return "\(label.prefix(1))\(String(repeating: "*", count: label.count - 2))\(label.suffix(1))"
    }
}

extension View {
    /// 계정명 흐림 처리 — 계정명 대신 표시하는 프로바이더 이름에는 미적용.
    func concealingAccountName() -> some View {
        modifier(AccountNameConcealment())
    }
}

private struct AccountNameConcealment: ViewModifier {
    @Environment(\.concealsAccountNames) private var conceals

    func body(content: Content) -> some View {
        content.blur(radius: conceals ? 4 : 0)
            .accessibilityHidden(conceals)
    }
}
