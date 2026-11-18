import XCTest
@testable import Egasu

final class UsageBreakdownTests: XCTestCase {
    private func usage(_ models: [ModelUsageEntry], cost: Double? = nil, tokens: Int = 0) -> UsageBreakdown {
        UsageBreakdown(
            title: "Today",
            breakdown: ModelUsageBreakdown(
                totalTokens: tokens, totalCostUSD: cost, models: models, sourceNote: ""
            ))
    }

    func testTopFiveByTheChosenFigurePlusOther() {
        let models = (1...7).map { ModelUsageEntry(model: "m\($0)", totalTokens: $0 * 100, costUSD: Double(8 - $0)) }
        let byCost = usage(models).rows(by: .cost)
        XCTAssertEqual(byCost.map(\.name), ["m1", "m2", "m3", "m4", "m5", "Other"])
        XCTAssertEqual(byCost.last?.number, 3, "남은 m6·m7 비용 합")
        let byTokens = usage(models).rows(by: .tokens)
        XCTAssertEqual(byTokens.map(\.name), ["m7", "m6", "m5", "m4", "m3", "Other"])
        XCTAssertEqual(byTokens.last?.number, 300)
    }

    func testMappedAndCachedBreakdownRanksTokensBeforeFoldingOther() throws {
        let asOf = try XCTUnwrap(Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 12)))
        let variants = [
            ModelUsageVariant(model: "m6-high", totalTokens: 500, costUSD: 3),
            ModelUsageVariant(model: "m6-low", totalTokens: 400, costUSD: 2)
        ]
        let models = [
            ModelUsageEntry(model: "m1", totalTokens: 100, costUSD: 10),
            ModelUsageEntry(model: "m2", totalTokens: 200, costUSD: 9),
            ModelUsageEntry(model: "m3", totalTokens: 300, costUSD: 8),
            ModelUsageEntry(model: "m4", totalTokens: 400, costUSD: 7),
            ModelUsageEntry(model: "m5", totalTokens: 500, costUSD: 6),
            ModelUsageEntry(model: "m6", totalTokens: 900, costUSD: 5, variants: variants),
            ModelUsageEntry(model: "m7", totalTokens: 600, costUSD: 1)
        ]
        let date = "2026-11-09"
        let daily = DailyUsageSeries(daily: [DailyUsageEntry(date: date, totalTokens: 3_000, costUSD: 46)])
        let modelUsage = ModelUsageSeries(daily: [DailyModelUsageEntry(date: date, models: models)])
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            daily, to: &lines, now: asOf, modelUsage: modelUsage, modelSourceNote: "From logs")
        let snapshot = ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: lines)
        let restored = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        guard case .values(_, _, _, _, _, let storedDetail) = restored.line(label: "Today") else {
            return XCTFail("Expected Today usage detail")
        }
        let breakdown = try XCTUnwrap(storedDetail)
        XCTAssertEqual(breakdown.totalTokens, 3_000)
        XCTAssertEqual(breakdown.totalCostUSD, 46)
        let detail = UsageBreakdown(title: "Today", breakdown: breakdown)
        let other = L10n.metrics(ModelUsageEntry.otherModelName)
        let byCost = detail.rows(by: .cost)
        XCTAssertEqual(byCost.map(\.name), ["m1", "m2", "m3", "m4", "m5", other])
        XCTAssertEqual(byCost.last?.number, 6)
        XCTAssertEqual(byCost.last?.variants.map(\.model), ["m6", "m7"])

        let byTokens = detail.rows(by: .tokens)
        XCTAssertEqual(byTokens.map(\.name), ["m6", "m7", "m5", "m4", "m3", other])
        XCTAssertEqual(byTokens.first?.variants, variants)
        XCTAssertEqual(byTokens.last?.number, 300)
        XCTAssertEqual(byTokens.last?.variants.map(\.model), ["m2", "m1"])
    }

    func testUnpricedModelsSitLastWithoutAPartialOtherCost() {
        let models =
            [
                ModelUsageEntry(model: "unpriced", totalTokens: 900, costUSD: nil),
                ModelUsageEntry(model: "priced", totalTokens: 100, costUSD: 2)
            ] + (1...5).map { ModelUsageEntry(model: "extra\($0)", totalTokens: 100, costUSD: 0.01) }
        let rows = usage(models).rows(by: .cost)
        XCTAssertEqual(rows.first?.name, "priced")
        XCTAssertEqual(rows.last?.name, "Other")
        XCTAssertNil(rows.last?.number, "가격 없는 모델이 섞인 묶음은 비용을 합치지 않음")
    }

    func testFiguresAndChoicesFollowWhatWasReported() {
        let priced = usage(
            [ModelUsageEntry(model: "a", totalTokens: 1_200_000, costUSD: 4.08)], cost: 4.08, tokens: 1_200_000)
        XCTAssertEqual(priced.figures.count, 2, "비용 + 토큰")
        XCTAssertEqual(priced.modelFigures, [.cost, .tokens])

        let tokensOnly = usage([ModelUsageEntry(model: "a", totalTokens: 500, costUSD: nil)], tokens: 500)
        XCTAssertEqual(tokensOnly.figures.count, 1)
        XCTAssertEqual(tokensOnly.modelFigures, [.tokens])

        XCTAssertTrue(usage([]).isEmpty)
        XCTAssertTrue(UsageBreakdown(title: "Yesterday", breakdown: .empty).isEmpty)
        XCTAssertFalse(tokensOnly.isEmpty)
    }

    func testUnattributedAndOtherNamesAreLocalized() {
        let rows = usage([ModelUsageEntry(model: ModelUsageEntry.unattributedModelName, totalTokens: 10, costUSD: nil)])
            .rows(by: .tokens)
        XCTAssertEqual(rows.map(\.name), [L10n.metrics(ModelUsageEntry.otherModelName)])
        XCTAssertEqual(rows.first?.variants.map(\.model), [ModelUsageEntry.unattributedModelName])
    }

    func testVariantTooltipKeepsExactCostAndTokensWithoutShares() throws {
        let grouped = usage([
            ModelUsageEntry(
                model: "gpt-5", totalTokens: 1_500, costUSD: nil,
                variants: [
                    ModelUsageVariant(model: "gpt-5-high", totalTokens: 1_200, costUSD: 2.50),
                    ModelUsageVariant(model: "gpt-5-fast", totalTokens: 300, costUSD: nil)
                ])
        ])
        try L10n.withLanguage(.english) {
            for figure in [ModelFigure.cost, .tokens] {
                let tooltip = try XCTUnwrap(grouped.rows(by: figure).first?.variantTooltip)
                XCTAssertEqual(tooltip, "gpt-5-high: $2.50 · 1,200 tokens\ngpt-5-fast: — · 300 tokens")
                XCTAssertFalse(tooltip.contains("%"))
            }
        }
        XCTAssertNil(
            usage([ModelUsageEntry(model: "single", totalTokens: 10, costUSD: 1)]).rows(by: .cost).first?.variantTooltip
        )
        XCTAssertNil(
            usage([ModelUsageEntry(model: ModelUsageEntry.otherModelName, totalTokens: 10, costUSD: 1)]).rows(by: .cost)
                .first?.variantTooltip,
            "이전 캐시에 Other의 원본 내역이 없으면 반복 툴팁 생략")
    }

    func testOtherTooltipIncludesBothNewlyFoldedAndAlreadyFoldedModels() throws {
        let models = (1...6).map { ModelUsageEntry(model: "m\($0)", totalTokens: 100, costUSD: Double(8 - $0)) }
        let other = ModelUsageEntry(
            model: ModelUsageEntry.otherModelName, totalTokens: 20, costUSD: nil,
            variants: [
                ModelUsageVariant(model: "tiny", totalTokens: 10, costUSD: 0.10),
                ModelUsageVariant(model: "unknown", totalTokens: 10, costUSD: nil)
            ])
        try L10n.withLanguage(.english) {
            let row = try XCTUnwrap(usage(models + [other]).rows(by: .cost).last)
            XCTAssertEqual(row.name, "Other")
            XCTAssertNil(row.number)
            XCTAssertEqual(
                row.variantTooltip, "m6: $2.00 · 100 tokens\ntiny: $0.10 · 10 tokens\nunknown: — · 10 tokens")
        }
    }

    func testCachedSpendDetailsUseTheirAggregationDayAfterMidnight() throws {
        let asOf = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 9, hour: 23, minute: 59))!
        let nextDay = asOf.addingTimeInterval(120)
        let daily = DailyUsageSeries(daily: [
            DailyUsageEntry(date: "2026-11-09", totalTokens: 100, costUSD: 1),
            DailyUsageEntry(date: "2026-11-08", totalTokens: 200, costUSD: 2)
        ])
        let models = ModelUsageSeries(
            daily: daily.daily.map {
                DailyModelUsageEntry(
                    date: $0.date,
                    models: [ModelUsageEntry(model: "gpt-5", totalTokens: $0.totalTokens, costUSD: $0.costUSD)])
            })
        var lines: [MetricLine] = []
        SpendTileMapper.appendTokenUsage(
            daily, to: &lines, now: asOf, modelUsage: models, modelSourceNote: "From test logs")
        let snapshot = ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: lines, refreshedAt: nextDay)
        let cached = try JSONDecoder().decode(ProviderSnapshot.self, from: JSONEncoder().encode(snapshot))
        try L10n.withLanguage(.english) {
            for (label, archived, tokens) in [
                ("Today", "Nov 9, 2026", 100), ("Yesterday", "Nov 8, 2026", 200),
                ("Last 30 Days", "30 Days Ending Nov 9, 2026", 300)
            ] {
                guard case .values(_, _, _, _, _, let value) = cached.line(label: label) else {
                    return XCTFail("기간 값 필요")
                }
                let breakdown = try XCTUnwrap(value)
                let detail = UsageBreakdown(title: label, breakdown: breakdown)
                XCTAssertEqual(detail.displayTitle(at: asOf), label)
                XCTAssertEqual(detail.displayTitle(at: nextDay), archived, "스냅샷 갱신 시각과 집계 기준일 분리")
                XCTAssertEqual(breakdown.totalTokens, tokens)
                XCTAssertEqual(breakdown.totalCostUSD, Double(tokens) / 100)
            }
        }
    }

    func testArchivedYesterdayUsesTheCapturedCalendarAcrossDSTAndYearChanges() throws {
        let cases = [
            ("America/Los_Angeles", "2026-03-09T07:30:00Z", "2026-03-10T07:00:00Z", "Mar 8, 2026"),
            ("Asia/Seoul", "2026-12-31T15:30:00Z", "2027-01-01T15:00:00Z", "Dec 31, 2026")
        ]
        try L10n.withLanguage(.english) {
            for (zone, collected, viewed, expected) in cases {
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
                let asOf = try XCTUnwrap(EgasuISO8601.date(from: collected))
                let period = ModelUsagePeriod(window: .yesterday, asOf: asOf, calendar: calendar)
                let breakdown = ModelUsageBreakdown(
                    totalTokens: 10, totalCostUSD: 1, models: [], sourceNote: "", period: period)
                let restored = try JSONDecoder().decode(ModelUsageBreakdown.self, from: JSONEncoder().encode(breakdown))
                let detail = UsageBreakdown(title: "Yesterday", breakdown: restored)
                XCTAssertEqual(detail.displayTitle(at: asOf), "Yesterday")
                XCTAssertEqual(detail.displayTitle(at: try XCTUnwrap(EgasuISO8601.date(from: viewed))), expected)
            }
        }
    }

    func testOldBreakdownCacheWithoutAggregationDayKeepsItsTitle() throws {
        let json = Data(
            #"{"totalTokens":100,"totalCostUSD":1,"models":[{"model":"old","totalTokens":100,"costUSD":1}],"sourceNote":"From logs"}"#
                .utf8)
        let breakdown = try JSONDecoder().decode(ModelUsageBreakdown.self, from: json)
        XCTAssertEqual(UsageBreakdown(title: "Today", breakdown: breakdown).displayTitle(at: .distantFuture), "Today")
        XCTAssertEqual(breakdown.models.first?.model, "old")
    }

    func testOldBreakdownCacheKeepsOtherWhenSourceEntriesAreMissing() throws {
        let json = Data(
            #"{"totalTokens":100,"totalCostUSD":1,"models":[{"model":"old","totalTokens":60,"costUSD":0.6},{"model":"Other","totalTokens":40,"costUSD":0.4}],"sourceNote":"From logs"}"#
                .utf8)
        let breakdown = try JSONDecoder().decode(ModelUsageBreakdown.self, from: json)
        let detail = UsageBreakdown(title: "Today", breakdown: breakdown)
        let rows = detail.rows(by: .tokens)
        XCTAssertEqual(rows.map(\.name), ["old", L10n.metrics(ModelUsageEntry.otherModelName)])
        XCTAssertEqual(rows.last?.number, 40)
        XCTAssertNil(rows.last?.variantTooltip)
    }
}
