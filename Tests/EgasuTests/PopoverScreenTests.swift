import XCTest
@testable import Egasu

@MainActor
final class PopoverScreenTests: XCTestCase {
    func testLaunchTabUsesStoredPreferenceOrPriorityDefault() throws {
        let suiteName = "EgasuTests.PopoverScreen.InitialTab.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let state = PopoverState(defaults: defaults)
        XCTAssertEqual(state.screen, .dashboard)
        XCTAssertEqual(state.dashboardTab, .priority)

        defaults.set(DashboardTab.allUsage.rawValue, forKey: DashboardTab.defaultKey)
        XCTAssertEqual(PopoverState(defaults: defaults).dashboardTab, .allUsage)
    }

    func testStartsOnDashboardPriority() {
        let state = PopoverState(dashboardTab: .priority)
        XCTAssertEqual(state.screen, .dashboard)
        XCTAssertEqual(state.dashboardTab, .priority)
        XCTAssertEqual(state.settingsTab, .general)
    }

    func testScreensReplaceEachOtherAndRecordSlide() {
        let state = PopoverState()
        state.screen = .accounts
        XCTAssertEqual(state.screenSlideFrom, .dashboard)
        XCTAssertEqual(state.screenSlideID, 1)

        state.screen = .settings
        XCTAssertEqual(state.screenSlideFrom, .accounts)
        XCTAssertEqual(state.screenSlideID, 2)

        state.screen = .settings
        XCTAssertEqual(state.screenSlideID, 2, "같은 화면 재설정은 slide를 기록하지 않음")
    }

    func testLeavingAccountsClearsDetailAndSheet() {
        let state = PopoverState()
        state.openAccounts("claude")
        state.isAddingAccount = true
        XCTAssertEqual(state.accountDetailID, "claude")

        state.screen = .settings
        XCTAssertNil(state.accountDetailID)
        XCTAssertFalse(state.isAddingAccount)
    }

    func testBackStepsFromDetailToListToDashboard() {
        let state = PopoverState()
        state.openAccounts("codex")

        XCTAssertTrue(state.back())
        XCTAssertNil(state.accountDetailID)
        XCTAssertEqual(state.screen, .accounts)

        XCTAssertTrue(state.back())
        XCTAssertEqual(state.screen, .dashboard)

        XCTAssertFalse(state.back(), "대시보드에서는 패널 닫기로 넘어감")
    }

    func testToggleReturnsToDashboard() {
        let state = PopoverState()
        state.toggle(.settings)
        XCTAssertEqual(state.screen, .settings)
        state.toggle(.settings)
        XCTAssertEqual(state.screen, .dashboard)
    }

    func testAccountDetailFollowsTheSameProfileWhenCardsSwap() {
        for family in ["claude", "codex"] {
            let personalID = AccountUsageCardPlanner.cardID(family: family, profileID: "personal")
            let workID = AccountUsageCardPlanner.cardID(family: family, profileID: "work")
            let previous = [family: "personal", workID: "work"]
            let next = [family: "work", personalID: "personal"]
            let nextRegistry = registry(cardIDs: [family, personalID])

            for (openedID, expectedID) in [(workID, family), (family, personalID)] {
                let state = PopoverState()
                state.openAccounts(openedID)
                state.reconcileAccountDetail(
                    in: nextRegistry, previousProfileIDsByCard: previous, nextProfileIDsByCard: next
                )

                XCTAssertEqual(state.accountDetailID, expectedID, "\(family): \(openedID)")
                XCTAssertEqual(next[expectedID], previous[openedID], "열린 상세는 같은 등록 계정 유지")
                XCTAssertNotNil(nextRegistry.provider(id: expectedID))
                XCTAssertEqual(state.screen, .accounts)

                state.reconcileAccountDetail(
                    in: nextRegistry, previousProfileIDsByCard: next, nextProfileIDsByCard: next
                )
                XCTAssertEqual(state.accountDetailID, expectedID, "같은 카탈로그 재적용은 상세 유지")
            }
        }
    }

    func testMissingProfileReturnsToListEvenIfItsOldCardNowBelongsToAnotherAccount() {
        let state = PopoverState()
        state.openAccounts("codex")

        state.reconcileAccountDetail(
            in: registry(cardIDs: ["codex"]),
            previousProfileIDsByCard: ["codex": "personal"],
            nextProfileIDsByCard: ["codex": "work"]
        )

        XCTAssertNil(state.accountDetailID)
        XCTAssertEqual(state.screen, .accounts)
    }

    func testDetailRequiresARealCardAndPreservesAnUnchangedProfileCard() {
        let snapshotID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "work")
        let mapping = ["codex": "work", snapshotID: "work"]
        let state = PopoverState()
        state.openAccounts(snapshotID)

        state.reconcileAccountDetail(
            in: registry(cardIDs: ["codex", snapshotID]),
            previousProfileIDsByCard: mapping, nextProfileIDsByCard: mapping
        )
        XCTAssertEqual(state.accountDetailID, snapshotID, "같은 계정의 기존 카드가 있으면 불필요한 이동 없음")

        state.reconcileAccountDetail(
            in: registry(cardIDs: ["codex"]),
            previousProfileIDsByCard: mapping, nextProfileIDsByCard: mapping
        )
        XCTAssertEqual(state.accountDetailID, "codex", "매핑만 남은 snapshot 대신 실제 카드 선택")

        state.reconcileAccountDetail(
            in: registry(cardIDs: []),
            previousProfileIDsByCard: mapping, nextProfileIDsByCard: mapping
        )
        XCTAssertNil(state.accountDetailID)
        XCTAssertEqual(state.screen, .accounts)
    }

    func testDetectedProviderDetailStaysOnlyWhileItsCardExists() {
        let state = PopoverState()
        state.openAccounts("cursor")
        state.reconcileAccountDetail(
            in: registry(cardIDs: ["cursor"]), previousProfileIDsByCard: [:], nextProfileIDsByCard: [:]
        )
        XCTAssertEqual(state.accountDetailID, "cursor")

        state.reconcileAccountDetail(
            in: registry(cardIDs: []), previousProfileIDsByCard: [:], nextProfileIDsByCard: [:]
        )
        XCTAssertNil(state.accountDetailID)
        XCTAssertEqual(state.screen, .accounts)
    }

    func testCatalogRefreshDoesNotOpenDetailOrLeaveTheCurrentScreen() {
        for screen in [PopoverScreen.dashboard, .accounts, .settings] {
            let state = PopoverState()
            state.openAccounts("codex@profile-work")
            if screen == .accounts {
                state.back()
            } else {
                state.screen = screen
            }
            state.reconcileAccountDetail(
                in: registry(cardIDs: ["codex"]),
                previousProfileIDsByCard: ["codex@profile-work": "work"],
                nextProfileIDsByCard: ["codex": "work"]
            )
            XCTAssertNil(state.accountDetailID)
            XCTAssertEqual(state.screen, screen)
        }
    }

    func testResetReturnsToDashboardAndGeneralTab() {
        let state = PopoverState()
        state.screen = .settings
        state.settingsTab = .advanced
        state.shareNotice.present(true)

        state.reset()

        XCTAssertEqual(state.screen, .dashboard)
        XCTAssertEqual(state.settingsTab, .general)
        XCTAssertFalse(state.shareNotice.value)
    }

    func testShowSetsTabAndVisibility() {
        let state = PopoverState()
        state.show(dashboardTab: .allUsage)
        XCTAssertEqual(state.dashboardTab, .allUsage)
        XCTAssertTrue(state.popoverShown)
    }

    func testReopeningPreservesLastSelectedTab() {
        for initialTab in DashboardTab.allCases {
            let state = PopoverState(dashboardTab: initialTab)
            state.show()
            XCTAssertEqual(state.dashboardTab, initialTab)

            let selectedTab: DashboardTab = initialTab == .priority ? .allUsage : .priority
            state.dashboardTab = selectedTab
            state.screen = .settings
            state.popoverShown = false
            state.reset()
            state.show()

            XCTAssertEqual(state.screen, .dashboard)
            XCTAssertEqual(state.dashboardTab, selectedTab)
            XCTAssertTrue(state.popoverShown)
        }
    }

    func testExplicitOpenTabOverridesLastSelection() {
        let state = PopoverState(dashboardTab: .priority)
        state.show(dashboardTab: .allUsage)
        state.popoverShown = false
        state.reset()
        state.show()

        XCTAssertEqual(state.dashboardTab, .allUsage)
    }

    func testPreferredTabReadsDefaultTabSetting() {
        let suiteName = "EgasuTests.PopoverScreen.DefaultTab.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        XCTAssertEqual(DashboardTab.preferred(in: defaults), .priority)
        defaults.set(DashboardTab.allUsage.rawValue, forKey: DashboardTab.defaultKey)
        XCTAssertEqual(DashboardTab.preferred(in: defaults), .allUsage)
    }

    private func registry(cardIDs: [String]) -> WidgetRegistry {
        WidgetRegistry(
            providers: cardIDs.map { Provider(id: $0, displayName: $0, icon: .providerMark("codex")) },
            descriptors: []
        )
    }
}
