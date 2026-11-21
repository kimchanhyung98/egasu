import XCTest
@testable import Egasu

final class AccountNamePrivacyTests: XCTestCase {
    func testPrivacyModeOnlyConcealsDashboardAccountNames() {
        for screen in [PopoverScreen.dashboard, .accounts, .settings] {
            XCTAssertEqual(AccountNamePrivacy.concealsAccountNames(on: screen, isEnabled: true), screen == .dashboard)
            XCTAssertFalse(AccountNamePrivacy.concealsAccountNames(on: screen, isEnabled: false))
        }
    }

    @MainActor
    func testDashboardProtectionDoesNotRequireScreenCapture() {
        let suite = "EgasuTests.AccountNamePrivacy.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: MenuBarPrivacyStore.key)
        let privacy = MenuBarPrivacyStore(defaults: defaults, probe: { false }, installChangeNotifications: { _ in })
        defer {
            privacy.hideUsageWhileScreenSharing = false
            defaults.removePersistentDomain(forName: suite)
        }

        XCTAssertFalse(privacy.screenIsCaptured)
        XCTAssertFalse(privacy.concealUsage)
        XCTAssertTrue(
            AccountNamePrivacy.concealsAccountNames(on: .dashboard, isEnabled: privacy.hideUsageWhileScreenSharing))
        XCTAssertFalse(
            AccountNamePrivacy.concealsAccountNames(on: .accounts, isEnabled: privacy.hideUsageWhileScreenSharing))
        privacy.hideUsageWhileScreenSharing = false
        XCTAssertFalse(
            AccountNamePrivacy.concealsAccountNames(on: .dashboard, isEnabled: privacy.hideUsageWhileScreenSharing))
    }

    func testVisibleNamesKeepTheAlias() {
        XCTAssertEqual(AccountNamePrivacy.displayName("Work", email: "test@gmail.com", conceals: false), "Work")
        XCTAssertEqual(AccountNamePrivacy.displayName("Personal", email: nil, conceals: false), "Personal")
    }

    func testConcealedNamesUseTheMaskedEmailInsteadOfTheAlias() {
        XCTAssertEqual(
            AccountNamePrivacy.displayName("Work", email: "test@gmail.com", conceals: true), "t**t@g***l.com")
        XCTAssertEqual(
            AccountNamePrivacy.displayName("test@gmail.com", email: "test@gmail.com", conceals: true), "t**t@g***l.com")
    }

    func testMissingOrInvalidEmailUsesTheLocalizedGenericName() {
        for language in LanguageSetting.allCases {
            L10n.withLanguage(language) {
                for email in [nil, "", "Work", "invalid@"] {
                    XCTAssertEqual(
                        AccountNamePrivacy.displayName("Private Alias", email: email, conceals: true),
                        L10n.dashboard("Account")
                    )
                }
            }
        }
    }

    func testEmailMaskPreservesOnlyTheEndsAndFinalDomainLabel() {
        let cases = [
            ("test@gmail.com", "t**t@g***l.com"),
            ("test@mail.gmail.com", "t**t@m**l.g***l.com"),
            ("user@example.co.uk", "u**r@e*****e.c*.uk"),
            ("first.last@example-domain.com", "f********t@e************n.com"),
            ("홍길동@메일.한국", "홍*동@메*.한국"),
            ("  TEST@GMAIL.COM\n", "T**T@G***L.COM")
        ]
        for (email, expected) in cases {
            XCTAssertEqual(AccountNamePrivacy.maskedEmail(email), expected, email)
        }
    }

    func testShortEmailLabelsStillHideAtLeastOneCharacter() {
        let cases = [
            ("a@b.com", "*@*.com"),
            ("ab@cd.com", "a*@c*.com"),
            ("a@b.cd.com", "*@*.c*.com")
        ]
        for (email, expected) in cases {
            XCTAssertEqual(AccountNamePrivacy.maskedEmail(email), expected, email)
        }
    }

    func testInvalidEmailDoesNotExposeAnUnmaskedValue() {
        let invalid: [String?] = [
            nil, "", " \n", "Work", "test.gmail.com", "test@", "@gmail.com", "test@@gmail.com",
            "test@gmail", "test@.com", "test@gmail..com", "test @gmail.com", "test@gmail .com",
            "test@gmail.com\nother", "test\u{0}@gmail.com"
        ]
        for email in invalid {
            XCTAssertNil(AccountNamePrivacy.maskedEmail(email), email ?? "nil")
        }
    }

    func testConcealedSwitchErrorsMaskOnlyTheirAccountArguments() {
        L10n.withLanguage(.english) {
            let cases: [(AccountCredentialSwitcher.Error, String)] = [
                (.missingSnapshot("a"), "No saved sign-in was found for t**t@g***l.com. Sign in again and retry."),
                (
                    .snapshotIdentityMismatch("a"),
                    "The saved sign-in for t**t@g***l.com no longer matches its account. Sign in again and retry."
                ),
                (
                    .switchVerificationFailed("a"),
                    "Switching to t**t@g***l.com could not be verified. Check the selected account and try again."
                )
            ]
            for (error, expected) in cases {
                XCTAssertEqual(
                    AccountNamePrivacy.switchErrorMessage(error, name: "a", email: "test@gmail.com", conceals: true),
                    "Couldn't switch to t**t@g***l.com: \(expected)"
                )
            }
        }
    }

    func testVisibleSwitchErrorsKeepTheirOriginalAccountArguments() {
        let errors: [AccountCredentialSwitcher.Error] = [
            .missingSnapshot("Private Alias"), .snapshotIdentityMismatch("Private Alias"),
            .switchVerificationFailed("Private Alias")
        ]
        for error in errors {
            XCTAssertEqual(
                AccountNamePrivacy.switchErrorMessage(
                    error, name: "Private Alias", email: "test@gmail.com", conceals: false),
                L10n.accounts("Couldn't switch to %@: %@", "Private Alias", UserFacingErrors.message(error))
            )
        }
    }

    func testConcealedSwitchErrorWithoutEmailUsesOnlyTheGenericAccountName() {
        L10n.withLanguage(.english) {
            XCTAssertEqual(
                AccountNamePrivacy.switchErrorMessage(
                    AccountCredentialSwitcher.Error.missingSnapshot("Private Alias"),
                    name: "Private Alias", email: nil, conceals: true
                ),
                "Couldn't switch to Account: No saved sign-in was found for Account. Sign in again and retry."
            )
        }
    }
}
