import XCTest
@testable import Egasu

@MainActor
final class ResetDisplayTests: XCTestCase {
    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testAbsoluteLabelDayBuckets() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))! // 정오 고정, 날짜 경계 회피

        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(2 * 3600),
                                                    now: now, calendar: calendar)!.hasPrefix("Resets today at "))

        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!.addingTimeInterval(3600)
        XCTAssertTrue(Formatters.resetAbsoluteLabel(at: tomorrow,
                                                    now: now, calendar: calendar)!.hasPrefix("Resets tomorrow at "))

        let later = calendar.date(byAdding: .day, value: 5, to: now)!
        let label = Formatters.resetAbsoluteLabel(at: later, now: now, calendar: calendar)!
        XCTAssertTrue(label.hasPrefix("Resets ") && label.contains(" at "))
        XCTAssertFalse(label.hasPrefix("Resets today"))
        XCTAssertFalse(label.hasPrefix("Resets tomorrow"))

        XCTAssertEqual(Formatters.resetAbsoluteLabel(at: now.addingTimeInterval(-1),
                                                     now: now, calendar: calendar), "Resets soon")
    }

    func testWidgetDataTrailingAndTooltipHonorMode() {
        var data = WidgetData(title: "Weekly", icon: .providerMark("codex"),
                              kind: .percent, used: 50, limit: 100)
        data.resetsAt = Date().addingTimeInterval(4 * 24 * 3600 + 17 * 3600)
        data.periodDurationMs = 7 * 24 * 60 * 60 * 1000
        XCTAssertTrue(data.hasResetLabel())

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.boundedTrailingText()?.hasPrefix("Resets in "), true)
        XCTAssertEqual(data.resetTooltip()?.hasPrefix("Resets "), true)

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.boundedTrailingText()?.hasPrefix("Resets "), true)
        XCTAssertEqual(data.resetTooltip()?.hasPrefix("Resets in "), true)
    }

    private func kimiSession(usedRatio: Double, resetTime: String?) throws -> WidgetData {
        var quota: [String: Any] = ["used_ratio": usedRatio]
        quota["reset_time"] = resetTime
        let mapped = try KimiUsageMapper.map(["usages": ["limit_5h": quota]])
        let provider = KimiProvider()
        let descriptor = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "kimi.session" })
        let snapshot = ProviderSnapshot.make(
            provider: provider.provider, plan: nil, lines: mapped.lines, refreshedAt: Date())
        return WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
    }

    func testKimiZeroUsageSessionShowsTheReportedResetInBothLayouts() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(4 * 3600 + 54 * 60)
        var data = try kimiSession(usedRatio: 0, resetTime: EgasuISO8601.string(from: reset))
        XCTAssertEqual(data.used, 0)
        XCTAssertEqual(data.resetsAt, reset)
        XCTAssertTrue(data.hasResetLabel(now: now))

        for mode in [ResetDisplayMode.relative, .absolute] {
            data.resetDisplayMode = mode
            let row = data.dashboardRow(now: now)
            guard case .bar(_, _, _, let gridReset, _) = row.mark else { return XCTFail("Expected session meter") }
            let expectedGrid =
                mode == .relative
                ? Formatters.countdown(to: reset, now: now) : Formatters.compactClock(reset, now: now)
            let expectedCard =
                mode == .relative
                ? Formatters.resetRelativeLabel(until: reset, now: now)
                : Formatters.resetAbsoluteLabel(at: reset, now: now)
            XCTAssertEqual(gridReset, expectedGrid)
            XCTAssertEqual(row.cardReset, expectedCard)
        }
    }

    func testKimiSessionWithoutAValidResetShowsOnlyUsageInBothLayouts() throws {
        for reset in [nil, "invalid"] as [String?] {
            for ratio in [0.0, 0.25] {
                let data = try kimiSession(usedRatio: ratio, resetTime: reset)
                XCTAssertTrue(data.hasData)
                XCTAssertEqual(data.used, ratio * 100)
                XCTAssertEqual(data.periodDurationMs, KimiUsageMapper.sessionPeriodMs)
                XCTAssertFalse(data.hasResetLabel())
                XCTAssertNil(data.resetTooltip())
                let row = data.dashboardRow()
                guard case .bar(_, _, _, let gridReset, _) = row.mark else { return XCTFail("Expected session meter") }
                XCTAssertNil(gridReset)
                XCTAssertNil(row.cardReset)
            }
        }
    }

    func testZeroUsageSessionSignalPreservesAntigravityBehavior() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let period: TimeInterval = 5 * 3600
        for id in ["antigravity.geminiPro", "antigravity.claude"] {
            var data = WidgetData(title: "Session", icon: .providerMark("codex"), kind: .percent, used: 0, limit: 100)
            data.sessionStartSignal = .zeroUsage
            data.periodDurationMs = Int(period * 1000)
            // window 절반 경과에도 usage 0이면 "Not started" (isFreshSessionWindow 기준)
            data.resetsAt = now.addingTimeInterval(period / 2)
            XCTAssertEqual(data.boundedTrailingText(now: now), "Not started", id)
            XCTAssertFalse(data.hasResetLabel(now: now), id)
            XCTAssertEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip, id)
            // "Not started" 상태에서는 pacing 강제에도 pace projection·tick 없음
            data.alwaysShowPacing = true
            let state = data.meterState(now: now)
            XCTAssertEqual(state, .level(.normal), id)
            XCTAssertNil(state.tooltip, id)
            XCTAssertNil(data.paceTick(for: state, now: now), id)
            data.resetsAt = now
            XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
            data.resetsAt = nil
            XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
        }
    }

    func testClaudeSessionStartUsesMissingResetDateInBothDisplayModes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let future = now.addingTimeInterval(9_000)
        for mode in [WidgetDisplayMode.used, .remaining] {
            for resetMode in [ResetDisplayMode.relative, .absolute] {
                var data = WidgetData(title: "Session", icon: .providerMark("claude"),
                                      kind: .percent, used: 0, limit: 100, displayMode: mode,
                                      resetDisplayMode: resetMode, periodDurationMs: MetricPeriod.sessionMs)
                data.sessionStartSignal = .missingResetDate
                XCTAssertEqual(data.boundedTrailingText(now: now), "Not started")
                XCTAssertEqual(data.resetTooltip(now: now), WidgetData.freshSessionTooltip)
                XCTAssertFalse(data.hasResetLabel(now: now))

                data.resetsAt = future
                XCTAssertFalse(data.isFreshSessionWindow(now: now))
                XCTAssertTrue(data.hasResetLabel(now: now))
                XCTAssertEqual(data.boundedTrailingText(now: now), resetMode == .relative
                    ? Formatters.resetRelativeLabel(until: future, now: now)
                    : Formatters.resetAbsoluteLabel(at: future, now: now))
                XCTAssertEqual(data.meterState(now: now), .level(.normal))
                XCTAssertNil(data.paceTick(for: data.meterState(now: now), now: now))

                data.resetsAt = now.addingTimeInterval(-1)
                XCTAssertFalse(data.isFreshSessionWindow(now: now))
                XCTAssertEqual(data.boundedTrailingText(now: now), "Resets soon")
            }
        }
    }

    func testMissingResetSignalRequiresZeroUsageAndRealBoundedData() {
        var data = WidgetData(title: "Session", icon: .providerMark("claude"), kind: .percent,
                              used: 1, limit: 100, sessionStartSignal: .missingResetDate)
        XCTAssertFalse(data.isFreshSessionWindow())
        data.used = 0
        data.hasData = false
        XCTAssertFalse(data.isFreshSessionWindow())
        XCTAssertEqual(data.boundedTrailingText(), WidgetData.noDataSubtitle)
        data.hasData = true
        data.limit = nil
        XCTAssertFalse(data.isFreshSessionWindow())
    }

    @MainActor
    func testSessionStartSignalsAreWiredOnExactlyTheShippingDescriptors() {
        let providers: [ProviderRuntime] = [
            ClaudeProvider(), CodexProvider(), CursorProvider(),
            AntigravityProvider(), CopilotProvider(), DevinProvider(),
            GrokProvider(), KimiProvider(), KiroProvider(), OpenCodeProvider(), OpenRouterProvider(), ZAIProvider()
        ]
        let descriptors = providers.flatMap(\.widgetDescriptors)
        let signals = Dictionary(uniqueKeysWithValues: descriptors.compactMap { descriptor in
            descriptor.sample.sessionStartSignal.map { (descriptor.id, $0) }
        })
        XCTAssertEqual(
            signals,
            [
                "claude.session": .missingResetDate,
                "antigravity.geminiPro": .zeroUsage,
                "antigravity.claude": .zeroUsage
            ])

        let suffixed = descriptors.filter { $0.sample.traySuffix != nil }
        XCTAssertEqual(suffixed.map(\.id), ["codex.rateLimitResets"])
        XCTAssertEqual(suffixed.first?.sample.traySuffix, "resets")
    }

    func testAntigravityWeeklyRowsNeverReadNotStarted() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let period: TimeInterval = 7 * 24 * 3600
        let provider = AntigravityProvider(usageScan: { _, _ in nil }, pricing: { .empty })
        let registry = WidgetRegistry(providers: [provider.provider], descriptors: provider.widgetDescriptors)
        let reset = EgasuISO8601.string(from: now.addingTimeInterval(period / 2))
        let buckets = ["gemini-weekly", "3p-weekly", "gemini-argon-wtu-weekly"].map {
            ["bucketId": $0, "remainingFraction": 1, "resetTime": reset] as [String: Any]
        }
        let payload = try JSONSerialization.data(withJSONObject: ["groups": [["buckets": buckets]]])
        let snapshot = ProviderSnapshot(
            providerID: provider.provider.id, displayName: provider.provider.displayName,
            lines: try XCTUnwrap(AntigravityUsageMapper.parseQuotaSummary(payload)?.lines), refreshedAt: now
        )
        try L10n.withLanguage(.english) {
            for id in ["antigravity.geminiWeekly", "antigravity.claudeWeekly", "antigravity.argonWeekly"] {
                let descriptor = try XCTUnwrap(registry.descriptor(id: id))
                var data = WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
                data.resetDisplayMode = .relative
                XCTAssertTrue(data.hasData, id)
                XCTAssertEqual(data.used, 0, id)
                XCTAssertEqual(data.periodDurationMs, Int(period * 1000), id)
                XCTAssertFalse(data.isFreshSessionWindow(now: now), id)
                XCTAssertNotEqual(data.boundedTrailingText(now: now), "Not started", id)
                XCTAssertEqual(data.boundedTrailingText(now: now)?.hasPrefix("Resets"), true, id)
            }
        }
    }

    func testExpiryTooltipSingleCreditFollowsTimeSetting() {
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 1, kind: .count, label: "available")]
        data.expiriesAt = [Date().addingTimeInterval(12 * 24 * 3600 + 18 * 3600)]

        XCTAssertEqual(data.unboundedDetail, "1 available")

        data.resetDisplayMode = .relative
        XCTAssertEqual(data.expiryTooltip, "Reset expires in 12d 18h")

        data.resetDisplayMode = .absolute
        XCTAssertEqual(data.expiryTooltip?.hasPrefix("Reset expires "), true)
        XCTAssertEqual(data.expiryTooltip?.contains(" at "), true)
    }

    func testExpiryTooltipMultipleCreditsIsNumberedList() {
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]
        data.expiriesAt = [
            Date().addingTimeInterval(12 * 24 * 3600 + 18 * 3600),
            Date().addingTimeInterval(22 * 24 * 3600 + 12 * 3600)
        ]
        data.resetDisplayMode = .relative

        XCTAssertEqual(data.unboundedDetail, "2 available")
        XCTAssertEqual(data.expiryTooltip, "Resets expire in:\n1. 12d 18h\n2. 22d 12h")
    }

    func testExpirySeverityTracksSoonestExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 2, kind: .count, label: "available")]

        data.expiriesAt = [
            now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600),
            now.addingTimeInterval(WidgetData.expiryWarningWindow + 10 * 24 * 3600)
        ]
        XCTAssertEqual(data.expirySeverity(now: now), .critical)

        data.expiriesAt = [now.addingTimeInterval(WidgetData.expiryCriticalWindow + 3600)]
        XCTAssertEqual(data.expirySeverity(now: now), .warning)

        data.expiriesAt = [now.addingTimeInterval(WidgetData.expiryWarningWindow + 24 * 3600)]
        XCTAssertEqual(data.expirySeverity(now: now), .normal)

        data.expiriesAt = []
        XCTAssertNil(data.expirySeverity(now: now))
    }

    func testNoExpiryTooltipWhenNoExpiries() {
        var data = WidgetData(title: "Rate Limit Resets", icon: .providerMark("codex"),
                              kind: .count, used: 0, limit: nil)
        data.values = [MetricValue(number: 0, kind: .count, label: "available")]
        XCTAssertEqual(data.unboundedDetail, "0 available")
        XCTAssertNil(data.expiryTooltip)
    }

    func testResetsPopoverEntriesAreSoonestFirstAndNumbered() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(
            from: [
                // 정렬 검증용 역순 입력
                now.addingTimeInterval(12 * 24 * 3600 + 18 * 3600),
                now.addingTimeInterval(WidgetData.expiryCriticalWindow - 3600)
            ],
            now: now
        )

        XCTAssertEqual(entries.map(\.number), [1, 2])
        XCTAssertEqual(entries[0].severity, .critical)
        XCTAssertEqual(entries[1].severity, .normal)
        XCTAssertEqual(entries[1].time.contains(" at "), true)
        XCTAssertEqual(entries[1].countdown, "12d 18h")
    }

    func testResetsPopoverPastDueEntryReadsSoonWithNoCountdown() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(-60)], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].time, "Expiring soon")
        XCTAssertNil(entries[0].countdown)
        XCTAssertEqual(entries[0].severity, .critical)
    }

    func testResetsPopoverImminentFutureCreditCollapsesToSoon() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = RateLimitResetsDetail.entries(from: [now.addingTimeInterval(180)], now: now)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].time, "Expiring soon")
        XCTAssertNil(entries[0].countdown)
    }

    func testResetsPopoverEmptyWhenNoCredits() {
        XCTAssertTrue(RateLimitResetsDetail.entries(from: [], now: Date()).isEmpty)
    }

    func testCompactDurationOmitsZeroTrailingHours() {
        XCTAssertEqual(Formatters.compactDuration(4 * 24 * 3600 + 52 * 60), "4d")
        XCTAssertEqual(Formatters.compactDuration(7 * 24 * 3600), "7d")
        XCTAssertEqual(Formatters.compactDuration(9 * 24 * 3600 + 21 * 3600), "9d 21h")
        XCTAssertEqual(Formatters.compactDuration(5 * 3600), "5h")
        XCTAssertEqual(Formatters.compactDuration(52 * 60), "52m")
    }

    func testResetsPopoverContentResolvesEmptyCountOnlyAndTimeline() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        XCTAssertEqual(RateLimitResetsDetail.content(count: 0, expiries: [], now: now), .empty)

        // count 있음 + expiry 목록 없음 → unknownExpiries ("no resets"로 읽히면 안 됨)
        XCTAssertEqual(
            RateLimitResetsDetail.content(count: 3, expiries: [], now: now),
            .unknownExpiries(count: 3)
        )

        let expiries = [now.addingTimeInterval(4 * 24 * 3600)]
        let content = RateLimitResetsDetail.content(count: 1, expiries: expiries, now: now)
        guard case .timeline(let entries, let unknownCount) = content else {
            return XCTFail("expected timeline")
        }
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(unknownCount, 0)
    }

    func testDeadlineLabelSharesFormatAcrossPrefixesAndModes() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2024, month: 6, day: 1, hour: 12))!

        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600 + 360),
                                                mode: .relative, now: now), "Runs out in 2h 6m")
        XCTAssertTrue(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(2 * 3600),
                                               mode: .absolute, now: now, calendar: calendar)!
            .hasPrefix("Runs out today at "))
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(60),
                                                mode: .relative, now: now), "Runs out soon")
        XCTAssertEqual(Formatters.deadlineLabel("Runs out", at: now.addingTimeInterval(-1),
                                                mode: .absolute, now: now, calendar: calendar), "Runs out soon")
    }

    /// .runningOut일 때의 run-out ETA — 실제 clock 기준 평가 (아래 Date() 기반 resetsAt과 일치)
    private func runningOutEta(_ data: WidgetData) -> String? {
        if case .runningOut(let eta, _) = data.meterState() { return eta }
        return nil
    }

    func testRunningOutEtaHonorsResetDisplayMode() {
        // 10h window 절반에 90/100 사용 → run-out 약 34m 후, reset(5h)보다 이른 시점
        var data = WidgetData(title: "Session", icon: .providerMark("codex"),
                              kind: .percent, used: 90, limit: 100)
        data.resetsAt = Date().addingTimeInterval(5 * 3600)
        data.periodDurationMs = 10 * 3600 * 1000

        data.resetDisplayMode = .relative
        XCTAssertEqual(runningOutEta(data)?.hasPrefix("Limit in "), true)
        XCTAssertEqual(runningOutEta(data)?.hasSuffix("m"), true)

        data.resetDisplayMode = .absolute
        // 실제 clock 기준 평가 → 자정 부근 실행 시 "tomorrow" bucket 가능
        let absolute = runningOutEta(data)
        XCTAssertEqual(absolute?.hasPrefix("Limit today at ") == true
                        || absolute?.hasPrefix("Limit tomorrow at ") == true, true)
    }

    func testNoResetLabelWithoutResetDate() {
        var data = WidgetData(title: "Credits", icon: .providerMark("codex"),
                              kind: .dollars, used: 12, limit: 20)
        data.resetDisplayMode = .absolute
        XCTAssertFalse(data.hasResetLabel())
        XCTAssertNil(data.resetTooltip())
        XCTAssertEqual(data.boundedTrailingText(), "$20 limit")
    }

    // MARK: - Antigravity 사용률 원값

    private func antigravitySession(fraction: Double, now: Date) -> WidgetData {
        guard
            case .progress(_, let used, let limit, _, let resetsAt, let periodMs, _) = AntigravityUsageMapper.line(
                pool: AntigravityMetric.sessionLabel, fraction: fraction,
                resetTime: now.addingTimeInterval(2 * 3600), periodMs: MetricPeriod.sessionMs
            )
        else { preconditionFailure("expected a progress line") }
        var data = WidgetData(
            title: "Session", icon: .providerMark("antigravity"), kind: .percent, used: used, limit: limit)
        data.resetsAt = resetsAt
        data.periodDurationMs = periodMs
        data.sessionStartSignal = .zeroUsage
        data.displayMode = .remaining
        data.resetDisplayMode = .relative
        return data
    }

    func testAntigravitySessionJustUnderFullKeepsItsCountdownBehindTheRoundedPercent() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let data = antigravitySession(fraction: 0.99965, now: now)

        XCTAssertEqual(data.used, 0.035, accuracy: 0.001)
        XCTAssertGreaterThan(data.used, 0, "조금 쓴 세션이 미사용으로 반올림되면 안 됨")
        L10n.withLanguage(.english) {
            XCTAssertEqual(data.valueText, "100%", "표시만 정수 %로 반올림")
            XCTAssertFalse(data.isFreshSessionWindow(now: now))
            XCTAssertEqual(data.boundedTrailingText(now: now), "Resets in 2h")
            XCTAssertEqual(data.compactResetText(now: now), "2h")
        }
    }

    func testAntigravityUntouchedAndExhaustedWindowsKeepTheirFreshAndCountdownReads() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let untouched = antigravitySession(fraction: 1, now: now)
        XCTAssertTrue(untouched.isFreshSessionWindow(now: now))
        XCTAssertNil(untouched.compactResetText(now: now))
        L10n.withLanguage(.english) { XCTAssertEqual(untouched.boundedTrailingText(now: now), "Not started") }

        let exhausted = antigravitySession(fraction: 0, now: now)
        XCTAssertFalse(exhausted.isFreshSessionWindow(now: now))
        L10n.withLanguage(.english) { XCTAssertEqual(exhausted.compactResetText(now: now), "2h") }
        L10n.withLanguage(.english) { XCTAssertEqual(exhausted.boundedTrailingText(now: now), "Resets in 2h") }

        for (fraction, expected) in [(1.5, 0.0), (-0.5, 100.0)] {
            guard
                case .progress(_, let used, _, _, _, _, _) = AntigravityUsageMapper.line(
                    pool: "x", fraction: fraction, resetTime: nil, periodMs: MetricPeriod.sessionMs
                )
            else { return XCTFail("expected a progress line") }
            XCTAssertEqual(used, expected, "fraction \(fraction)는 0...1로 고정")
        }
    }

    func testAntigravityWeeklyKeepsTheRawPercentForTheCardToRound() {
        guard
            case .progress(_, let used, let limit, _, _, _, _) = AntigravityUsageMapper.line(
                pool: AntigravityMetric.weeklyLabel, fraction: 0.9742, resetTime: nil, periodMs: MetricPeriod.weekMs
            )
        else { return XCTFail("expected a progress line") }
        XCTAssertEqual(used, 2.58, accuracy: 0.0001)
        var data = WidgetData(
            title: "Weekly", icon: .providerMark("antigravity"), kind: .percent, used: used, limit: limit)
        data.displayMode = .remaining
        XCTAssertEqual(data.valueText, "97%")
    }
    func testCountdownShowsCalendarMonthsAndDaysFromAMonthOut() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let start = calendar.date(from: DateComponents(year: 2026, month: 11, day: 10, hour: 9))!
        func countdown(_ components: DateComponents) -> String? {
            Formatters.countdown(to: calendar.date(byAdding: components, to: start)!, now: start, calendar: calendar)
        }
        L10n.withLanguage(.english) {
            XCTAssertEqual(countdown(DateComponents(day: 29, hour: 23)), "29d 23h", "한 달 미만은 일·시간 유지")
            XCTAssertEqual(countdown(DateComponents(month: 1)), "1mo", "11월 10일 → 12월 10일은 달력 기준 한 달")
            XCTAssertEqual(countdown(DateComponents(day: 30)), "1mo")
            XCTAssertEqual(countdown(DateComponents(month: 3, day: 27, hour: 2)), "3mo 27d")
            XCTAssertEqual(countdown(DateComponents(year: 1, month: 2, day: 5)), "1y 2mo")
            XCTAssertEqual(countdown(DateComponents(hour: 2, minute: 6)), "2h 6m")
            XCTAssertNil(Formatters.countdown(to: start.addingTimeInterval(-60), now: start, calendar: calendar))
            XCTAssertEqual(
                Formatters.whenLabel(at: calendar.date(byAdding: .month, value: 4, to: start)!, mode: .relative,
                                     now: start, calendar: calendar),
                "4mo", "초기화권 팝오버·툴팁의 카운트다운"
            )
        }
        L10n.withLanguage(.korean) { XCTAssertEqual(countdown(DateComponents(month: 3, day: 27)), "3개월 27일") }
        L10n.withLanguage(.japanese) { XCTAssertEqual(countdown(DateComponents(month: 3, day: 27)), "3か月 27日") }
    }

    func testResetColumnUsesMonthsAndDaysForLongCountdowns() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var data = WidgetData(title: "Monthly", icon: .providerMark("codex"), kind: .percent, used: 10, limit: 100)
        data.resetsAt = Calendar.current.date(byAdding: .month, value: 4, to: now)
        data.resetDisplayMode = .relative
        L10n.withLanguage(.english) { XCTAssertEqual(data.compactResetText(now: now), "4mo") }
    }

    func testLocalizedDurationUnitsAndZeroTails() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        let examples: [(LanguageSetting, [String])] = [
            (.english, ["1mo", "11mo 30d", "1y", "1y 2mo", "4d", "1m"]),
            (.korean, ["1개월", "11개월 30일", "1년", "1년 2개월", "4일", "1분"]),
            (.japanese, ["1か月", "11か月 30日", "1年", "1年 2か月", "4日", "1分"])
        ]
        for (language, expected) in examples {
            L10n.withLanguage(language) {
                let components = [DateComponents(month: 1), DateComponents(month: 11, day: 30),
                                  DateComponents(year: 1, day: 5), DateComponents(year: 1, month: 2, day: 5)]
                let actual = components.map {
                    Formatters.countdown(to: calendar.date(byAdding: $0, to: now)!, now: now, calendar: calendar)!
                } + [Formatters.compactDuration(4 * 86_400)!, Formatters.compactDuration(60)!]
                XCTAssertEqual(actual, expected)
            }
        }
    }

    func testCompactClockChangesFromTimeToWeekdayAndThenMonthDayAtTheDayBoundaries() {
        let calendar = utcCalendar()
        let now = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 12))!
        for language in LanguageSetting.allCases {
            L10n.withLanguage(language) {
                for days in [0, 1, 6, 7, 8] {
                    let date = calendar.date(byAdding: .day, value: days, to: now)!
                    let text = Formatters.compactClock(date, now: now, calendar: calendar)
                    if days == 0 {
                        XCTAssertEqual(text, TimeFormatSetting.current.shortTime(date))
                    } else if days < 7 {
                        XCTAssertEqual(text, TimeFormatSetting.current.weekdayTime(date))
                    } else {
                        XCTAssertEqual(text, Formatters.monthDayLabel(date))
                    }
                }
            }
        }
    }

    func testCountdownUsesLocalCalendarAcrossMonthEndLeapDayAndDST() {
        for zone in ["Asia/Seoul", "America/Los_Angeles"] {
            var calendar = utcCalendar()
            calendar.timeZone = TimeZone(identifier: zone)!
            L10n.withLanguage(.english) {
                for start in [DateComponents(year: 2026, month: 1, day: 31, hour: 12),
                              DateComponents(year: 2024, month: 2, day: 29, hour: 12),
                              DateComponents(year: 2026, month: 2, day: 8, hour: 12)] {
                    let now = calendar.date(from: start)!
                    let end = calendar.date(byAdding: .month, value: 1, to: now)!
                    XCTAssertEqual(Formatters.countdown(to: end, now: now, calendar: calendar), "1mo", zone)
                }
                let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 7, hour: 12))!
                let end = calendar.date(byAdding: .day, value: 1, to: now)!
                XCTAssertEqual(Formatters.countdown(to: end, now: now, calendar: calendar),
                               zone == "America/Los_Angeles" ? "23h" : "1d", "짧은 기간은 실제 남은 시간")
            }
        }
    }

}
