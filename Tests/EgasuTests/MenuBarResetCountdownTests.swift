import XCTest

@testable import Egasu

@MainActor
final class MenuBarResetCountdownTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testCompactLocalizedUnitsAndTheirBoundaries() {
        let samples: [(LanguageSetting, [String])] = [
            (.english, ["6d+", "4h+", "1h+", "59m", "32m", "1m", "<1m"]),
            (.korean, ["6일+", "4시간+", "1시간+", "59분", "32분", "1분", "1분 미만"]),
            (.japanese, ["6日+", "4時間+", "1時間+", "59分", "32分", "1分", "1分未満"])
        ]
        let seconds: [TimeInterval] = [6 * 86_400 + 7200, 4 * 3_600 + 60, 3_600, 3_599.5, 32 * 60, 60, 59.5]
        for (language, expected) in samples {
            L10n.withLanguage(language) {
                XCTAssertEqual(
                    seconds.compactMap { MenuBarResetCountdown(reset: now.addingTimeInterval($0), now: now)?.text },
                    expected)
                XCTAssertNil(MenuBarResetCountdown(reset: now, now: now))
                XCTAssertNil(MenuBarResetCountdown(reset: now.addingTimeInterval(-1), now: now))
            }
        }
    }

    func testEachPinnedQuotaHasItsOwnTimeNextUpdateAndAccessibleValue() throws {
        try L10n.withLanguage(.english) {
            let session = line("Session", seconds: 32 * 60 + 10, remaining: true)
            let week = line("Weekly", seconds: 6 * 86_400 + 3_600 + 7)
            let content = makeContent([session, week], at: now)
            XCTAssertEqual(content.items.map(\.displayedValue), ["90% 32m", "10% 6d+"])
            let nextTick = try XCTUnwrap(content.nextInvalidation)
            XCTAssertGreaterThan(nextTick, now.addingTimeInterval(7))
            XCTAssertLessThan(nextTick, now.addingTimeInterval(7.01))
            XCTAssertTrue(content.accessibilityText.contains("Codex — Work Session 90%, Resets in 32m"))
            XCTAssertTrue(content.accessibilityText.contains("Codex — Work Weekly 10%, Resets in 6d+"))
            let image = try XCTUnwrap(MenuBarStripRenderer.image(for: content))
            XCTAssertEqual(image.accessibilityDescription, content.accessibilityText)
            let tick = makeContent([session, week], at: nextTick)
            XCTAssertGreaterThan(try XCTUnwrap(tick.nextInvalidation), nextTick)
            XCTAssertIdentical(image, try XCTUnwrap(MenuBarStripRenderer.image(for: tick)))
            let minuteLater = makeContent([session, week], at: now.addingTimeInterval(60))
            XCTAssertEqual(minuteLater.items.map(\.displayedValue), ["90% 31m", "10% 6d+"])
            XCTAssertNotIdentical(image, try XCTUnwrap(MenuBarStripRenderer.image(for: minuteLater)))
            let last = makeContent([session], at: try XCTUnwrap(session.data.resetsAt).addingTimeInterval(-1))
            XCTAssertEqual(last.items.first?.displayedValue, "90% <1m")
            XCTAssertEqual(last.nextInvalidation, session.data.resetsAt)
            let expired = makeContent([session], at: try XCTUnwrap(last.nextInvalidation))
            XCTAssertEqual(expired.items.first?.displayedValue, "90%")
            XCTAssertNil(expired.nextInvalidation)
        }
    }

    func testCountdownRendersOnTheValueLineWithAnAccountLabelOrNoVisibleLabel() throws {
        for visibleLabel in ["Work", ""] {
            var item = MenuBarContent.Item(
                id: "codex.weekly", icon: .providerMark("codex"), providerName: "Codex — Work", badge: "7d",
                label: "Weekly", shortLabel: visibleLabel, value: "90%", fraction: 0.9
            )
            let off = try XCTUnwrap(MenuBarStripRenderer.image(for: MenuBarContent(items: [item])))
            item.resetCountdown = "32m"
            let on = try XCTUnwrap(MenuBarStripRenderer.image(for: MenuBarContent(items: [item])))
            XCTAssertEqual(item.displayedValue, "90% 32m")
            XCTAssertEqual(item.shortLabel, visibleLabel)
            XCTAssertEqual(item.badge, "7d")
            XCTAssertNotIdentical(off, on)
            XCTAssertGreaterThan(on.size.width, off.size.width)
            XCTAssertTrue(on.accessibilityDescription?.contains("Codex — Work Weekly 90%") == true)
        }
    }

    func testOffBarsIconOnlyAndIneligibleRowsHaveNoCountdownTick() {
        let session = line("Session", seconds: 60)
        let none = line("Weekly", seconds: nil)
        let cost = line("Cost", kind: .dollars, seconds: 60)
        let forecast = line("Forecast", seconds: 60, forecast: true)
        let icon = makeContent([session], at: now, limit: .iconOnly)
        XCTAssertTrue(icon.isEmpty)
        XCTAssertNil(icon.nextInvalidation)
        let neutral = [
            makeContent([session], at: now, enabled: false), makeContent([session], at: now, style: .bars),
            makeContent([none, cost, forecast], at: now)
        ]
        for content in neutral {
            XCTAssertFalse(content.items.isEmpty)
            XCTAssertTrue(content.items.allSatisfy { $0.resetCountdown == nil })
            XCTAssertNil(content.nextInvalidation)
        }
    }

    func testNotStartedSessionsHaveNoCountdownButActiveZeroUsageSessionsDo() {
        L10n.withLanguage(.english) {
            for remaining in [false, true] {
                var data = WidgetData(
                    title: "Session", icon: .providerMark("antigravity"), kind: .percent, used: 0, limit: 100,
                    displayMode: remaining ? .remaining : .used, resetsAt: now.addingTimeInterval(7_200)
                )
                data.sessionStartSignal = .zeroUsage
                let descriptor = WidgetDescriptor(
                    id: "antigravity.geminiPro", providerID: "antigravity", metricLabel: "Session", sample: data)
                let notStarted = makeContent([DashboardLine(descriptor: descriptor, data: data)], at: now)
                XCTAssertNil(notStarted.items.first?.resetCountdown)
                XCTAssertNil(notStarted.nextInvalidation)
                XCTAssertFalse(notStarted.accessibilityText.contains("Resets in"))

                data.sessionStartSignal = .missingResetDate
                let active = makeContent([DashboardLine(descriptor: descriptor, data: data)], at: now)
                XCTAssertEqual(active.items.first?.resetCountdown, "2h+")
                XCTAssertNotNil(active.nextInvalidation)
            }
        }
    }

    func testDefaultAndStoredOption() throws {
        let suite = "MenuBarResetCountdownTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = DisplaySettingsStore(defaults: defaults)
        XCTAssertFalse(settings.showsMenuBarResetCountdown)
        settings.showsMenuBarResetCountdown = true
        XCTAssertTrue(DisplaySettingsStore(defaults: defaults).showsMenuBarResetCountdown)
        XCTAssertTrue(PriorityIconsPreview.sample(limit: .upToThree).items.allSatisfy { $0.resetCountdown == nil })
        XCTAssertEqual(
            PriorityIconsPreview.sample(limit: .upToThree, showResetCountdown: true).items.compactMap(\.resetCountdown)
                .count, 3)
    }

    private func line(
        _ label: String, kind: MetricKind = .percent, seconds: Double?, remaining: Bool = false, forecast: Bool = false
    ) -> DashboardLine {
        let data = WidgetData(
            title: label, icon: .providerMark("codex"), kind: kind, used: 10, limit: 100,
            displayMode: remaining ? .remaining : .used, forecast: forecast ? .init() : nil,
            resetsAt: seconds.map(now.addingTimeInterval)
        )
        let descriptor = WidgetDescriptor(id: "codex.\(label)", providerID: "codex", metricLabel: label, sample: data)
        return DashboardLine(descriptor: descriptor, data: data)
    }

    private func makeContent(
        _ lines: [DashboardLine], at time: Date, enabled: Bool = true, limit: MenuBarLimit = .upToFive,
        style: MenuBarStyle = .text
    ) -> MenuBarContent {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let account = DashboardAccount(provider: provider, providerName: "Codex", name: "Work", lines: lines)
        let board = PriorityBoard.make(accounts: [account], pinned: Set(lines.map(\.id)), now: time)
        return MenuBarContentBuilder.build(
            board: board, limit: limit, selection: .pinnedOnly, style: style, showResetCountdown: enabled, now: time
        )
    }
}
