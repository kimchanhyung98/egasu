import SwiftUI
import XCTest
@testable import Egasu

extension DashboardSnapshotTests {
    func testCodexBusinessPersonalLimitSummaryFollowsUsedAndLeft() {
        var data = WidgetData(
            title: "Individual Credits", icon: .providerMark("codex"), kind: .count, used: 898.386, limit: 2500)
        let id = "codex@fixture.individualCredits"
        for (language, used, left) in [
            (LanguageSetting.english, "36% used · Limit 2,500 credits", "64% left · Limit 2,500 credits"),
            (.korean, "36% 사용 · 한도 2,500 크레딧", "64% 남음 · 한도 2,500 크레딧"),
            (.japanese, "36% 使用済み · 上限 2,500 クレジット", "残り 64% · 上限 2,500 クレジット")
        ] {
            L10n.withLanguage(language) {
                data.displayMode = .used
                let row = line(id, data).dashboardRow()
                XCTAssertEqual(row.limitSummary, used)
                guard case .bar(_, _, let value, _, _) = row.mark else { return XCTFail("Missing credit meter") }
                XCTAssertEqual(value, "898.4")
                data.displayMode = .remaining
                XCTAssertEqual(line(id, data).dashboardRow().limitSummary, left)
            }
        }
        L10n.withLanguage(.english) {
            data.limit = 1000
            data.used = 325
            data.displayMode = .used
            XCTAssertEqual(line(id, data).dashboardRow().limitSummary, "33% used · Limit 1,000 credits")
            data.displayMode = .remaining
            XCTAssertEqual(line(id, data).dashboardRow().limitSummary, "68% left · Limit 1,000 credits")

            data.limit = 2500
            data.used = 2500
            data.displayMode = .used
            XCTAssertEqual(line(id, data).dashboardRow().limitSummary, "100% used · Limit 2,500 credits")
            data.displayMode = .remaining
            XCTAssertEqual(line(id, data).dashboardRow().limitSummary, "0% left · Limit 2,500 credits")
            data.used = 3000
            data.displayMode = .used
            let overLimit = line(id, data).dashboardRow()
            XCTAssertEqual(overLimit.limitSummary, "120% used · Limit 2,500 credits")
            guard case .bar(let fill, _, _, _, _) = overLimit.mark else { return XCTFail("Missing credit meter") }
            XCTAssertEqual(fill, 1)
            data.displayMode = .remaining
            XCTAssertEqual(line(id, data).dashboardRow().limitSummary, "0% left · Limit 2,500 credits")
            XCTAssertNil(line("codex@fixture.monthly", data).dashboardRow().limitSummary)
        }
    }

    func testMinimalCreditLabelWrapsAndCentersBesideAmountAndLimit() throws {
        let data = WidgetData(
            title: "Individual Credits", icon: .providerMark("codex"), kind: .count, used: 325, limit: 1000)
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                let model = line("codex@fixture.individualCredits", data).dashboardRow()
                let image = try render(
                    DashboardMetricRow(model: model)
                        .padding(.horizontal, DashboardGrid.cardPadding)
                        .environment(\.locale, language.locale),
                    appearance: .dark)
                let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
                let scale = CGFloat(bitmap.pixelsWide) / image.size.width
                let left = Int(DashboardGrid.cardPadding * scale)
                let split = Int((DashboardGrid.cardPadding + DashboardGrid.labelWidth) * scale)
                let label = try inkRows(in: bitmap, columns: left..<split)
                let figures = try inkRows(in: bitmap, columns: split..<(bitmap.pixelsWide - left))
                let labelHeight = CGFloat(label.upperBound - label.lowerBound + 1) / scale
                if language == .korean {
                    XCTAssertLessThan(labelHeight, DashboardGrid.rowHeight)
                } else {
                    XCTAssertGreaterThan(labelHeight, DashboardGrid.rowHeight)
                }
                XCTAssertEqual(
                    CGFloat(label.lowerBound + label.upperBound) / (2 * scale),
                    CGFloat(figures.lowerBound + figures.upperBound) / (2 * scale),
                    accuracy: 2, language.rawValue)
            }
        }
    }

    private func inkRows(in bitmap: NSBitmapImageRep, columns: Range<Int>) throws -> ClosedRange<Int> {
        let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0)?.usingColorSpace(.sRGB))
        let rows = (0..<bitmap.pixelsHigh).filter { y in
            columns.contains { x in
                guard let ink = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(ink.redComponent - background.redComponent) > 0.15
                    || abs(ink.greenComponent - background.greenComponent) > 0.15
                    || abs(ink.blueComponent - background.blueComponent) > 0.15
            }
        }
        return try XCTUnwrap(rows.first)...XCTUnwrap(rows.last)
    }

    func testCodexBusinessIndividualCreditsRenderOnlyOnTheAccountWithAReportedLimit() throws {
        let now = Date()
        let accountID = "codex@fixture"
        let runtime = CodexProvider(provider: CodexProvider.makeProvider(id: accountID))
        let body = Data("""
            {"plan_type":"business","rate_limit":{
                "primary_window":{"limit_window_seconds":604800,"used_percent":26},
                "secondary_window":{"limit_window_seconds":2592000,"used_percent":42}},
             "spend_control":{"individual_limit":{"unit":"credit","used":325,"limit":1000}}}
            """.utf8)
        let mapped = try CodexUsageMapper.mapUsageResponse(.init(statusCode: 200, headers: [:], body: body))
        let snapshot = ProviderSnapshot.make(provider: runtime.provider, plan: mapped.plan, lines: mapped.lines, refreshedAt: now)
        let rows = runtime.widgetDescriptors.map { descriptor in
            DashboardLine(descriptor: descriptor,
                          data: WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init()))
        }.filter { $0.data.hasData && $0.isVisible }
        XCTAssertEqual(rows.map(\.id), ["weekly", "monthly", "individualCredits"].map { "\(accountID).\($0)" })
        let descriptor = try XCTUnwrap(rows.last?.descriptor)
        let ordinary = ProviderSnapshot.make(provider: runtime.provider, plan: "Plus", lines: [], refreshedAt: now)
        let absent = WidgetDataResolver.resolve(descriptor, snapshot: ordinary, codexResetWatch: .init())
        XCTAssertFalse(DashboardLine(descriptor: descriptor, data: absent).isVisible)

        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                let account = DashboardAccount(
                    provider: runtime.provider, providerName: "Codex", name: "Business", lines: rows)
                let family = DashboardFamily(
                    id: "codex", provider: runtime.provider, displayName: "Codex", accounts: [account])
                let model = try XCTUnwrap(rows.last).dashboardRow(now: now)
                var noSummary = model
                noSummary.limitSummary = nil
                for layout in [DashboardLayoutStyle.minimal, .cards] {
                    let reading = try render(DashboardMetricRow(model: model, layoutStyle: layout), appearance: .dark)
                    let baseline = try render(
                        DashboardMetricRow(model: noSummary, layoutStyle: layout), appearance: .dark)
                    XCTAssertGreaterThan(reading.size.height, baseline.size.height)

                    let view = DashboardProviderSection(family: family, layoutStyle: layout) { account in
                        DashboardAccountRows(account: account, plan: mapped.plan, layoutStyle: layout)
                    }
                    let image = try render(
                        view.environment(\.locale, language.locale), appearance: .dark,
                        name: "codex-business-individual-credits-\(language.rawValue)-\(layout.rawValue)")
                    XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 3)
                }
            }
        }
    }
}
