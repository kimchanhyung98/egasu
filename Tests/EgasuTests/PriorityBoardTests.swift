import XCTest
@testable import Egasu

final class PriorityLimitsTests: XCTestCase {
    func testStandardLimits() {
        XCTAssertEqual(PriorityLimits.standard.warning, 30)
        XCTAssertEqual(PriorityLimits.standard.critical, 10)
    }

    func testValuesSnapToStepsAndRanges() {
        let limits = PriorityLimits(warning: 93, critical: 2)
        XCTAssertEqual(limits.warning, 70)
        XCTAssertEqual(limits.critical, 5)
        XCTAssertEqual(PriorityLimits(warning: 33, critical: 12).warning, 35)
    }

    func testCriticalStaysBelowWarning() {
        var limits = PriorityLimits.standard
        limits.critical = 25
        limits.warning = 25
        XCTAssertLessThan(limits.critical, limits.warning)
        XCTAssertEqual(limits.critical, 20)

        limits.critical = 25
        XCTAssertEqual(limits.warning, 30, "Critical을 올리면 Warning이 한 단계 밀림")
    }
}

final class WidgetDataSeverityTests: XCTestCase {
    func testSeverityUsesRemainingThresholdsOnly() {
        XCTAssertEqual(meter(used: 60).severity, .normal)
        XCTAssertEqual(meter(used: 70).severity, .warning, "30% 남음 = Warning 경계 포함")
        XCTAssertEqual(meter(used: 90).severity, .critical)
    }

    func testCustomLimitsChangeSeverity() {
        var data = meter(used: 55)
        data.priorityLimits = PriorityLimits(warning: 50, critical: 20)
        XCTAssertEqual(data.severity, .warning)
    }

    func testUnpacedMeterUsesSameThresholdsAsPacedOnes() {
        // 초기화 주기가 없는 지표도 사용 75%(남음 25%)면 Warning — 이전 절대 band(80%)보다 이름.
        XCTAssertEqual(meter(used: 75).severity, .warning)
    }

    func testForecastFillUsesProbabilityBands() {
        var data = WidgetData(title: "Reset Watch", icon: .providerMark("codex"), kind: .percent, used: 30, limit: 100)
        data.forecast = .init()
        XCTAssertEqual(data.severity, .normal, "예측 행은 한도가 아님")
        XCTAssertEqual(data.fillSeverity, .neutral)
        data = WidgetData(title: "Reset Watch", icon: .providerMark("codex"), kind: .percent, used: 45, limit: 100)
        data.forecast = .init()
        XCTAssertEqual(data.fillSeverity, .normal)
        data = WidgetData(title: "Reset Watch", icon: .providerMark("codex"), kind: .percent, used: 65, limit: 100)
        data.forecast = .init()
        XCTAssertEqual(data.fillSeverity, .warning)
        data = WidgetData(title: "Reset Watch", icon: .providerMark("codex"), kind: .percent, used: 99, limit: 100)
        data.forecast = .init()
        XCTAssertEqual(data.fillSeverity, .critical)
    }

    private func meter(used: Double) -> WidgetData {
        WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
    }
}

final class PriorityBoardTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let week = 7 * 24 * 60 * 60 * 1000

    func testSectionsAndOrder() {
        let account = account(
            "codex",
            lines: [
                line("codex.weekly", used: 95, resetIn: 3 * 86_400),
                line("codex.session", used: 75, resetIn: 3_600, period: 5 * 3_600_000),
                line("codex.spark", used: 100, resetIn: 86_400),
                line("codex.sparkWeekly", used: 10, resetIn: 3_600)
            ])
        let board = PriorityBoard.make(accounts: [account], useItOrLoseIt: true, now: now)

        XCTAssertEqual(board.summary, .listed)
        XCTAssertEqual(Set(board.attention.map(\.id)), ["codex.weekly", "codex.session"])
        XCTAssertEqual(board.usedUp.map(\.id), ["codex.spark"])
        XCTAssertEqual(board.useItOrLoseIt.map(\.id), ["codex.sparkWeekly"])
        XCTAssertFalse(board.showsClearRow)
    }

    func testPinnedMetricStaysPinnedThroughWarningSpentAndReset() {
        for used in [20.0, 75, 95, 100, 0] {
            let account = account("codex", lines: [line("codex.weekly", used: used, resetIn: 3 * 86_400)])
            let board = PriorityBoard.make(accounts: [account], pinned: ["codex.weekly"], now: now)
            XCTAssertEqual(board.pinned.map(\.id), ["codex.weekly"], "used=\(used)")
            XCTAssertEqual(board.pinned.first?.data.used, used)
            XCTAssertTrue(board.attention.isEmpty)
            XCTAssertTrue(board.usedUp.isEmpty)
            XCTAssertTrue(board.useItOrLoseIt.isEmpty)
            let runningOut = used >= 70 && used < 100
            XCTAssertEqual(board.runningOut.map(\.id), runningOut ? ["codex.weekly"] : [])
            XCTAssertEqual(board.showsClearRow, !runningOut, "고정한 경고도 All Clear 판정에 포함")
            if used == 100 {
                XCTAssertEqual(board.pinned.first?.item?.reason, .usedUp(resetsAt: now.addingTimeInterval(3 * 86_400)))
            } else if runningOut {
                XCTAssertEqual(board.pinned.first?.item?.reason.severity, used >= 90 ? .critical : .warning)
            } else {
                XCTAssertNil(board.pinned.first?.item)
            }
        }
    }

    func testPinnedStatesKeepSavedOrderAndDoNotDuplicateAutomaticSections() throws {
        let pinnedLines = [
            line("codex.spent", used: 100, resetIn: 86_400),
            line("codex.low", used: 95, resetIn: 3 * 86_400),
            line("codex.fast", used: 60, resetIn: 3.5 * 86_400),
            line("codex.soon", used: 10, resetIn: 3_600),
            line("codex.calm", used: 10, resetIn: 6 * 86_400)
        ]
        let other = account(
            "codex@work",
            lines: [
                line("codex@work.low", used: 95, resetIn: 3 * 86_400),
                line("codex@work.spent", used: 100, resetIn: 86_400),
                line("codex@work.soon", used: 10, resetIn: 3_600)
            ])
        let accounts = [account("codex", lines: pinnedLines), other]
        let board = PriorityBoard.make(
            accounts: accounts, pinned: Set(pinnedLines.map(\.id)),
            burningFast: BurningFast(), useItOrLoseIt: true, now: now)
        XCTAssertEqual(board.pinned.map(\.id), pinnedLines.map(\.id))
        XCTAssertEqual(board.attention.map(\.id), ["codex@work.low"])
        XCTAssertEqual(board.usedUp.map(\.id), ["codex@work.spent"])
        XCTAssertEqual(board.useItOrLoseIt.map(\.id), ["codex@work.soon"])
        XCTAssertEqual(Set(board.runningOut.map(\.id)), ["codex.low", "codex.fast", "codex@work.low"])

        let unpinned = PriorityBoard.make(accounts: accounts, burningFast: BurningFast(), useItOrLoseIt: true, now: now)
        XCTAssertTrue(unpinned.pinned.isEmpty)
        XCTAssertEqual(Set(unpinned.attention.map(\.id)), ["codex.low", "codex.fast", "codex@work.low"])
        XCTAssertEqual(Set(unpinned.usedUp.map(\.id)), ["codex.spent", "codex@work.spent"])
        XCTAssertEqual(Set(unpinned.useItOrLoseIt.map(\.id)), ["codex.soon", "codex@work.soon"])
    }

    func testMissingPinnedQuotaStaysHiddenWhileItsAccountNoticeRemains() {
        let original = line("codex.weekly", used: 0, resetIn: 86_400)
        var missing = original.data
        missing.hasData = false
        let account = account("codex", lines: [.init(descriptor: original.descriptor, data: missing)])
        let board = PriorityBoard.make(accounts: [account], pinned: ["codex.weekly"], now: now) { _ in
            .unavailable("Session expired")
        }
        XCTAssertTrue(account.lines.isEmpty)
        XCTAssertTrue(board.pinned.isEmpty)
        XCTAssertEqual(board.summary, .unavailable)
        XCTAssertEqual(board.notices.first?.account.id, "codex")
        XCTAssertFalse(board.showsClearRow)
        XCTAssertFalse(board.hasRows)
    }

    func testForecastChartAndPeriodRowsNeverEnterAutomaticSections() {
        var forecast = WidgetData(
            title: "Reset Watch", icon: .providerMark("codex"), kind: .percent, used: 99, limit: 100)
        forecast.forecast = .init()
        var chart = WidgetData(title: "Usage Trend", icon: .providerMark("codex"), kind: .count, used: 0, limit: nil)
        chart.isChart = true
        let account = account(
            "codex",
            lines: [
                DashboardLine(descriptor: descriptor("codex.resetWatch"), data: forecast),
                DashboardLine(descriptor: descriptor("codex.trend"), data: chart)
            ])
        let board = PriorityBoard.make(accounts: [account], burningFast: BurningFast(), useItOrLoseIt: true, now: now)
        XCTAssertTrue(board.attention.isEmpty)
        XCTAssertTrue(board.usedUp.isEmpty)
        XCTAssertTrue(board.useItOrLoseIt.isEmpty)
        XCTAssertEqual(board.summary, .noReportedLimits)
    }

    func testAllClearRequiresAReportedLimit() {
        let empty = PriorityBoard.make(accounts: [account("cursor", lines: [])], now: now)
        XCTAssertEqual(empty.summary, .noReportedLimits)
        XCTAssertFalse(empty.showsClearRow)
        let reported = PriorityBoard.make(
            accounts: [account("codex", lines: [line("codex.weekly", used: 10, resetIn: 3 * 86_400)])], now: now)
        XCTAssertEqual(reported.summary, .allClear)
        XCTAssertTrue(reported.showsClearRow)
    }

    func testWaitingAndNoticesDecideSummary() {
        let waiting = DashboardAccount(
            provider: provider("cursor"), providerName: "Cursor", name: nil, lines: [],
            waitingMetricIDs: ["cursor.usage"])
        XCTAssertEqual(PriorityBoard.make(accounts: [waiting], now: now).summary, .waitingForUsage)

        let failing = account("cursor", lines: [])
        let board = PriorityBoard.make(accounts: [failing], now: now) { _ in .unavailable("Session expired") }
        XCTAssertEqual(board.summary, .unavailable)
        XCTAssertEqual(board.notices.first?.message, "Session expired")
    }

    func testAccountNameSwitchesToTheLoginEmailButShareImagesNeverShowIt() {
        let named = DashboardAccount(
            provider: provider("codex"), providerName: "Codex", name: "work", email: "me@example.com", isInUse: true,
            lines: [])
        XCTAssertEqual(named.showingEmail.subtitle, "me@example.com")
        XCTAssertTrue(named.showingEmail.isNamedByEmail, "긴 이메일은 가운데 생략")
        XCTAssertEqual(named.showingEmail.email, "me@example.com", "다시 눌러 계정명으로 돌아갈 수 있음")
        XCTAssertTrue(named.showingEmail.isInUse, "이메일 표시로 바꿔도 사용 중 계정 강조 유지")
        XCTAssertEqual(named.hidingEmail.subtitle, "work")
        XCTAssertTrue(named.hidingEmail.isInUse)
        XCTAssertNil(named.hidingEmail.email, "공유 이미지에는 이메일 없음")
        XCTAssertNil(named.showingEmail.hidingEmail.name, "이메일 보기 상태로 만들어도 공유 이미지에서는 제외")

        let unknown = DashboardAccount(
            provider: provider("openrouter"), providerName: "OpenRouter", name: nil, lines: [])
        XCTAssertEqual(unknown.showingEmail.subtitle, "OpenRouter", "이메일을 모르는 계정은 그대로")
        XCTAssertFalse(unknown.isInUse)
    }

    func testOnlyNonpositiveBalanceIsUsedUp() {
        for amount in [0.0, -3, 3] {
            var balance = WidgetData(
                title: "Balance", icon: .providerMark("openrouter"), kind: .dollars, used: 0, limit: nil,
                unboundedValueWord: "left")
            balance.values = [MetricValue(number: amount, kind: .dollars)]
            let descriptor = descriptor("openrouter.balance")
                .exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
            let account = account("openrouter", lines: [DashboardLine(descriptor: descriptor, data: balance)])
            XCTAssertEqual(
                PriorityBoard.make(accounts: [account], now: now).usedUp.map(\.id),
                amount <= 0 ? ["openrouter.balance"] : [])
            let pinned = PriorityBoard.make(accounts: [account], pinned: ["openrouter.balance"], now: now)
            XCTAssertEqual(pinned.pinned.map(\.id), ["openrouter.balance"])
            XCTAssertEqual(pinned.pinned.first?.item?.reason, amount <= 0 ? .emptyBalance : nil)
            XCTAssertTrue(pinned.usedUp.isEmpty)
        }
    }

    func testZeroSpendWithoutABalanceResourceIsNotUsedUp() {
        // Copilot Org Spend처럼 지출 값이 $0이어도 잔액이 아니면 소진됨 아님.
        var spend = WidgetData(
            title: "Org Spend", icon: .providerMark("copilot"), kind: .dollars, used: 0, limit: nil,
            unboundedValueWord: "spent")
        spend.values = [MetricValue(number: 0, kind: .dollars)]
        let descriptor = descriptor("copilot.orgSpend")
            .exportingLimit("orgSpend", unit: "usd", source: .value(kind: .dollars))
        let account = account("copilot", lines: [DashboardLine(descriptor: descriptor, data: spend)])
        XCTAssertTrue(PriorityBoard.make(accounts: [account], now: now).usedUp.isEmpty)
    }

    func testBurningFastLatchHoldsUntilPaceEases() {
        // 기간 절반 경과, 사용 60% → 초기화 전 소진 예상.
        let burning = line("codex.weekly", used: 60, resetIn: 3.5 * 86_400, period: week).data
        XCTAssertTrue(BurningFast.isBurning(burning, now: now, wasBurning: false))
        // 사용 46% → 마지막 10% 안 착지(close) — 이전에 burning이면 유지, 아니면 아님.
        let easing = line("codex.weekly", used: 46, resetIn: 3.5 * 86_400, period: week).data
        XCTAssertTrue(BurningFast.isBurning(easing, now: now, wasBurning: true))
        XCTAssertFalse(BurningFast.isBurning(easing, now: now, wasBurning: false))
    }

    func testBurningFastLatchSurvivesTimeExtensionBeforeReset() {
        let oldReset = now.addingTimeInterval(3.5 * 86_400)
        let extended = line("codex.weekly", used: 48, resetIn: 3.5 * 86_400 + 60)
        let burning = BurningFast(latched: [extended.id: oldReset])
        XCTAssertTrue(burning.contains(extended, now: now))
        XCTAssertFalse(BurningFast().contains(extended, now: now))
        XCTAssertFalse(burning.wasBurning(extended.id, extended.data, now: oldReset))

        let recovered = line("codex.weekly", used: 0, resetIn: 3.5 * 86_400 + 60)
        XCTAssertFalse(burning.contains(recovered, now: now))
    }

    // MARK: - Helpers

    private func provider(_ id: String) -> Provider {
        Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
    }

    private func descriptor(_ id: String) -> WidgetDescriptor {
        let providerID = String(id.split(separator: ".")[0])
        return WidgetDescriptor(
            id: id, providerID: providerID, metricLabel: id,
            sample: WidgetData(title: id, icon: .providerMark(providerID), kind: .percent, used: 0, limit: 100)
        )
    }

    func testLoginEmailComesFromTheAccountLabel() {
        XCTAssertEqual(AppContainer.loginEmail(fromAccountLabel: "me@example.com"), "me@example.com")
        XCTAssertEqual(
            AppContainer.loginEmail(fromAccountLabel: "me@example.com (me@example.com's Organization)"),
            "me@example.com")
        XCTAssertEqual(AppContainer.loginEmail(fromAccountLabel: "me@example.com (Acme (US))"), "me@example.com")
        XCTAssertNil(AppContainer.loginEmail(fromAccountLabel: "Acme Team"), "이메일이 없는 라벨")
    }

    private func line(_ id: String, used: Double, resetIn: TimeInterval, period: Int? = nil) -> DashboardLine {
        var data = WidgetData(title: id, icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetIn)
        data.periodDurationMs = period ?? week
        return DashboardLine(descriptor: descriptor(id), data: data)
    }

    private func account(_ id: String, lines: [DashboardLine]) -> DashboardAccount {
        DashboardAccount(provider: provider(id), providerName: id.capitalized, name: nil, lines: lines)
    }
    func testMenuBarLimitFromCount() {
        XCTAssertEqual(MenuBarLimit(count: 0), .iconOnly)
        XCTAssertEqual(MenuBarLimit(count: 4), .upToFour)
        XCTAssertEqual(MenuBarLimit(count: 9), .upToFive)
    }

}
