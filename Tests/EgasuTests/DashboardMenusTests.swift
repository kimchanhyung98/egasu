import XCTest
@testable import Egasu

@MainActor
final class DashboardMenusTests: XCTestCase {
    private let cardID = "codex@ab12cd34"

    func testPinnableMetricOffersPinOrUnpinThenHide() {
        XCTAssertEqual(
            DashboardMenus.metric("codex.weekly", pinnable: true, pinned: false).compactMap(\.command),
            [.setPinned("codex.weekly", true), .hide("codex.weekly")]
        )
        XCTAssertEqual(
            DashboardMenus.metric("codex.weekly", pinnable: true, pinned: true).compactMap(\.command),
            [.setPinned("codex.weekly", false), .hide("codex.weekly")]
        )
    }

    func testUnpinnableMetricStillOffersHide() {
        XCTAssertEqual(
            DashboardMenus.metric("codex.trend", pinnable: false, pinned: false).compactMap(\.command),
            [.hide("codex.trend")],
            "차트처럼 고정할 수 없는 행도 숨길 수 있음"
        )
    }

    func testRenameSitsBetweenRefreshAndEditForNamedAccounts() {
        let commands = DashboardMenus.account(account, canRename: true).flatMap { $0 }.compactMap(
            \.command)
        XCTAssertEqual(commands, [.refresh([cardID]), .rename(cardID), .editAccount(cardID)])
    }

    func testAccountsWithoutANameOfferNoRename() {
        let commands = DashboardMenus.account(account, canRename: false).flatMap { $0 }.compactMap(
            \.command)
        XCTAssertFalse(commands.contains(.rename(cardID)))
    }

    func testPrivacyDisablesRenameWithoutBlockingOtherAccountActions() throws {
        let items = DashboardMenus.account(
            account,
            profileAction: DashboardMenuItem(title: "Use Codex: t**t@g***l.com", command: .switchAccount("profile")),
            canRename: true, renameDisabled: true
        ).flatMap { $0 }
        let rename = try XCTUnwrap(items.first { $0.command == .rename(cardID) })
        XCTAssertTrue(rename.isDisabled)
        XCTAssertTrue(items.filter { $0.command != .rename(cardID) }.allSatisfy { !$0.isDisabled })
        XCTAssertTrue(items.contains { $0.command == .editAccount(cardID) })
        XCTAssertTrue(items.contains { $0.command == .switchAccount("profile") })
    }

    func testExpiredCodexMenuTargetsOnlyTheRegisteredProfileWithoutPrintingTheError() throws {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "work", identityKey: "identity", createdAt: .distantPast)
        for status in [AccountStatus.sessionExpired("long error"), .signInNeeded("long error")] {
            for selected in [true, false] {
                let action = DashboardMenus.profileAction(
                    for: profile, status: status, isSelected: selected, displayName: profile.label, isBusy: false)
                let sections = DashboardMenus.account(account, profileAction: action)
                let metricMenu = DashboardMenus.metric("weekly", pinnable: true, pinned: false)
                for menu in [sections.flatMap { $0 }, metricMenu + sections.flatMap { $0 }] {
                    XCTAssertTrue(
                        menu.contains(
                            DashboardMenuItem(title: L10n.accounts("Sign In Again…"), command: .signInAgain("c"))))
                    XCTAssertFalse(
                        menu.contains { $0.command == .switchAccount("c") || $0.title.contains("long error") })
                }
            }
        }
    }

    func testOtherAccountStatesKeepSwitchAndRespectTheBusyState() {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "work", identityKey: "identity", createdAt: .distantPast)
        for status in [AccountStatus.ready, .checking, .refreshFailed("network"), .refreshFailed("Keychain")] {
            XCTAssertNil(
                DashboardMenus.profileAction(
                    for: profile, status: status, isSelected: true, displayName: "work", isBusy: false))
            XCTAssertEqual(
                DashboardMenus.profileAction(
                    for: profile, status: status, isSelected: false, displayName: "work", isBusy: true)?.command,
                .switchAccount("c"))
        }
        XCTAssertEqual(
            DashboardMenus.profileAction(
                for: profile, status: .sessionExpired("expired"), isSelected: false, displayName: "work", isBusy: true)?
                .isDisabled, true)
        var claude = profile
        claude.family = "claude"
        XCTAssertEqual(
            DashboardMenus.profileAction(
                for: claude, status: .signInNeeded(), isSelected: false, displayName: "work", isBusy: false)?.command,
            .switchAccount("c"))
    }

    func testPendingCodexRecoveryOffersUseForTheSelectedAccountInsteadOfAnotherSignIn() {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "work", identityKey: "identity", createdAt: .distantPast)
        for status in [AccountStatus.ready, .sessionExpired("expired"), .signInNeeded()] {
            for busy in [false, true] {
                let action = DashboardMenus.profileAction(
                    for: profile, status: status, isSelected: true, displayName: profile.label,
                    isBusy: busy, hasPendingRecovery: true)
                XCTAssertEqual(action?.command, .switchAccount(profile.id))
                XCTAssertEqual(action?.isDisabled, busy)
            }
        }
    }

    func testProviderMenuOffersRefreshAndAccountManagementWithoutSharing() {
        let family = DashboardFamily(id: "codex", provider: account.provider, displayName: "Codex", accounts: [account])
        let commands = DashboardMenus.provider(family).flatMap { $0 }.compactMap(\.command)
        XCTAssertEqual(commands, [.refresh([cardID]), .manageAccounts])
    }

    func testSwitchAlertsChooseDetailsAtPresentationTime() {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "Private Alias", identityKey: "workspace", createdAt: .distantPast)
        let path = "/fixture/private-account/auth.json"
        let cause = UserFacingErrors.message(CodexAuthError.sessionExpired)
        let required = AccountActionAlert.signInRequired(profile, detail: cause + " " + path, concealedDetail: cause)
        let failed = AccountActionAlert.switchFailed(
            profile, email: "test@gmail.com", error: KeychainError.readFailed(path))
        for concealed in [false, true, false] {
            let signIn = required.text(concealsAccountNames: concealed)
            XCTAssertEqual(signIn.title.contains(profile.label), !concealed)
            XCTAssertEqual(signIn.message.contains(path), !concealed)
            XCTAssertTrue(signIn.message.contains(cause))
            let failure = failed.text(concealsAccountNames: concealed)
            XCTAssertEqual(failure.message.contains(profile.label), !concealed)
            XCTAssertEqual(failure.message.contains(path), !concealed)
            XCTAssertEqual(failure.message.contains("t**t@g***l.com"), concealed)
        }
        XCTAssertEqual(required.recoveryProfile?.id, profile.id)
        XCTAssertNil(failed.recoveryProfile)
    }

    private var account: DashboardAccount {
        DashboardAccount(
            provider: Provider(id: cardID, displayName: "Codex", icon: .providerMark("codex")),
            providerName: "Codex",
            name: "work",
            lines: []
        )
    }
}
