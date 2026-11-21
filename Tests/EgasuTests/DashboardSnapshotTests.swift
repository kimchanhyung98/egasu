import SwiftUI
import XCTest
@testable import Egasu

/// All Usage의 행·계정·언어·표시 방식 렌더 검증.
@MainActor
final class DashboardSnapshotTests: XCTestCase {
    private let now = Date()

    func testReducedMotionDetailUsesParentScopedDismissalWithoutAnimation() {
        let controller = ReducedMotionPopoverController(isPresented: .constant(false))

        XCTAssertEqual(controller.popover.behavior, .semitransient)
        XCTAssertFalse(controller.popover.animates)
    }

    func testAllUsageCardRendersAccountSectionsAndEveryRowKind() throws {
        for appearance in [ColorScheme.light, .dark] {
            let view = DashboardProviderSection(family: codexFamily()) { account in
                DashboardAccountRows(account: account, plan: account.name == "Account 1" ? "Pro" : "Plus")
            }
            let image = try render(view, appearance: appearance, name: "allusage-\(appearance)")
            XCTAssertEqual(image.size.width, PanelMetrics.width - PanelMetrics.margin * 2)
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight * 6)
        }
    }

    func testLocalizedResetTextFitsItsColumnBesideTheUsageValue() throws {
        let fixedNow = Date(timeIntervalSince1970: 1_794_470_400)
        let samples: [(Double, TimeInterval)] = [
            (65, 22 * 3_600 + 29 * 60), (72, 23 * 3_600 + 29 * 60), (100, 32 * 3_600),
            (65, 29 * 86_400 + 23 * 3_600), (65, 364 * 86_400), (65, 395 * 86_400), (65, 700 * 86_400)
        ]
        for language in LanguageSetting.allCases {
            try L10n.withLanguage(language) {
                var models: [DashboardRowModel] = []
                for (used, interval) in samples {
                    var data = WidgetData(
                        title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
                    data.resetsAt = fixedNow.addingTimeInterval(interval)
                    data.resetDisplayMode = .relative
                    models.append(data.dashboardRow(now: fixedNow))
                }
                for format in [TimeFormatSetting.twelveHour, .twentyFourHour] {
                    models.append(
                        DashboardRowModel(
                            label: L10n.metrics("Weekly"),
                            mark: .bar(
                                fill: 0.65, severity: .normal, value: "65%", reset: format.weekdayTime(fixedNow)),
                            showsClockTimes: true
                        ))
                }
                for model in models {
                    guard case .bar(_, _, _, let reset?, _) = model.mark else {
                        return XCTFail("Expected a countdown beside the usage value")
                    }
                    let text = Text(reset)
                        .font(DashboardMetricRow.resetFont)
                        .monospacedDigit()
                        .fixedSize()
                    let image = try XCTUnwrap(ShareCardRenderer.image(for: text))
                    let width = model.showsClockTimes ? DashboardGrid.clockResetWidth : DashboardGrid.resetWidth
                    XCTAssertLessThanOrEqual(image.size.width, width, "\(language.rawValue): \(reset)")
                }
                for appearance in [ColorScheme.light, .dark] {
                    let rows = VStack(spacing: 0) {
                        ForEach(Array(models.enumerated()), id: \.offset) { _, model in
                            DashboardMetricRow(model: model, onToggleMeterStyle: {}, onToggleResetDisplay: {})
                        }
                    }
                    .padding(.horizontal, DashboardGrid.cardPadding)
                    let image = try render(
                        rows, appearance: appearance, name: "countdown-columns-\(language.rawValue)-\(appearance)")
                    XCTAssertEqual(image.size.width, PanelMetrics.width - PanelMetrics.margin * 2)
                    XCTAssertEqual(image.size.height, DashboardGrid.rowHeight * CGFloat(models.count))
                }
            }
        }
    }

    func testCardsLayoutRendersSeparateAccountsWithExpandedMetersAndMatchingShareImage() throws {
        for appearance in [ColorScheme.light, .dark] {
            for language in LanguageSetting.allCases {
                try L10n.withLanguage(language) {
                    var heights: [DashboardLayoutStyle: CGFloat] = [:]
                    for style in DashboardLayoutStyle.allCases {
                        let view = DashboardProviderSection(family: codexFamily(), layoutStyle: style) { account in
                            DashboardAccountRows(
                                account: account,
                                plan: account.name == "Account 1" ? "Pro" : "Plus",
                                layoutStyle: style
                            )
                        }
                        let variant = "\(style.rawValue)-\(language.rawValue)-\(appearance)"
                        let image = try render(view, appearance: appearance, name: "layout-\(variant)")
                        XCTAssertEqual(image.size.width, PanelMetrics.width - PanelMetrics.margin * 2)
                        heights[style] = image.size.height
                        let shared = ShareCardView(family: codexFamily(), appearance: appearance, layoutStyle: style)
                        let shareImage = try XCTUnwrap(ShareCardRenderer.image(for: shared))
                        XCTAssertEqual(shareImage.size.width, ShareCardView.width)
                        try export(shareImage, name: "share-\(variant)")
                    }
                    XCTAssertGreaterThan(try XCTUnwrap(heights[.cards]), try XCTUnwrap(heights[.minimal]))
                }
            }
        }
    }

    private func codexFamily() -> DashboardFamily {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let second = Provider(id: "codex@ab12cd34", displayName: "Codex", icon: .providerMark("codex"))
        var trend = WidgetData(title: "Usage Trend", icon: provider.icon, kind: .count, used: 0, limit: nil)
        trend.isChart = true
        trend.chartPoints = (0..<30).map { MetricChartPoint(value: Double(($0 * 37) % 11), label: "d\($0)") }
        var today = WidgetData(title: "Today", icon: provider.icon, kind: .dollars, used: 0, limit: nil)
        today.isUsagePeriod = true
        today.values = [
            MetricValue(number: 4.08, kind: .dollars), MetricValue(number: 1_200_000, kind: .count, label: "tokens")
        ]
        var yesterday = WidgetData(title: "Yesterday", icon: provider.icon, kind: .dollars, used: 0, limit: nil)
        yesterday.isUsagePeriod = true
        yesterday.hasData = false
        var watch = WidgetData(title: "Reset Watch", icon: provider.icon, kind: .percent, used: 72, limit: 100)
        watch.forecast = .init(deadline: now.addingTimeInterval(2 * 86_400), communityYesPercent: 61)
        let session = meter("Session", used: 42, resetIn: 3 * 3_600, period: 5 * 3_600_000)
        var weekly = meter("Weekly", used: 91, resetIn: 2 * 86_400)
        weekly.softLimitUsedFraction = 0.8
        let first = DashboardAccount(
            provider: provider, providerName: "Codex", name: "Account 1", isInUse: true,
            lines: [
                line("codex.session", session),
                line("codex.weekly", weekly),
                line("codex.trend", trend),
                line("codex.today", today),
                line("codex.yesterday", yesterday),
                line("codex.resetWatch", watch)
            ])
        let secondAccount = DashboardAccount(
            provider: second, providerName: "Codex", name: "Account 2",
            lines: [
                line("codex@ab12cd34.session", meter("Session", used: 100, resetIn: 1_800, period: 5 * 3_600_000)),
                line("codex@ab12cd34.weekly", meter("Weekly", used: 20, resetIn: 20 * 3_600))
            ]
        )
        return DashboardFamily(id: "codex", provider: provider, displayName: "Codex", accounts: [first, secondAccount])
    }

    private func meter(_ title: String, used: Double, resetIn: TimeInterval, period: Int = 7 * 86_400_000) -> WidgetData
    {
        var data = WidgetData(title: title, icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(resetIn)
        data.periodDurationMs = period
        return data
    }

    private func line(_ id: String, _ data: WidgetData) -> DashboardLine {
        DashboardLine(
            descriptor: WidgetDescriptor(
                id: id, providerID: ProviderAccountID.providerID(ofMetric: id), metricLabel: data.title, sample: data),
            data: data
        )
    }

    private func render<V: View>(_ view: V, appearance: ColorScheme, name: String? = nil) throws -> NSImage {
        let framed =
            view
            .frame(width: PanelMetrics.width - PanelMetrics.margin * 2)
            .background(Theme.panelBody)
            .environment(\.colorScheme, appearance)
            .environment(\.drawsLevelsAsShapes, true)
            .environment(\.hoverTooltipsDisabled, true)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: framed))
        if let name { try export(image, name: name) }
        return image
    }

    private func pixels(of image: NSImage) throws -> CGImage {
        var rect = CGRect(origin: .zero, size: image.size)
        return try XCTUnwrap(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))
    }

    private func export(_ image: NSImage, name: String) throws {
        guard let folder = ProcessInfo.processInfo.environment["EGASU_DASHBOARD_SNAPSHOTS"] else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
        try png.write(to: url.appendingPathComponent("\(name).png"))
    }
    func testStackedMenuBarIconsRenderOneThroughFiveBars() throws {
        for count in 1...5 {
            var content = menuBarSample(limit: MenuBarLimit(count: count))
            content.overflow = 0
            let image = try XCTUnwrap(MenuBarStripRenderer.image(for: content, style: .bars))
            XCTAssertEqual(image.size.width, 18)
            XCTAssertEqual(image.size.height, 18)
            let bitmap = NSBitmapImageRep(cgImage: try pixels(of: image))
            let center = bitmap.pixelsWide / 2
            var visibleBars = 0
            var wasVisible = false
            for y in 0..<bitmap.pixelsHigh {
                let isVisible = (bitmap.colorAt(x: center, y: y)?.alphaComponent ?? 0) > 0.05
                if isVisible && !wasVisible { visibleBars += 1 }
                wasVisible = isVisible
            }
            XCTAssertEqual(visibleBars, count)
            try export(image, name: "menubar-bars-\(count)")
            for appearance in [ColorScheme.light, .dark] {
                _ = try render(
                    Image(nsImage: image).renderingMode(.template).frame(height: 30),
                    appearance: appearance, name: "menubar-bars-\(count)-\(appearance)")
            }
        }
    }

    func testPriorityListRendersEverySection() throws {
        let waitingProvider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let waitingAccount = DashboardAccount(provider: waitingProvider, providerName: "Claude", name: nil, lines: [])
        let board = PriorityBoard.make(
            accounts: codexFamily().accounts + [cursorAccount(), waitingAccount],
            pinned: ["codex.session"],
            burningFast: BurningFast(),
            useItOrLoseIt: true,
            now: now
        ) { account in
            switch account.id {
            case "cursor": .unavailable("Session expired")
            case "claude": .waiting
            default: .current
            }
        }
        XCTAssertFalse(board.pinned.isEmpty)
        XCTAssertFalse(board.attention.isEmpty)
        XCTAssertFalse(board.usedUp.isEmpty)
        XCTAssertFalse(board.useItOrLoseIt.isEmpty)
        XCTAssertFalse(board.notices.isEmpty)
        XCTAssertFalse(board.waiting.isEmpty)

        enum Section: CaseIterable { case pinned, attention, usedUp, useItOrLoseIt, notices, waiting }
        func without(_ section: Section) -> PriorityBoard {
            PriorityBoard(
                pinned: section == .pinned ? [] : board.pinned,
                runningOut: board.runningOut,
                attention: section == .attention ? [] : board.attention,
                usedUp: section == .usedUp ? [] : board.usedUp,
                useItOrLoseIt: section == .useItOrLoseIt ? [] : board.useItOrLoseIt,
                notices: section == .notices ? [] : board.notices,
                waiting: section == .waiting ? [] : board.waiting,
                summary: board.summary,
                showsClearRow: board.showsClearRow,
                nextUseItOrLoseItChange: board.nextUseItOrLoseItChange
            )
        }

        for appearance in [ColorScheme.light, .dark] {
            let image = try render(
                PriorityBoardList(board: board, now: now), appearance: appearance, name: "priority-\(appearance)")
            for section in Section.allCases {
                let reduced = try render(PriorityBoardList(board: without(section), now: now), appearance: appearance)
                XCTAssertGreaterThanOrEqual(image.size.height - reduced.size.height, 28, "\(appearance): \(section)")
            }
        }
    }

    func testPinnedRowsKeepTheirHeightThroughWarningSpentAndReset() throws {
        let provider = MockData.codex
        let balanceProvider = Provider(id: "openrouter", displayName: "OpenRouter", icon: .providerMark("openrouter"))
        let balance = WidgetData(title: "Balance", icon: balanceProvider.icon, kind: .dollars, used: 0, limit: nil,
                                 unboundedValueWord: "left", values: [MetricValue(number: 0, kind: .dollars)])
        let balanceLine = line("openrouter.balance", balance)
        let balanceDescriptor = balanceLine.descriptor.exportingLimit("balance", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        let balanceAccount = DashboardAccount(provider: balanceProvider, providerName: "OpenRouter", name: nil, lines: [
            DashboardLine(descriptor: balanceDescriptor, data: balance)
        ])
        for appearance in [ColorScheme.light, .dark] {
            for language in [LanguageSetting.english, .korean, .japanese] {
                try L10n.withLanguage(language) {
                    var expectedHeight: CGFloat?
                    for used in [20.0, 95, 100, 0] {
                        let lines = [
                            line("codex.weekly", meter("Weekly", used: used, resetIn: 3 * 86_400)),
                            line("codex.session", meter("Session", used: 60, resetIn: 2.5 * 3_600, period: 5 * 3_600_000)),
                            line("codex.credits", meter("Credits", used: 10, resetIn: 20 * 3_600)),
                        ]
                        let account = DashboardAccount(provider: provider, providerName: "Codex", name: "Account 1", lines: lines)
                        let pins = lines.map(\.id) + [balanceLine.id]
                        let board = PriorityBoard.make(accounts: [account, balanceAccount], pinned: Set(pins),
                                                       burningFast: BurningFast(), useItOrLoseIt: true, now: now)
                        XCTAssertEqual(board.pinned.map(\.id), pins)
                        XCTAssertTrue(board.attention.isEmpty)
                        XCTAssertTrue(board.usedUp.isEmpty)
                        XCTAssertTrue(board.useItOrLoseIt.isEmpty)
                        let image = try render(PriorityBoardList(board: board, now: now), appearance: appearance,
                                               name: "priority-pinned-\(Int(used))-\(language.rawValue)-\(appearance)")
                        if let expectedHeight {
                            XCTAssertEqual(image.size.height, expectedHeight, "상태가 바뀌어도 고정 행 높이 유지")
                        } else {
                            expectedHeight = image.size.height
                        }
                        XCTAssertGreaterThan(image.size.height, 46 * CGFloat(pins.count))
                    }
                }
            }
        }
    }

    func testMenuBarStripRendersBadgesAndOverflow() throws {
        func strip(firstBadge: String?, secondBadge: String?, overflow: Int = 0) throws -> NSImage {
            let content = MenuBarContent(
                items: [
                    MenuBarContent.Item(
                        id: "codex.weekly", icon: .providerMark("codex"), providerName: "Codex — Account 1",
                        badge: firstBadge, label: "Weekly", shortLabel: "Weekly", value: "9%"),
                    MenuBarContent.Item(
                        id: "codex@ab12cd34.session", icon: .providerMark("codex"), providerName: "Codex — Account 2",
                        badge: secondBadge, label: "Session", shortLabel: "Session", value: "14%"),
                    MenuBarContent.Item(
                        id: "cursor.usage", icon: .providerMark("cursor"), providerName: "Cursor", badge: nil,
                        label: "Premium Usage", shortLabel: "Premium", value: "$12")
                ], overflow: overflow)
            return try XCTUnwrap(MenuBarStripRenderer.textImage(for: content))
        }
        let plain = try strip(firstBadge: nil, secondBadge: nil)
        let badged = try strip(firstBadge: "A1", secondBadge: "A2")
        let otherInitials = try strip(firstBadge: "Z9", secondBadge: "Z8")
        let image = try strip(firstBadge: "A1", secondBadge: "A2", overflow: 2)

        XCTAssertGreaterThan(badged.size.width, plain.size.width)
        let badgedPixels = try XCTUnwrap(try pixels(of: badged).dataProvider?.data) as Data
        let otherPixels = try XCTUnwrap(try pixels(of: otherInitials).dataProvider?.data) as Data
        XCTAssertNotEqual(badgedPixels, otherPixels, "배지 글자가 실제 스트립 픽셀에 반영됨")
        XCTAssertGreaterThan(image.size.width, badged.size.width)
        XCTAssertLessThanOrEqual(image.size.height, 22, "메뉴 막대 높이 안에 들어감")
        try export(image, name: "menubar-strip")
    }

    func testMenuBarExtraIndicatorsCanBeHiddenWithoutChangingUsage() throws {
        var original = menuBarSample(limit: .upToTwo)
        original.updateAvailable = true
        original.nextInvalidation = now.addingTimeInterval(30)
        let plain = original.showingExtraIndicators(false)
        XCTAssertEqual(plain.items, original.items)
        XCTAssertEqual(plain.nextInvalidation, original.nextInvalidation)
        XCTAssertEqual(original.showingExtraIndicators(true), original)
        XCTAssertEqual(plain.accessibilityText, plain.items.map { "\($0.providerName) \($0.label) \($0.value)" }.joined(separator: "; "))
        for style in MenuBarStyle.allCases {
            let fullImage = try XCTUnwrap(MenuBarStripRenderer.image(for: original, style: style))
            let plainImage = try XCTUnwrap(MenuBarStripRenderer.image(for: plain, style: style))
            XCTAssertLessThan(plainImage.size.width, fullImage.size.width)
            if style == .bars { XCTAssertEqual(plainImage.size, NSSize(width: 18, height: 18)) }
            XCTAssertEqual(plainImage.accessibilityDescription, plain.accessibilityText)
            let restored = try XCTUnwrap(MenuBarStripRenderer.image(for: original, style: style))
            XCTAssertEqual(restored.size, fullImage.size)
            try export(plainImage, name: "menubar-\(style.rawValue)-plain")

            let empty = MenuBarContent(items: [], updateAvailable: true)
            XCTAssertNotNil(MenuBarStripRenderer.image(for: empty, style: style))
            XCTAssertNil(MenuBarStripRenderer.image(for: empty.showingExtraIndicators(false), style: style))
        }
    }

    private func cursorAccount() -> DashboardAccount {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        return DashboardAccount(provider: provider, providerName: "Cursor", name: nil, lines: [])
    }

    private func menuBarSample(limit: MenuBarLimit) -> MenuBarContent {
        MenuBarContent(items: (0..<limit.count).map { index in
            MenuBarContent.Item(
                id: "codex.meter\(index)", icon: .providerMark("codex"), providerName: "Codex",
                badge: "A\(index + 1)", label: "Weekly", shortLabel: "Weekly", value: "42%",
                fraction: Double(index + 1) / 6)
        }, overflow: 2)
    }

    func testClickableSpendValuesKeepTheSharedRingLayout() throws {
        let total = TotalSpend(period: .today, slices: [
            TotalSpendSlice(provider: MockData.claude, title: "Claude", amountUSD: 14, tokenCount: 14_000_000, estimated: false),
            TotalSpendSlice(provider: MockData.codex, title: "Codex", amountUSD: 9, tokenCount: 6_000_000, estimated: false),
        ])
        for appearance in [ColorScheme.light, .dark] {
            for metric in TotalSpendMetric.allCases {
                let projection = total.projection(for: metric)
                let staticImage = try render(
                    TotalSpendRingContent(projection: projection),
                    appearance: appearance, name: "spend-static-\(metric.rawValue)-\(appearance)"
                )
                let interactiveImage = try render(
                    TotalSpendRingContent(projection: projection, onCycleMetric: {}),
                    appearance: appearance, name: "spend-clickable-\(metric.rawValue)-\(appearance)"
                )
                XCTAssertEqual(interactiveImage.size, staticImage.size)
                XCTAssertEqual(interactiveImage.size.height, 104)
            }
        }
    }

    func testShareCardRendersWithFooterBand() throws {
        let card = ShareCardView(family: codexFamily(), plans: ["codex": "Pro"], appearance: .light)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        let bodyOnly = DashboardProviderSection(
            family: card.family.forSharing, layoutStyle: card.layoutStyle
        ) { account in
            DashboardAccountRows(
                account: account, plan: card.plans[account.id], layoutStyle: card.layoutStyle, showsEmptyMessage: true
            )
        }
        .padding(ShareCardView.inset)
        .frame(width: ShareCardView.width, alignment: .topLeading)
        .environment(\.drawsLevelsAsShapes, true)
        .environment(\.concealsAccountNames, card.blursAccountNames)
        .environment(\.hoverTooltipsDisabled, true)
        .environment(\.colorScheme, card.appearance)
        let bodyImage = try XCTUnwrap(ShareCardRenderer.image(for: bodyOnly))

        XCTAssertEqual(image.size.width, ShareCardView.width)
        XCTAssertGreaterThanOrEqual(image.size.height - bodyImage.size.height, 40)
        try export(image, name: "share-light")
    }

    func testUsageBreakdownPopoverRendersSummaryModelsAndEmptyState() throws {
        let models = [
            ModelUsageEntry(model: "claude-sonnet-4.5", totalTokens: 900_000, costUSD: 3.10),
            ModelUsageEntry(model: "claude-opus-4.1", totalTokens: 200_000, costUSD: 0.80),
            ModelUsageEntry(model: "claude-haiku-4.5", totalTokens: 100_000, costUSD: 0.18),
        ]
        let usage = UsageBreakdown(title: "Today", breakdown: ModelUsageBreakdown(
            totalTokens: 1_200_000, totalCostUSD: 4.08, models: models, sourceNote: "Estimated from local logs on this Mac."
        ))
        for appearance in [ColorScheme.light, .dark] {
            let detail = UsageBreakdownContent(
                usage: usage, providerName: "Claude", icon: .providerMark("claude"), figure: .cost,
                figureSelection: .constant(.cost)
            )
                .padding(UsageBreakdownDetail.padding)
                .frame(width: UsageBreakdownDetail.width, alignment: .leading)
                .background(Theme.panelBody)
                .environment(\.colorScheme, appearance)
                .environment(\.hoverTooltipsDisabled, true)
            let image = try XCTUnwrap(ShareCardRenderer.image(for: detail))
            XCTAssertGreaterThan(image.size.height, 120)
            try export(image, name: "usage-breakdown-\(appearance)")
        }
        let empty = UsageBreakdownContent(usage: UsageBreakdown(title: "Yesterday", breakdown: .empty), providerName: "Codex", icon: .providerMark("codex"), figure: .cost)
            .padding(UsageBreakdownDetail.padding)
            .frame(width: UsageBreakdownDetail.width, alignment: .leading)
            .background(Theme.panelBody)
        try export(try XCTUnwrap(ShareCardRenderer.image(for: empty)), name: "usage-breakdown-empty")
        let card = UsageBreakdownShareCard(usage: usage, providerName: "Claude", icon: .providerMark("claude"), figure: .tokens, appearance: .light)
        try export(try XCTUnwrap(ShareCardRenderer.image(for: card)), name: "usage-breakdown-share")
        var archived = usage.breakdown
        archived.period = ModelUsagePeriod(window: .last30, asOf: Calendar.current.startOfDay(for: now).addingTimeInterval(-1), calendar: .current)
        for appearance in [ColorScheme.light, .dark] {
            let archivedCard = UsageBreakdownShareCard(
                usage: UsageBreakdown(title: "Last 30 Days", breakdown: archived),
                providerName: "Claude", icon: .providerMark("claude"), figure: .cost, appearance: appearance
            )
            try export(try XCTUnwrap(ShareCardRenderer.image(for: archivedCard)), name: "usage-breakdown-archived-share-\(appearance)")
        }
    }

    func testUsageTrendDetailRendersInTheSharedPopoverFrame() throws {
        let firstDay = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 11))!
        let points = (0..<31).map {
            MetricChartPoint(value: Double(($0 * 37) % 11) * 100_000, label: "", date: Calendar.current.date(byAdding: .day, value: $0, to: firstDay))
        }
        for appearance in [ColorScheme.light, .dark] {
            let detail = UsageTrendDetail(title: "Usage Trend", points: points, note: "From your Codex logs (estimated)") { _ in }
                .background(Theme.panelBody)
                .environment(\.colorScheme, appearance)
            let image = try XCTUnwrap(ShareCardRenderer.image(for: detail))
            XCTAssertEqual(image.size.width, 288)
            XCTAssertGreaterThan(image.size.height, 110)
            try export(image, name: "usage-trend-\(appearance)")
        }
    }

    func testSavedBreakdownAndZeroPeriodRowRender() throws {
        let saved = UsageBreakdownSavedDetail(
            title: "Today", figures: ["$4.08", "1.2M tokens"], savedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            status: DashboardAccountStatus(), onHoverChange: { _ in }
        )
        .background(Theme.panelBody)
        let savedImage = try XCTUnwrap(ShareCardRenderer.image(for: saved))
        XCTAssertGreaterThan(savedImage.size.height, 80)
        try export(savedImage, name: "usage-breakdown-saved")

        let name = "EgasuTests.ZeroRowSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        let registry = WidgetRegistry.from(ProviderCatalog.make())
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults)
        store.snapshots["claude"] = .init(
            providerID: "claude", displayName: "Claude",
            lines: [.progress(label: "Weekly", used: 30, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)],
            usageHistory: .init(series: .init(daily: []))
        )
        let today = store.data(for: try XCTUnwrap(registry.descriptor(id: "claude.today")))
        XCTAssertNil(today.rowDetail(reportsModels: true))
        guard case .value(let value, _, _) = today.dashboardRow().mark else { return XCTFail("값 행이어야 함") }
        L10n.withLanguage(.english) { XCTAssertTrue(value.hasPrefix("$0.00"), value) }
        let row = DashboardMetricRow(model: today.dashboardRow())
            .padding(.horizontal, DashboardGrid.cardPadding)
            .frame(width: PanelMetrics.width)
            .background(Theme.panelBody)
        try export(try XCTUnwrap(ShareCardRenderer.image(for: row)), name: "period-row-zero")
    }

}
