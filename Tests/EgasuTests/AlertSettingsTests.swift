import XCTest
@testable import Egasu

@MainActor
final class AlertSettingsTests: XCTestCase {
    func testSwitchesTurnedOnBeforeTheRenameStayOn() {
        let suite = "EgasuTests.AlertSettings.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        // 옛 Almost Out·Cutting It Close 저장값 — 같은 키를 새 Critical·Warning이 읽음.
        defaults.set(true, forKey: "openusage.notifications.underTenPercent")
        defaults.set(true, forKey: "openusage.notifications.healthyToClose")

        let settings = NotificationSettingsStore(defaults: defaults)
        XCTAssertTrue(settings.critical)
        XCTAssertTrue(settings.warning)
        XCTAssertFalse(settings.closeToRunningOut)
        XCTAssertFalse(settings.useItOrLoseIt, "새 알림은 기본 꺼짐")
        XCTAssertTrue(settings.anyEnabled)

        settings.useItOrLoseIt = true
        XCTAssertTrue(NotificationSettingsStore(defaults: defaults).useItOrLoseIt)
    }

    func testBurningFastTitleMatchesSettingsInEveryLanguageAndKeepsTheSavedSwitch() throws {
        let suite = "EgasuTests.BurningFastTitle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "openusage.notifications.closeToRunningOut"
        defaults.set(true, forKey: key)
        let settings = NotificationSettingsStore(defaults: defaults)
        let titles: [(LanguageSetting, String)] = [
            (.english, "Burning Fast"), (.korean, "빠른 소진"), (.japanese, "急速な消費")
        ]
        for (language, title) in titles {
            L10n.withLanguage(language) {
                XCTAssertEqual(PaceMilestone.closeToRunningOut.notificationTitle, title)
                XCTAssertEqual(PaceMilestone.closeToRunningOut.notificationTitle, L10n.dashboard("Burning Fast"))
                XCTAssertEqual(PaceMilestone.closeToRunningOut.settingKey, key)
                XCTAssertTrue(settings.isOn(.closeToRunningOut))
            }
        }
        settings.closeToRunningOut = false
        XCTAssertFalse(defaults.bool(forKey: key))
        XCTAssertFalse(NotificationSettingsStore(defaults: defaults).closeToRunningOut)
    }

    func testLevelAlertBodiesFollowThePriorityLimits() {
        let limits = PriorityLimits(warning: 40, critical: 15)
        L10n.withLanguage(.english) {
            XCTAssertEqual(PaceMilestone.warning.body(limits), "40% or less left for this window.")
            XCTAssertEqual(PaceMilestone.critical.body(limits), "15% or less left for this window.")
        }
    }

    func testConditionDisplayAndNotificationChoicesStayIndependentAcrossRelaunch() throws {
        let suite = "EgasuTests.AlertConditions.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplaySettingsStore(defaults: defaults)
        let notifications = NotificationSettingsStore(defaults: defaults)
        XCTAssertTrue(display.showsBurningFast)
        XCTAssertTrue(display.showsUseItOrLoseIt)
        XCTAssertFalse(notifications.anyEnabled)

        for shown in [false, true] {
            display.showsBurningFast = shown
            display.showsUseItOrLoseIt = shown
            XCTAssertFalse(notifications.anyEnabled, "표시 선택으로 알림 권한 요청 조건을 켜지 않음")
            for notify in [true, false] {
                notifications.closeToRunningOut = notify
                notifications.useItOrLoseIt = notify
                let restoredDisplay = DisplaySettingsStore(defaults: defaults)
                let restoredNotifications = NotificationSettingsStore(defaults: defaults)
                XCTAssertEqual(restoredDisplay.showsBurningFast, shown)
                XCTAssertEqual(restoredDisplay.showsUseItOrLoseIt, shown)
                XCTAssertEqual(restoredNotifications.closeToRunningOut, notify)
                XCTAssertEqual(restoredNotifications.useItOrLoseIt, notify)
                XCTAssertFalse(restoredNotifications.warning)
                XCTAssertFalse(restoredNotifications.critical)
                XCTAssertFalse(restoredNotifications.codexResetWatch)
            }
        }
        notifications.closeToRunningOut = true
        notifications.useItOrLoseIt = true
        display.showsBurningFast = false
        display.showsUseItOrLoseIt = false
        XCTAssertTrue(NotificationSettingsStore(defaults: defaults).closeToRunningOut)
        XCTAssertTrue(NotificationSettingsStore(defaults: defaults).useItOrLoseIt)
    }
}
