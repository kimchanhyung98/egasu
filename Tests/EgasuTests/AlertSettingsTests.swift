import CoreImage
import SwiftUI
import Vision
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

    func testWarningAndCriticalVisibilityMigrateAndPersistSeparatelyFromThresholdsAndAlerts() throws {
        let suite = "EgasuTests.AlertLevelVisibility.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(45, forKey: DisplaySettingsStore.priorityWarningKey)
        defaults.set(20, forKey: DisplaySettingsStore.priorityCriticalKey)
        defaults.set(false, forKey: DisplaySettingsStore.priorityBurningFastKey)
        defaults.set(false, forKey: DisplaySettingsStore.priorityUseItOrLoseItKey)
        defaults.set(true, forKey: PaceMilestone.warning.settingKey)
        let display = DisplaySettingsStore(defaults: defaults)
        XCTAssertTrue(display.showsWarning)
        XCTAssertTrue(display.showsCritical)

        for warning in [false, true] {
            for critical in [false, true] {
                display.showsWarning = warning
                display.showsCritical = critical
                let restored = DisplaySettingsStore(defaults: defaults)
                XCTAssertEqual(restored.showsWarning, warning)
                XCTAssertEqual(restored.showsCritical, critical)
                XCTAssertEqual(restored.visiblePriorityLevels.contains(.warning), warning)
                XCTAssertEqual(restored.visiblePriorityLevels.contains(.critical), critical)
                XCTAssertEqual(restored.hasVisiblePriorityConditions, warning || critical)
                XCTAssertEqual(restored.priorityLimits, PriorityLimits(warning: 45, critical: 20))
                let notifications = NotificationSettingsStore(defaults: defaults)
                XCTAssertTrue(notifications.warning)
                XCTAssertFalse(notifications.critical)
            }
        }
    }

    func testSystemSettingsLinkOpensThisAppsOwnNotificationPage() {
        XCTAssertEqual(
            AppNotifications.notificationSettingsURL(bundleID: "com.kimchanhyung98.openusage.dev")?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=com.kimchanhyung98.openusage.dev"
        )
        XCTAssertEqual(
            AppNotifications.notificationSettingsURL(bundleID: nil)?.absoluteString,
            "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        )
    }

    func testDelayedPermissionResponseFinishesBeforeRefreshingTheNotice() async throws {
        for granted in [true, false] {
            let started = expectation(description: "권한 응답 대기")
            var reply: CheckedContinuation<Bool, Never>?
            var response: Bool?
            var refreshed = false
            var displayedResponse: Bool?
            let request = Task<Bool, Never> {
                let value = await withCheckedContinuation {
                    reply = $0
                    started.fulfill()
                }
                response = value
                return value
            }
            let update = SettingsAlertsTab.requestAuthorization(request: { request }) {
                refreshed = true
                displayedResponse = response
            }
            await fulfillment(of: [started], timeout: 2)
            XCTAssertFalse(refreshed, "허용·거부 응답 전에는 안내 상태를 다시 읽지 않음")
            try XCTUnwrap(reply).resume(returning: granted)
            await update.value
            XCTAssertTrue(refreshed)
            XCTAssertEqual(displayedResponse, granted)
        }
    }

    func testRepeatedPermissionActionsWaitForTheSharedRequest() async throws {
        let started = expectation(description: "공유 권한 요청 대기")
        var reply: CheckedContinuation<Bool, Never>?
        var refreshCount = 0
        let request = Task<Bool, Never> {
            await withCheckedContinuation {
                reply = $0
                started.fulfill()
            }
        }
        let first = SettingsAlertsTab.requestAuthorization(request: { request }) { refreshCount += 1 }
        let second = SettingsAlertsTab.requestAuthorization(request: { request }) { refreshCount += 1 }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(refreshCount, 0)
        try XCTUnwrap(reply).resume(returning: false)
        await first.value
        await second.value
        XCTAssertEqual(refreshCount, 2)
    }

    func testAlreadyDeniedPermissionStillRefreshesTheNotice() async {
        var refreshed = false
        let update = SettingsAlertsTab.requestAuthorization(request: { Task { false } }) {
            refreshed = true
        }
        await update.value
        XCTAssertTrue(refreshed)
    }

    func testConditionMatrixShowsBothColumnsAndAllRowsInEveryLanguageAndAppearance() async throws {
        let suite = "EgasuTests.AlertConditions.Rendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplaySettingsStore(defaults: defaults)
        let notifications = NotificationSettingsStore(defaults: defaults)
        notifications.warning = true
        notifications.critical = true

        for language in LanguageSetting.allCases {
            for appearance in [ColorScheme.light, .dark] {
                for shown in [true, false] {
                    display.showsWarning = shown
                    display.showsCritical = shown
                    display.showsBurningFast = shown
                    display.showsUseItOrLoseIt = shown
                    notifications.closeToRunningOut = !shown
                    notifications.useItOrLoseIt = !shown
                    let (image, expected) = try L10n.withLanguage(language) {
                        let expected = [
                            L10n.settings("Show in Priority"), L10n.settings("Receive Alerts"),
                            L10n.settings("Warning"), L10n.settings("Critical"),
                            L10n.dashboard("Burning Fast"), L10n.dashboard("Use It or Lose It")
                        ]
                        let view = Form {
                            SettingsAlertConditionsSection(display: display, notifications: notifications)
                        }
                        .formStyle(.grouped)
                        .scrollContentBackground(.hidden)
                        .scrollIndicators(.never)
                        .contentMargins(.horizontal, PanelMetrics.margin - 20, for: .scrollContent)
                        .contentMargins(.top, DashboardContentView.barGap - 20, for: .scrollContent)
                        .contentMargins(.bottom, PanelMetrics.margin - 20, for: .scrollContent)
                        .frame(width: PanelMetrics.width, height: 300)
                        .background(appearance == .light ? Color.white : Color.black)
                        .environment(\.colorScheme, appearance)
                        let host = NSHostingView(rootView: view)
                        let window = NSWindow(
                            contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300),
                            styleMask: .borderless, backing: .buffered, defer: false
                        )
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                        window.contentView = host
                        defer { window.close() }
                        let bitmap = try settingsBitmap(in: host, scale: 4)
                        if let path = ProcessInfo.processInfo.environment["EGASU_ALERT_CONDITION_SCREENSHOTS"] {
                            let directory = URL(fileURLWithPath: path)
                            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            let name = "\(language.rawValue)-\(appearance)-display-\(shown).png"
                            try png.write(to: directory.appendingPathComponent(name))
                        }
                        return (try XCTUnwrap(bitmap.cgImage), expected)
                    }
                    let detected = try await Task.detached {
                        let analysisImage: CGImage
                        if appearance == .dark {
                            let inverted = CIImage(cgImage: image).applyingFilter("CIColorInvert")
                            let context = CIContext(options: [.useSoftwareRenderer: true])
                            analysisImage = try XCTUnwrap(context.createCGImage(inverted, from: inverted.extent))
                        } else {
                            analysisImage = image
                        }
                        let request = VNRecognizeTextRequest()
                        request.recognitionLanguages = [language.locale.identifier, "en-US"]
                        try VNImageRequestHandler(cgImage: analysisImage).perform([request])
                        let lines = (request.results ?? []).map { $0.topCandidates(3).map(\.string) }
                        let primary = lines.compactMap(\.first).joined().filter { !$0.isWhitespace }
                        let alternatives = lines.flatMap { $0 }.map { $0.filter { !$0.isWhitespace } }
                        return (primary: primary, alternatives: alternatives)
                    }.value
                    for label in expected {
                        let compact = label.filter { !$0.isWhitespace }
                        XCTAssertTrue(
                            detected.primary.contains(compact)
                                || detected.alternatives.contains { $0.contains(compact) },
                            "\(language) \(appearance) \(label): \(detected.primary)"
                        )
                    }
                }
            }
        }
    }
}
