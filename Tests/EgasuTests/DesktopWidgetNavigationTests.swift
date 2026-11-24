import DesktopWidgetSupport
import XCTest
@testable import Egasu

@MainActor
final class DesktopWidgetNavigationTests: XCTestCase {
    func testURLsRoundTripOnlyForTheMatchingHostAndScheme() throws {
        for target: DesktopWidgetDestination in [.priority, .allUsage, .alerts, .account("group:work/A&B")] {
            let url = try XCTUnwrap(target.url(scheme: "egasu-dev"))
            XCTAssertEqual(DesktopWidgetDestination(url: url, scheme: "egasu-dev"), target)
            XCTAssertNil(DesktopWidgetDestination(url: url, scheme: "egasu"))
        }
        for raw in [
            "egasu://unknown/priority", "egasu://user@widget/priority", "egasu://widget:123/alerts",
            "egasu://widget/alerts?extra=1", "egasu://widget/priority#extra", "egasu://widget/account",
            "egasu://widget/account?id=", "egasu://widget/account?id=a&id=b", "egasu://widget/reset"
        ] {
            XCTAssertNil(DesktopWidgetDestination(url: try XCTUnwrap(URL(string: raw)), scheme: "egasu"), raw)
        }
    }

    func testColdLaunchRetainsLastValidClickUntilPanelIsReadyAndConsumesItOnce() throws {
        var navigation = DesktopWidgetNavigation()
        let first = try XCTUnwrap(DesktopWidgetDestination.priority.url(scheme: "egasu"))
        let second = try XCTUnwrap(DesktopWidgetDestination.account("work").url(scheme: "egasu"))
        let wrongBuild = try XCTUnwrap(DesktopWidgetDestination.account("dev").url(scheme: "egasu-dev"))
        navigation.receive([first], scheme: "egasu")
        navigation.receive([first, second, wrongBuild], scheme: "egasu")
        navigation.receive([wrongBuild], scheme: "egasu")
        XCTAssertEqual(navigation.take(), .account("work"))
        XCTAssertNil(navigation.take())
        navigation.receive([first], scheme: "egasu")
        XCTAssertEqual(navigation.take(), .priority)
    }

    func testWidgetSelectsDashboardOrAlertsWithoutChangingTheUsersDefault() throws {
        let suite = "EgasuTests.WidgetNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(DashboardTab.allUsage.rawValue, forKey: DashboardTab.defaultKey)
        let display = DisplaySettingsStore(defaults: defaults)
        let state = PopoverState(defaults: defaults, displaySettings: display)
        let noAccount: (String) -> String? = { _ in
            XCTFail("unexpected account lookup"); return nil
        }
        state.openAccounts("old")
        state.openFromWidget(.priority, cardID: noAccount)
        XCTAssertEqual(state.screen, .dashboard)
        XCTAssertEqual(state.dashboardTab, .priority)
        XCTAssertNil(state.accountDetailID)
        XCTAssertEqual(defaults.string(forKey: DashboardTab.defaultKey), DashboardTab.allUsage.rawValue)

        display.showsCritical = false
        display.showsWarning = false
        display.showsBurningFast = false
        display.showsUseItOrLoseIt = false
        state.openFromWidget(.priority, cardID: noAccount)
        XCTAssertEqual(state.screen, .settings)
        XCTAssertEqual(state.settingsTab, .alerts)
        state.openFromWidget(.allUsage, cardID: noAccount)
        XCTAssertEqual(state.screen, .dashboard)
        XCTAssertEqual(state.dashboardTab, .allUsage)
        display.showsCritical = true
        state.openFromWidget(.alerts, cardID: noAccount)
        XCTAssertEqual(state.screen, .settings)
        XCTAssertEqual(state.settingsTab, .alerts)
    }

    func testWidgetReResolvesAccountForEachClickAndReturnsToListAfterRemoval() {
        let state = PopoverState(dashboardTab: .allUsage)
        let link = DesktopWidgetDestination.account("stable-work")
        var byKey = ["stable-work": "codex"]
        state.openFromWidget(link) { byKey[$0] }
        XCTAssertEqual(state.screen, .accounts)
        XCTAssertEqual(state.accountDetailID, "codex")
        byKey["stable-work"] = "codex@abcd1234"
        state.openFromWidget(link) { byKey[$0] }
        XCTAssertEqual(state.accountDetailID, "codex@abcd1234")
        state.isAddingAccount = true
        byKey.removeAll()
        state.openFromWidget(link) { byKey[$0] }
        XCTAssertEqual(state.screen, .accounts)
        XCTAssertNil(state.accountDetailID)
        XCTAssertFalse(state.isAddingAccount)
    }
}
