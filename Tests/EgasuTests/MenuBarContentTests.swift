import XCTest
@testable import Egasu

@MainActor
final class MenuBarContentTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    func testPinnedOnlyKeepsAccountOrderAcrossEveryUsageState() {
        var calmData = line("codex.calm", used: 10).data
        calmData.resetsAt = now.addingTimeInterval(2 * 86_400)
        let calm = DashboardLine(descriptor: descriptor("codex.calm"), data: calmData)
        var soonData = line("codex.soon", used: 10).data
        soonData.resetsAt = now.addingTimeInterval(3_600)
        let soon = DashboardLine(descriptor: descriptor("codex.soon"), data: soonData)
        let pins: Set<String> = ["codex.calm", "codex.spent", "codex.low", "codex.soon", "codex@work.weekly"]
        let accounts = [
            account("codex", [calm, line("codex.spent", used: 100), line("codex.low", used: 95), soon, line("codex.unpinned", used: 99)]),
            account("codex@work", [line("codex@work.weekly", used: 80)]),
        ]
        let board = PriorityBoard.make(accounts: accounts, pinned: pins, useItOrLoseIt: true, now: now)
        let expected = ["codex.calm", "codex.spent", "codex.low", "codex.soon", "codex@work.weekly"]
        XCTAssertEqual(board.pinned.map(\.id), expected)
        XCTAssertTrue(board.usedUp.isEmpty)
        XCTAssertTrue(board.useItOrLoseIt.isEmpty)
        for style in MenuBarStyle.allCases {
            let shown = MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .pinnedOnly, style: style, now: now)
            XCTAssertEqual(shown.items.map(\.id), expected)
            XCTAssertNil(shown.nextInvalidation, "고정 전용은 소진 순위 타이머가 필요 없음")
            let capped = MenuBarContentBuilder.build(board: board, limit: .upToTwo, selection: .pinnedOnly, style: style, now: now)
            XCTAssertEqual(capped.items.map(\.id), Array(expected.prefix(2)))
            XCTAssertEqual(capped.overflow, 3, "소진된 고정 지표도 표시 개수에 포함")
        }

        let changed = PriorityBoard.make(accounts: [
            account("codex", [line("codex.calm", used: 100), line("codex.spent", used: 10), line("codex.low", used: 20),
                              line("codex.soon", used: 95), line("codex.unpinned", used: 99)]), accounts[1],
        ], pinned: pins, useItOrLoseIt: true, now: now)
        XCTAssertEqual(MenuBarContentBuilder.build(board: changed, limit: .upToFive, selection: .pinnedOnly, now: now).items.map(\.id), expected)
    }

    func testPinnedOnlyNeverFillsEmptySlotsWithAutomaticCandidates() {
        let lines = [line("codex.low", used: 95), line("codex.spent", used: 100)]
        let noPins = makeBoard(lines: lines)
        XCTAssertTrue(MenuBarContentBuilder.build(board: noPins, limit: .upToFive, selection: .pinnedOnly, now: now).isEmpty)
        let pinned = PriorityBoard.make(accounts: [account("codex", lines)], pinned: ["codex.spent"], now: now)
        let content = MenuBarContentBuilder.build(board: pinned, limit: .upToFive, selection: .pinnedOnly, now: now)
        XCTAssertEqual(content.items.map(\.id), ["codex.spent"])
        XCTAssertEqual(content.overflow, 0)
        XCTAssertTrue(MenuBarContentBuilder.build(board: pinned, limit: .iconOnly, selection: .pinnedOnly, now: now).isEmpty)
    }

    func testPinnedOnlyFiltersMissingDataAndUnboundedBarsBeforeCounting() {
        var missingData = line("codex.missing", used: 90).data
        missingData.hasData = false
        let missing = DashboardLine(descriptor: descriptor("codex.missing"), data: missingData)
        let spend = DashboardLine(descriptor: descriptor("codex.today"), data: WidgetData(
            title: "Today", icon: .providerMark("codex"), kind: .dollars, used: 12, limit: nil
        ))
        let lines = [missing, spend, line("codex.weekly", used: 20), line("codex.session", used: 10), line("codex.unpinned", used: 95)]
        let board = PriorityBoard.make(accounts: [account("codex", lines)], pinned: Set(lines.dropLast().map(\.id)), now: now)
        let bars = MenuBarContentBuilder.build(board: board, limit: .upToOne, selection: .pinnedOnly, style: .bars, now: now)
        XCTAssertEqual(bars.items.map(\.id), ["codex.weekly"])
        XCTAssertEqual(bars.overflow, 1)
        let text = MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .pinnedOnly, now: now)
        XCTAssertEqual(text.items.map(\.id), ["codex.today", "codex.weekly", "codex.session"])
    }

    func testPinnedOnlyStillSchedulesTheShownForecastDeadline() {
        var watchData = line("codex.resetWatch", used: 65).data
        watchData.forecast = .init(deadline: now.addingTimeInterval(120), communityYesPercent: 60)
        let watch = DashboardLine(descriptor: descriptor("codex.resetWatch"), data: watchData)
        let board = PriorityBoard.make(accounts: [account("codex", [watch, line("codex.unpinned", used: 95)])],
                                       pinned: [watch.id], now: now)
        let content = MenuBarContentBuilder.build(board: board, limit: .upToTwo, selection: .pinnedOnly, now: now)
        XCTAssertEqual(content.items.map(\.id), [watch.id])
        XCTAssertEqual(content.nextInvalidation, watch.data.forecastDeadline)
    }

    func testOverflowCountUpdatesWhenACachedForecastExpires() {
        let deadline = now.addingTimeInterval(120)
        let weekly = line("codex.weekly", used: 50)
        var watchData = line("codex.resetWatch", used: 65).data
        watchData.forecast = .init(deadline: deadline, refreshFailed: true)
        let watch = DashboardLine(descriptor: descriptor("codex.resetWatch"), data: watchData)
        let board = PriorityBoard.make(
            accounts: [account("codex", [weekly, watch])], pinned: [weekly.id, watch.id], now: now
        )

        for style in MenuBarStyle.allCases {
            let active = MenuBarContentBuilder.build(
                board: board, limit: .upToOne, selection: .pinnedOnly, style: style, now: now
            )
            XCTAssertEqual(active.items.map(\.id), [weekly.id])
            XCTAssertEqual(active.overflow, 1)
            XCTAssertEqual(active.nextInvalidation, deadline)

            let expired = MenuBarContentBuilder.build(
                board: board, limit: .upToOne, selection: .pinnedOnly, style: style, now: deadline
            )
            XCTAssertEqual(expired.items.map(\.id), [weekly.id])
            XCTAssertEqual(expired.overflow, 0)
            XCTAssertNil(expired.nextInvalidation)
        }
    }

    func testUnusedWeeklyLimitUpdatesAtBothMenuBarPriorityBoundaries() {
        let weekly = line("codex.weekly", used: 10)
        guard let reset = weekly.data.resetsAt else { return XCTFail("Missing reset date") }
        let start = reset.addingTimeInterval(-PaceNotificationLogic.useItOrLoseItLead)
        let accounts = [account("codex", [weekly])]
        func content(at date: Date, selection: MenuBarSelection = .priority, enabled: Bool = true) -> MenuBarContent {
            let board = PriorityBoard.make(accounts: accounts, useItOrLoseIt: enabled, now: date)
            return MenuBarContentBuilder.build(board: board, limit: .upToOne, selection: selection, now: date)
        }
        let before = content(at: start.addingTimeInterval(-1))
        XCTAssertTrue(before.items.isEmpty)
        XCTAssertEqual(before.nextInvalidation, start)
        let during = content(at: start)
        XCTAssertEqual(during.items.map(\.id), [weekly.id])
        XCTAssertEqual(during.nextInvalidation, reset)
        let after = content(at: reset)
        XCTAssertTrue(after.items.isEmpty)
        XCTAssertNil(after.nextInvalidation)
        XCTAssertNil(content(at: start, selection: .runningOut).nextInvalidation)
        XCTAssertNil(content(at: start, selection: .pinnedOnly).nextInvalidation)
        XCTAssertNil(content(at: start, enabled: false).nextInvalidation)
    }

    func testBarsSkipUnboundedPinsBeforeApplyingTheLimit() {
        let spend = WidgetData(title: "Today", icon: .providerMark("codex"), kind: .dollars, used: 12, limit: nil)
        let lines = [DashboardLine(descriptor: descriptor("codex.today"), data: spend)]
            + [line("codex.weekly", used: 95), line("codex.session", used: 85), line("codex.spark", used: 75)]
        let board = PriorityBoard.make(accounts: [account("codex", lines)], pinned: ["codex.today"], now: now)
        let bars = MenuBarContentBuilder.build(board: board, limit: .upToTwo, selection: .priority, style: .bars, now: now)
        XCTAssertEqual(bars.items.map(\.id), ["codex.weekly", "codex.session"])
        XCTAssertEqual(bars.items.compactMap(\.fraction), [0.95, 0.85])
        XCTAssertEqual(bars.overflow, 1)
        let text = MenuBarContentBuilder.build(board: board, limit: .upToTwo, selection: .priority, now: now)
        XCTAssertEqual(text.items.map(\.id), ["codex.today", "codex.weekly"])
        XCTAssertNil(text.items.first?.fraction)
    }

    func testBarsUseTheSelectedUsedOrRemainingDirectionAndSupportFiveItems() throws {
        let lines = (0..<5).map { index -> DashboardLine in
            let original = line("codex.\(index)", used: 90)
            var data = original.data
            data.displayMode = .remaining
            return DashboardLine(descriptor: original.descriptor, data: data)
        }
        let board = makeBoard(lines: lines)
        let content = MenuBarContentBuilder.build(board: board, limit: .upToFive, style: .bars, now: now)
        XCTAssertEqual(content.items.count, 5)
        for item in content.items { XCTAssertEqual(try XCTUnwrap(item.fraction), 0.1, accuracy: 0.0001) }
        XCTAssertTrue(MenuBarContentBuilder.build(board: board, limit: .iconOnly, style: .bars, now: now).isEmpty)
    }

    func testDefaultShowsOnlyRunningOutUpToTheLimitWithOverflow() {
        let board = makeBoard(lines: [
            line("codex.weekly", used: 95),
            line("codex.session", used: 85),
            line("codex.spark", used: 75),
            line("codex.sparkWeekly", used: 72),
            line("codex.credits", used: 10),
        ])
        let content = MenuBarContentBuilder.build(board: board, limit: .upToThree, now: now)
        XCTAssertEqual(content.items.map(\.id), ["codex.weekly", "codex.session", "codex.spark"])
        XCTAssertEqual(content.overflow, 1, "+N은 소진 임박만 셈")
    }

    func testPrioritySelectionFollowsPriorityOrder() {
        var board = makeBoard(lines: [line("codex.weekly", used: 95), line("codex.session", used: 100), line("codex.credits", used: 10)])
        board = PriorityBoard.make(accounts: [account("codex", board.attention.map(\.line) + board.usedUp.map(\.line) + [line("codex.credits", used: 10)])],
                                   pinned: ["codex.credits"], now: now)
        let content = MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .priority, now: now)
        XCTAssertEqual(content.items.map(\.id), ["codex.credits", "codex.weekly", "codex.session"], "고정 → 소진 임박 → 소진됨")
    }

    func testPriorityKeepsPinnedSpentItemsFirstWithoutDuplicatingThem() {
        let lines = [line("codex.spent", used: 100), line("codex.pinnedLow", used: 95),
                     line("codex.low", used: 90), line("codex.unpinnedSpent", used: 100)]
        let board = PriorityBoard.make(accounts: [account("codex", lines)], pinned: ["codex.spent", "codex.pinnedLow"], now: now)
        for style in MenuBarStyle.allCases {
            let all = MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .priority, style: style, now: now)
            XCTAssertEqual(all.items.map(\.id), lines.map(\.id))
            XCTAssertEqual(all.overflow, 0)
            let capped = MenuBarContentBuilder.build(board: board, limit: .upToOne, selection: .priority, style: style, now: now)
            XCTAssertEqual(capped.items.map(\.id), ["codex.spent"])
            XCTAssertEqual(capped.overflow, 2, "고정한 소진 지표는 고정 목록에 포함, 고정하지 않은 소진 지표는 제외")
            let automatic = MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .runningOut, style: style, now: now)
            XCTAssertEqual(automatic.items.map(\.id), ["codex.pinnedLow", "codex.low"], "고정한 경고가 자동 메뉴 막대에서 빠지지 않음")
        }
    }

    func testPrioritySelectionListsUsedUpAfterRunningOutWithoutCountingIt() {
        let board = makeBoard(lines: [
            line("codex.spent", used: 100),
            line("codex.spentToo", used: 100),
            line("codex.low", used: 95),
            line("codex.lower", used: 90),
        ])
        let one = MenuBarContentBuilder.build(board: board, limit: .upToOne, selection: .priority, now: now)
        XCTAssertEqual(one.items.map(\.id), ["codex.low"])
        XCTAssertEqual(one.overflow, 1, "기다리는 것은 codex.lower뿐 — 소진됨은 +N에 세지 않음")

        let five = MenuBarContentBuilder.build(board: board, limit: .upToFive, selection: .priority, now: now)
        XCTAssertEqual(five.items.map(\.id), ["codex.low", "codex.lower", "codex.spent", "codex.spentToo"])
        XCTAssertEqual(five.overflow, 0)
    }

    func testAStripFullOfRunningOutLeavesUsedUpOutOfTheCount() {
        let board = makeBoard(lines: [
            line("codex.a", used: 95), line("codex.b", used: 92), line("codex.c", used: 90),
            line("codex.x", used: 100), line("codex.y", used: 100), line("codex.z", used: 100),
        ])
        let strip = MenuBarContentBuilder.build(board: board, limit: .upToThree, selection: .priority, now: now)
        XCTAssertEqual(strip.items.map(\.id), ["codex.a", "codex.b", "codex.c"])
        XCTAssertEqual(strip.overflow, 0, "칸이 소진 임박으로 차도 소진됨은 +N에 들어가지 않음")
    }

    func testIconOnlyAndNothingToShowAreEmpty() {
        let calm = makeBoard(lines: [line("codex.weekly", used: 10)])
        XCTAssertTrue(MenuBarContentBuilder.build(board: calm, limit: .upToThree, now: now).isEmpty)
        let busy = makeBoard(lines: [line("codex.weekly", used: 95)])
        XCTAssertTrue(MenuBarContentBuilder.build(board: busy, limit: .iconOnly, now: now).isEmpty)
    }

    func testInitialsBadgeOnlyWhenAProviderHasSeveralAccounts() {
        let first = DashboardAccount(provider: provider("codex"), providerName: "Codex", name: "Account 1", lines: [line("codex.weekly", used: 95)])
        let second = DashboardAccount(provider: provider("codex@ab12cd34"), providerName: "Codex", name: "Account 2", lines: [line("codex@ab12cd34.weekly", used: 92)])
        let board = PriorityBoard.make(accounts: [first, second], now: now)
        let families = MenuBarContentBuilder.multiAccountFamilies([first, second])
        XCTAssertEqual(families, ["codex"])
        let content = MenuBarContentBuilder.build(board: board, limit: .upToThree, multiAccountFamilies: families, now: now)
        XCTAssertEqual(content.items.map(\.badge), ["A1", "A2"])

        let alone = PriorityBoard.make(accounts: [first], now: now)
        let single = MenuBarContentBuilder.multiAccountFamilies([first])
        XCTAssertEqual(MenuBarContentBuilder.build(board: alone, limit: .upToThree, multiAccountFamilies: single, now: now).items.map(\.badge), [nil])
    }

    func testShortLabelDropsGenericTrailingWord() {
        XCTAssertEqual(MenuBarContentBuilder.shortLabel("Premium Usage"), "Premium")
        XCTAssertEqual(MenuBarContentBuilder.shortLabel("Weekly"), "Weekly")
        XCTAssertEqual(MenuBarContentBuilder.shortLabel("Gemini Pro Models"), "Gemini Pro")
    }

    func testAccountInitials() {
        XCTAssertEqual(AccountInitials.tag(for: "Personal"), "P")
        XCTAssertEqual(AccountInitials.tag(for: "Attention Machine 1"), "A1")
        XCTAssertEqual(AccountInitials.tag(for: ""), "")
    }

    func testBoundedTrayValuesStayUnitAware() {
        // percent는 %, bounded dollars/counts는 고유 단위 유지 — "used / limit" %로 붕괴 금지
        XCTAssertEqual(WidgetData(title: "Usage", icon: .providerMark("cursor"), kind: .percent, used: 67, limit: 100).menuBarValue, "67%")
        XCTAssertEqual(WidgetData(title: "Credits", icon: .providerMark("cursor"), kind: .dollars, used: 12000, limit: 18000).menuBarValue, "$12K")
        XCTAssertEqual(WidgetData(title: "Requests", icon: .providerMark("cursor"), kind: .count, used: 412, limit: 500).menuBarValue, "412")
    }

    func testRankingClockSchedulesAThirtySecondRerender() {
        // 기간 절반 경과, 사용 60% → 빠른 소진 — 순위가 시간에 따라 바뀌므로 30초 뒤 재렌더.
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: 60, limit: 100)
        data.resetsAt = now.addingTimeInterval(3.5 * 86_400)
        data.periodDurationMs = 7 * 86_400_000
        for pins in [Set<String>(), Set(["codex.weekly"])] {
            let board = PriorityBoard.make(accounts: [account("codex", [DashboardLine(descriptor: descriptor("codex.weekly"), data: data)])],
                                           pinned: pins, burningFast: BurningFast(), now: now)
            let content = MenuBarContentBuilder.build(board: board, limit: .upToThree, now: now)
            XCTAssertEqual(content.items.map(\.id), ["codex.weekly"])
            XCTAssertEqual(content.nextInvalidation, now.addingTimeInterval(MenuBarContentBuilder.rankingTick))
            let priority = MenuBarContentBuilder.build(board: board, limit: .upToThree, selection: .priority, now: now)
            XCTAssertEqual(priority.items.map(\.id), ["codex.weekly"])
            XCTAssertEqual(priority.nextInvalidation, pins.isEmpty ? content.nextInvalidation : nil)
        }
    }

    // MARK: - Fixtures

    private func makeBoard(lines: [DashboardLine]) -> PriorityBoard {
        PriorityBoard.make(accounts: [account("codex", lines)], now: now)
    }

    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: "Codex", icon: .providerMark("codex"))
    }

    private func account(_ id: String, _ lines: [DashboardLine]) -> DashboardAccount {
        DashboardAccount(provider: provider(id), providerName: "Codex", name: nil, lines: lines)
    }

    private func descriptor(_ id: String) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id, providerID: ProviderAccountID.providerID(ofMetric: id), metricLabel: id,
            sample: WidgetData(title: id, icon: .providerMark("codex"), kind: .percent, used: 0, limit: 100)
        )
    }

    private func line(_ id: String, used: Double) -> DashboardLine {
        var data = WidgetData(title: id, icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(86_400)
        data.periodDurationMs = 7 * 86_400_000
        return DashboardLine(descriptor: descriptor(id), data: data)
    }
}

@MainActor
final class MenuBarStarMigrationTests: XCTestCase {
    func testDefaultStarSetIsNotMigrated() {
        let defaults = scratchDefaults()
        defaults.set(DefaultLayout.pinnedMetricIDs, forKey: "layout.menuBarPins")
        let layout = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout") { $0 != "claude" }
        XCTAssertNil(layout.migrateMenuBarStars())
        XCTAssertTrue(layout.priorityPinIDs.isEmpty)
        XCTAssertNotNil(defaults.object(forKey: "layout.priorityPins"), "완료 표시로 키 기록")
        XCTAssertNil(makeLayout(defaults, defaultStars: []).migrateMenuBarStars(), "두 번째 실행은 이전하지 않음")
    }

    func testCustomStarsBecomePinsOnShownMetricsOnly() {
        let defaults = scratchDefaults()
        defaults.set(["claude.session", "codex.weekly"], forKey: "layout.menuBarPins")
        let layout = makeLayout(defaults, defaultStars: ["claude.weekly"])
        layout.setMetricEnabled("codex.weekly", false)
        defaults.removeObject(forKey: "layout.priorityPins")
        let reloaded = makeLayout(defaults, defaultStars: ["claude.weekly"])
        XCTAssertEqual(reloaded.migrateMenuBarStars(), 1)
        XCTAssertEqual(reloaded.priorityPinIDs, ["claude.session"], "숨긴 지표의 별표는 버림")
    }

    func testCustomStarOnDisabledProviderReturnsAfterReenable() {
        let defaults = scratchDefaults()
        defaults.set(["claude.session"], forKey: "layout.menuBarPins")
        var claudeIsEnabled = false
        func launch() -> LayoutStore {
            LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout") { id in
                id != "claude" || claudeIsEnabled
            }
        }

        let firstLaunch = launch()
        XCTAssertEqual(firstLaunch.migrateMenuBarStars(), 1)
        XCTAssertEqual(firstLaunch.priorityPinIDs, ["claude.session"])
        XCTAssertFalse(firstLaunch.displayGroups.contains { $0.provider.id == "claude" })

        let relaunched = launch()
        XCTAssertNil(relaunched.migrateMenuBarStars())
        XCTAssertTrue(relaunched.isMetricPinned("claude.session"))
        XCTAssertFalse(relaunched.displayGroups.contains { $0.provider.id == "claude" })

        claudeIsEnabled = true
        let visibleIDs = relaunched.displayGroups.flatMap(\.widgets).map(\.descriptorID)
        XCTAssertTrue(visibleIDs.contains("claude.session"))
        XCTAssertTrue(relaunched.isMetricPinned("claude.session"))
    }

    func testStarsExpandToKnownCardsExceptRowsHiddenOnAccountCards() {
        // 별표는 패밀리 설정 — 실행 시점에 아는 모든 계정 카드로 펼치되 추가 계정에서 숨기는 행(Today)은 제외.
        let codex = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let card = Provider(id: "codex@ab12cd34", displayName: "Codex — Work", icon: .providerMark("codex"))
        let descriptors = [codex, card].flatMap { provider in
            ["weekly", "today"].map { suffix in
                WidgetDescriptor(
                    id: "\(provider.id).\(suffix)", providerID: provider.id, metricLabel: suffix,
                    sample: WidgetData(title: suffix, icon: provider.icon, kind: .percent, used: 0, limit: 100)
                )
            }
        }
        let defaults = scratchDefaults()
        defaults.set(["codex.weekly", "codex.today"], forKey: "layout.menuBarPins")
        let layout = LayoutStore(
            registry: WidgetRegistry(providers: [codex, card], descriptors: descriptors),
            defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ["codex.weekly", "codex.today"], migrationBaselineMetricIDs: ["codex.weekly", "codex.today"],
            defaultPinnedMetricIDs: []
        )

        XCTAssertEqual(layout.migrateMenuBarStars(isHiddenOnCard: AppContainer.hidesMetric(_:onCard:)), 3)
        XCTAssertEqual(layout.priorityPinIDs, ["codex.weekly", "codex@ab12cd34.weekly", "codex.today"])
    }

    func testLegacyCardStarsAreReadAsFamilyStars() {
        let defaults = scratchDefaults()
        defaults.set(["claude@profile-work.session"], forKey: "layout.menuBarPins")
        let layout = makeLayout(defaults, defaultStars: ["claude.weekly"])
        XCTAssertEqual(layout.migrateMenuBarStars(), 1)
        XCTAssertEqual(layout.priorityPinIDs, ["claude.session"])
    }

    func testNoSavedStarsMeansNoMigration() {
        let layout = makeLayout(scratchDefaults(), defaultStars: ["claude.weekly"])
        XCTAssertNil(layout.migrateMenuBarStars())
    }

    private func makeLayout(_ defaults: UserDefaults, defaultStars: [String]) -> LayoutStore {
        LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout", defaultPinnedMetricIDs: defaultStars)
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "EgasuTests.StarMigration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}
