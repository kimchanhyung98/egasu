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
        let commands = DashboardMenus.account(account, status: nil, canRename: true).flatMap { $0 }.compactMap(
            \.command)
        XCTAssertEqual(commands, [.refresh([cardID]), .rename(cardID), .editAccount(cardID)])
    }

    func testAccountsWithoutANameOfferNoRename() {
        let commands = DashboardMenus.account(account, status: nil, canRename: false).flatMap { $0 }.compactMap(
            \.command)
        XCTAssertFalse(commands.contains(.rename(cardID)))
    }

    func testPrivacyDisablesRenameWithoutBlockingOtherAccountActions() throws {
        let items = DashboardMenus.account(
            account, status: nil,
            switchTitle: ("Use Codex: t**t@g***l.com", "profile", false),
            canRename: true, renameDisabled: true
        ).flatMap { $0 }
        let rename = try XCTUnwrap(items.first { $0.command == .rename(cardID) })
        XCTAssertTrue(rename.isDisabled)
        XCTAssertTrue(items.filter { $0.command != .rename(cardID) }.allSatisfy { !$0.isDisabled })
        XCTAssertTrue(items.contains { $0.command == .editAccount(cardID) })
        XCTAssertTrue(items.contains { $0.command == .switchAccount("profile") })
    }

    func testProviderMenuOffersRefreshAndAccountManagementWithoutSharing() {
        let family = DashboardFamily(id: "codex", provider: account.provider, displayName: "Codex", accounts: [account])
        let commands = DashboardMenus.provider(family).flatMap { $0 }.compactMap(\.command)
        XCTAssertEqual(commands, [.refresh([cardID]), .manageAccounts])
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
