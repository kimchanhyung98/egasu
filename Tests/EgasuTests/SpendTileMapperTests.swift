import XCTest
@testable import Egasu

final class SpendTileMapperTests: XCTestCase {
    func testLargeVariantCostsAndOrdinaryCentRoundingRemainEncodable() throws {
        for cost in [1.23456, 1e308, Double.greatestFiniteMagnitude] {
            var accumulator = DailyUsageAccumulator()
            accumulator.add(day: "2026-06-26", tokens: 1, cost: cost, model: "model")
            let scan = accumulator.build()
            var modelUsage = try XCTUnwrap(scan.modelUsage)
            modelUsage.daily[0].models[0].variants = [
                ModelUsageVariant(model: "model-variant", totalTokens: 1, costUSD: cost)
            ]
            var lines: [MetricLine] = []
            SpendTileMapper.appendTokenUsage(
                scan.series, to: &lines, now: day(2026, 6, 26), estimated: false,
                modelUsage: modelUsage, modelSourceNote: "From test logs"
            )
            for label in ["Today", "Last 30 Days"] {
                let model = try XCTUnwrap(modelBreakdown(lines, label)?.models.first)
                let expected = cost == 1.23456 ? 1.23 : cost
                XCTAssertEqual(model.costUSD, expected)
                XCTAssertEqual(model.variants?.first?.costUSD, expected)
            }
            XCTAssertNoThrow(try JSONEncoder().encode(lines))
        }
    }

    func testIdleRecentDaysLeftUnbacked() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-22", 5_000), ("2026-06-23", 7_000)]),
            to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertNil(line(lines, "Today"), "an idle today is left unbacked → tile reads No data")
        XCTAssertNil(line(lines, "Yesterday"), "ditto yesterday — not a fabricated $0.00")
        XCTAssertNotNil(line(lines, "Last 30 Days"), "the 30-day total still renders")
    }

    func testInRangeIdleDayAlsoLeftUnbacked() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            series([("2026-06-24", 9_000), ("2026-06-26", 3_000)]),
            to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertEqual(values(lines, "Today"), [MetricValue(number: 3_000, kind: .count, label: "tokens")])
        XCTAssertNil(line(lines, "Yesterday"), "an idle in-range day is No data, not $0.00 · 0 tokens")
    }

    func testIdleDayDoesNotHideCompleteThirtyDayCost() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 100, costUSD: 1),
                DailyUsageEntry(date: "2026-06-25", totalTokens: 0, costUSD: nil),
                DailyUsageEntry(date: "2026-06-24", totalTokens: 0, costUSD: 0.25),
                DailyUsageEntry(date: "2026-06-23", totalTokens: 0, costUSD: 0)
            ]),
            to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertEqual(values(lines, "Last 30 Days"), [
            MetricValue(number: 1.25, kind: .dollars, estimated: false),
            MetricValue(number: 100, kind: .count, label: "tokens")
        ])
        XCTAssertNil(line(lines, "Yesterday"))
    }

    func testIdleVariantDoesNotHidePricedVariantAcrossDays() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 100, costUSD: 1),
                DailyUsageEntry(date: "2026-06-25", totalTokens: 200, costUSD: 2),
                DailyUsageEntry(date: "2026-06-24", totalTokens: 0, costUSD: 0.25)
            ]),
            to: &lines, now: day(2026, 6, 26), estimated: false,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 100, costUSD: 1, variants: [
                        ModelUsageVariant(model: "thinking", totalTokens: 100, costUSD: 1)
                    ])
                ]),
                DailyModelUsageEntry(date: "2026-06-25", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 200, costUSD: 2, variants: [
                        ModelUsageVariant(model: "thinking", totalTokens: 0, costUSD: nil),
                        ModelUsageVariant(model: "plain", totalTokens: 200, costUSD: 2)
                    ])
                ]),
                DailyModelUsageEntry(date: "2026-06-24", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 0, costUSD: 0.25, variants: [
                        ModelUsageVariant(model: "thinking", totalTokens: 0, costUSD: 0.25)
                    ])
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let model = try XCTUnwrap(modelBreakdown(lines, "Last 30 Days")?.models.first)
        XCTAssertEqual(model.totalTokens, 300)
        XCTAssertEqual(model.costUSD, 3.25)
        XCTAssertEqual(model.variants?.first { $0.model == "thinking" }?.costUSD, 1.25)
        XCTAssertEqual(model.variants?.first { $0.model == "plain" }?.costUSD, 2)
    }

    func testEmptySeriesLeavesAllTilesUnbacked() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: []), to: &lines, now: day(2026, 6, 26), estimated: false
        )

        XCTAssertTrue(lines.isEmpty, "an all-zero window appends no spend tiles")
    }

    func testUsedDayRendersItsValues() {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [DailyUsageEntry(date: "2026-06-26", totalTokens: 12_000, costUSD: 1.50)]),
            to: &lines, now: day(2026, 6, 26), estimated: true
        )

        XCTAssertEqual(values(lines, "Today"),
                       [MetricValue(number: 1.50, kind: .dollars, estimated: true),
                        MetricValue(number: 12_000, kind: .count, label: "tokens")])
    }

    func testSingleModelPeriodStillGetsModelBreakdown() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 300, costUSD: 3)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.totalTokens, 300)
        XCTAssertEqual(breakdown.totalCostUSD, 3)
        XCTAssertEqual(breakdown.models, [
            ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)
        ])
    }

    func testModelBreakdownISODateMatchesLocalPeriodDay() throws {
        let now = day(2026, 6, 26)
        let localStart = Calendar.current.startOfDay(for: now)

        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: dayKey(now), totalTokens: 300, costUSD: 3)
            ]),
            to: &lines,
            now: now,
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: isoString(localStart), models: [
                    ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["gpt-5.5"])
    }

    func testModelBreakdownScopesTodayYesterdayAndLast30() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 300, costUSD: 3),
                DailyUsageEntry(date: "2026-06-25", totalTokens: 700, costUSD: 7)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 1),
                    ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 2)
                ]),
                DailyModelUsageEntry(date: "2026-06-25", models: [
                    ModelUsageEntry(model: "alpha", totalTokens: 300, costUSD: 3),
                    ModelUsageEntry(model: "gamma", totalTokens: 400, costUSD: 4)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let today = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(today.totalTokens, 300)
        XCTAssertEqual(today.totalCostUSD, 3)
        XCTAssertEqual(today.models.map(\.model), ["beta", "alpha"])

        let yesterday = try XCTUnwrap(modelBreakdown(lines, "Yesterday"))
        XCTAssertEqual(yesterday.models.map(\.model), ["gamma", "alpha"])

        let last30 = try XCTUnwrap(modelBreakdown(lines, "Last 30 Days"))
        XCTAssertEqual(last30.totalTokens, 1000)
        XCTAssertEqual(last30.totalCostUSD, 10)
        XCTAssertEqual(last30.models.map(\.model), ["alpha", "gamma", "beta"])
        XCTAssertEqual(last30.sourceNote, "From test logs")
    }

    func testModelBreakdownPreservesAllModelsBeforeRanking() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 3_700, costUSD: 49)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 10),
                    ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 9),
                    ModelUsageEntry(model: "aardvark", totalTokens: 300, costUSD: 9),
                    ModelUsageEntry(model: "delta", totalTokens: 400, costUSD: 7),
                    ModelUsageEntry(model: "epsilon", totalTokens: 500, costUSD: 6),
                    ModelUsageEntry(model: "zeta", totalTokens: 600, costUSD: 5),
                    ModelUsageEntry(model: "eta", totalTokens: 700, costUSD: 3),
                    ModelUsageEntry(model: "mystery", totalTokens: 900, costUSD: nil)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(
            breakdown.models.map(\.model),
            ["alpha", "aardvark", "beta", "delta", "epsilon", "zeta", "eta", "mystery"]
        )
        XCTAssertNil(breakdown.models.first { $0.model == "mystery" }?.costUSD)
        let rows = UsageBreakdown(title: "Today", breakdown: breakdown).rows(by: .cost)
        XCTAssertEqual(rows.dropLast().map(\.name), ["aardvark", "beta", "delta", "epsilon", "zeta"])
        let other = try XCTUnwrap(rows.last)
        XCTAssertEqual(other.name, L10n.metrics(ModelUsageEntry.otherModelName))
        XCTAssertNil(other.number)
        XCTAssertEqual(other.variants.map(\.model), ["alpha", "eta", "mystery"])
    }

    func testModelBreakdownFoldsSubFivePercentModelsIntoOther() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 1_000, costUSD: 100)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "big", totalTokens: 700, costUSD: 90),
                    ModelUsageEntry(model: "mid", totalTokens: 200, costUSD: 6),
                    ModelUsageEntry(model: "tiny", totalTokens: 100, costUSD: 4)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        let detail = UsageBreakdown(title: "Today", breakdown: breakdown)
        let costRows = detail.rows(by: .cost)
        XCTAssertEqual(costRows.dropLast().map(\.name), ["big", "mid"])
        let other = try XCTUnwrap(costRows.last)
        XCTAssertEqual(other.name, L10n.metrics(ModelUsageEntry.otherModelName))
        XCTAssertEqual(other.number, 4)
        XCTAssertEqual(other.variants.map(\.model), ["tiny"])
        XCTAssertEqual(detail.rows(by: .tokens).map(\.name), ["big", "mid", "tiny"])
    }

    func testModelBreakdownFoldsUnattributedIntoOtherRegardlessOfSize() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 1_000, costUSD: 6)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "grok-build", totalTokens: 600, costUSD: 6),
                    // token 40% — 5% floor를 크게 넘지만 여전히 Other로 편입
                    ModelUsageEntry(model: ModelUsageEntry.unattributedModelName, totalTokens: 400, costUSD: nil)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        let detail = UsageBreakdown(title: "Today", breakdown: breakdown)
        for figure in [ModelFigure.cost, .tokens] {
            let rows = detail.rows(by: figure)
            XCTAssertEqual(rows.map(\.name), ["grok-build", L10n.metrics(ModelUsageEntry.otherModelName)])
            let other = try XCTUnwrap(rows.last)
            XCTAssertEqual(other.number, figure == .tokens ? 400 : nil)
            XCTAssertEqual(other.variants.map(\.model), [ModelUsageEntry.unattributedModelName])
        }
    }

    func testModelBreakdownGroupsCaseInsensitivelyAndKeepsDominantSpelling() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 400, costUSD: 4)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "GLM-5.2", totalTokens: 100, costUSD: 1),
                    ModelUsageEntry(model: "glm-5.2", totalTokens: 300, costUSD: 3)
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let breakdown = try XCTUnwrap(modelBreakdown(lines, "Today"))
        XCTAssertEqual(breakdown.models.map(\.model), ["glm-5.2"],
                       "case variants collapse into one row titled with the dominant spelling")
        let merged = breakdown.models[0]
        XCTAssertEqual(merged.totalTokens, 400)
        XCTAssertEqual(merged.costUSD, 4)
        XCTAssertNil(merged.variants, "casing differences are not a real breakdown")
    }

    func testModelBreakdownMergesVariantsAcrossDays() throws {
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            DailyUsageSeries(daily: [
                DailyUsageEntry(date: "2026-06-26", totalTokens: 300, costUSD: 3),
                DailyUsageEntry(date: "2026-06-25", totalTokens: 400, costUSD: 4)
            ]),
            to: &lines,
            now: day(2026, 6, 26),
            estimated: true,
            modelUsage: ModelUsageSeries(daily: [
                DailyModelUsageEntry(date: "2026-06-26", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 300, costUSD: 3, variants: [
                        ModelUsageVariant(model: "opus-thinking-max", totalTokens: 300, costUSD: 3)
                    ])
                ]),
                DailyModelUsageEntry(date: "2026-06-25", models: [
                    ModelUsageEntry(model: "opus", totalTokens: 400, costUSD: 4, variants: [
                        ModelUsageVariant(model: "opus-thinking-max", totalTokens: 100, costUSD: 1),
                        ModelUsageVariant(model: "opus-thinking-high", totalTokens: 300, costUSD: 3)
                    ])
                ])
            ]),
            modelSourceNote: "From test logs"
        )

        let last30 = try XCTUnwrap(modelBreakdown(lines, "Last 30 Days"))
        let opus = try XCTUnwrap(last30.models.first { $0.model == "opus" })
        XCTAssertEqual(opus.totalTokens, 700)
        XCTAssertEqual(opus.costUSD, 7)
        XCTAssertEqual(opus.variants?.map(\.model), ["opus-thinking-max", "opus-thinking-high"],
                       "the same slug merges into one line across the period's days")
        XCTAssertEqual(opus.variants?.map(\.costUSD), [4, 3])
        XCTAssertEqual(opus.variants?.map(\.totalTokens), [400, 300])
    }

    // MARK: - Helpers

    private func series(_ days: [(String, Int)]) -> DailyUsageSeries {
        DailyUsageSeries(daily: days.map { DailyUsageEntry(date: $0.0, totalTokens: $0.1, costUSD: nil) })
    }

    /// 정오 고정 시각 — `dayKey(from:)`와 hyphen 입력 날짜 정렬 일치
    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    private func dayKey(_ date: Date) -> String {
        let components = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func line(_ lines: [MetricLine], _ label: String) -> MetricLine? {
        lines.first { $0.label == label }
    }

    private func values(_ lines: [MetricLine], _ label: String) -> [MetricValue]? {
        guard case .values(_, let values, _, _, _, _) = line(lines, label) else { return nil }
        return values
    }

    private func modelBreakdown(_ lines: [MetricLine], _ label: String) -> ModelUsageBreakdown? {
        guard case .values(_, _, _, _, _, let breakdown) = line(lines, label) else { return nil }
        return breakdown
    }
}
