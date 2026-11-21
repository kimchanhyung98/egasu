import Observation
import XCTest
@testable import Egasu

@MainActor
final class DashboardLineRulesTests: XCTestCase {
    func testFirstReadFailureKeepsTheAccountAndPriorityNotice() async throws {
        let catalog = WidgetRegistry.from(ProviderCatalog.make())
        for providerID in ["kimi", "kiro"] {
            let provider = try XCTUnwrap(catalog.provider(id: providerID))
            let descriptors = catalog.descriptors(for: providerID)
            let runtime = SequenceProviderRuntime(
                provider: provider, descriptors: descriptors,
                snapshots: [
                    .error(provider: provider, message: "Sign in again")
                ])
            let suite = "EgasuTests.FirstReadFailure.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let store = WidgetDataStore(
                registry: WidgetRegistry(providers: [provider], descriptors: descriptors), providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshot", ttl: 600),
                defaults: defaults
            )
            var family = DashboardFamily(
                id: providerID, provider: provider, displayName: provider.displayName,
                accounts: [
                    DashboardAccount(
                        provider: provider, providerName: provider.displayName, name: nil, lines: [],
                        waitingMetricIDs: descriptors.map(\.id)
                    )
                ]
            )
            XCTAssertTrue(family.isVisible(headerNotice: store.headerNotice(for:)))

            await store.refreshAll(force: true)

            let lines = descriptors.map { DashboardLine(descriptor: $0, data: store.data(for: $0)) }
            XCTAssertFalse(store.isWaitingForFirstReading(providerID))
            family.accounts = [
                DashboardAccount(provider: provider, providerName: provider.displayName, name: nil, lines: lines)
            ]
            XCTAssertTrue(family.accounts[0].lines.isEmpty)
            let visible = [family].filter { $0.isVisible(headerNotice: store.headerNotice(for:)) }
            XCTAssertEqual(visible.map(\.id), [providerID], "행이 없어도 오류를 확인할 계정은 유지")
            let board = store.priorityBoard(accounts: visible.flatMap(\.accounts), pinned: [], now: Date())
            XCTAssertEqual(board.summary, .unavailable)
            XCTAssertEqual(board.notices.map(\.id), [providerID])
        }
    }

    func testPinnedQuotasFollowMissingRetainedAndRecoveredReadingsWithoutChangingSavedOrder() async throws {
        let provider = Provider(id: "test", displayName: "Test", icon: .providerMark("codex"))
        let descriptors = ["Session", "Weekly"].map {
            WidgetDescriptor.percent(id: "test.\($0.lowercased())", provider: provider, title: $0)
        }
        let registry = WidgetRegistry(providers: [provider], descriptors: descriptors)
        let now = Date()
        func success(weekly: Double?) -> ProviderSnapshot {
            var lines: [MetricLine] = [.progress(label: "Session", used: 10, limit: 100, format: .percent)]
            if let weekly { lines.append(.progress(label: "Weekly", used: weekly, limit: 100, format: .percent)) }
            return .make(provider: provider, plan: nil, lines: lines, refreshedAt: now)
        }
        let failure = ProviderSnapshot.error(provider: provider, message: "Sign in again")
        let runtime = SequenceProviderRuntime(provider: provider, descriptors: descriptors, snapshots: [
            failure, success(weekly: 20), failure, success(weekly: nil), success(weekly: 87), success(weekly: 20)
        ])
        let suite = "EgasuTests.PinnedReadings.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        layout.setMetric("test.session", pinned: true)
        layout.setMetric("test.weekly", pinned: true)
        XCTAssertTrue(layout.reorderMetric(dragged: "test.weekly", target: "test.session", in: provider.id))
        let savedOrder = ["test.weekly", "test.session"]
        let store = WidgetDataStore(
            registry: registry, providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshot", ttl: 600),
            defaults: defaults, now: { now }
        )
        func board() throws -> PriorityBoard {
            let group = try XCTUnwrap(layout.displayGroups.first)
            let account = DashboardAccount(
                provider: provider, providerName: provider.displayName, name: nil,
                lines: group.widgets.compactMap { layout.descriptor(for: $0) }
                    .map { DashboardLine(descriptor: $0, data: store.data(for: $0)) }
            )
            let family = DashboardFamily(id: provider.id, provider: provider, displayName: provider.displayName, accounts: [account])
            XCTAssertTrue(family.isVisible(headerNotice: store.headerNotice(for:)))
            XCTAssertEqual(layout.priorityPinIDs, Set(savedOrder))
            XCTAssertEqual(group.widgets.map(\.descriptorID), savedOrder)
            return store.priorityBoard(accounts: family.accounts, pinned: layout.priorityPinIDs, now: now)
        }

        await store.refreshAll(force: true)
        let missing = try board()
        XCTAssertTrue(missing.pinned.isEmpty)
        XCTAssertEqual(missing.notices.map(\.id), [provider.id])
        XCTAssertFalse(missing.showsClearRow)
        XCTAssertTrue(MenuBarContentBuilder.build(board: missing, limit: .upToThree, selection: .pinnedOnly, now: now).isEmpty)

        await store.refreshAll(force: true)
        let loaded = try board()
        XCTAssertEqual(loaded.pinned.map(\.id), savedOrder)
        XCTAssertTrue(loaded.showsClearRow)

        await store.refreshAll(force: true)
        let retained = try board()
        XCTAssertEqual(retained.pinned.map(\.id), savedOrder)
        XCTAssertEqual(retained.pinned.map { $0.data.used }, [20, 10])
        XCTAssertEqual(retained.notices.map(\.id), [provider.id])
        XCTAssertFalse(retained.showsClearRow)

        await store.refreshAll(force: true)
        XCTAssertEqual(try board().pinned.map(\.id), ["test.session"], "보고가 빠진 한도만 숨기며 고정 설정은 유지")

        await store.refreshAll(force: true)
        let recovered = try board()
        XCTAssertEqual(recovered.pinned.map(\.id), savedOrder)
        XCTAssertTrue(recovered.notices.isEmpty)
        XCTAssertEqual(recovered.runningOut.map(\.id), ["test.weekly"])
        XCTAssertTrue(recovered.attention.isEmpty)
        XCTAssertFalse(recovered.showsClearRow)
        XCTAssertEqual(MenuBarContentBuilder.build(board: recovered, limit: .upToThree, selection: .pinnedOnly, now: now).items.map(\.id), savedOrder)

        await store.refreshAll(force: true)
        XCTAssertTrue(try board().showsClearRow)
        let reloaded = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(reloaded.priorityPinIDs, Set(savedOrder))
        XCTAssertEqual(reloaded.displayGroups.first?.widgets.map(\.descriptorID), savedOrder)
        XCTAssertEqual(runtime.refreshCount, 6)
    }

    func testPeriodRowDetailFollowsWhatWasReported() {
        let spent = period([MetricValue(number: 4.08, kind: .dollars), MetricValue(number: 1_200_000, kind: .count, label: "tokens")])
        XCTAssertEqual(spent.rowDetail(reportsModels: true), .saved, "합계만 있고 모델 내역이 없으면 합계 패널")
        XCTAssertNil(spent.rowDetail(reportsModels: false), "모델 내역을 내지 않는 프로바이더는 툴팁만")

        var detailed = spent
        detailed.modelBreakdown = ModelUsageBreakdown(
            totalTokens: 1_200_000, totalCostUSD: 4.08,
            models: [ModelUsageEntry(model: "gpt-5", totalTokens: 1_200_000, costUSD: 4.08)], sourceNote: ""
        )
        XCTAssertEqual(detailed.rowDetail(reportsModels: true), .breakdown)

        let zero = period([MetricValue(number: 0, kind: .dollars), MetricValue(number: 0, kind: .count, label: "tokens")])
        XCTAssertNil(zero.rowDetail(reportsModels: false), "0 행은 값을 유지하고 상세는 생략")
        XCTAssertNil(zero.rowDetail(reportsModels: true))
        var missing = zero
        missing.hasData = false
        XCTAssertEqual(missing.rowDetail(reportsModels: true), .empty)
    }

    func testZeroCostDoesNotHideTokenUsageDetails() {
        var free = period([MetricValue(number: 0, kind: .dollars), MetricValue(number: 200, kind: .count, label: "tokens")])
        free.selection = .kind(.dollars)
        XCTAssertEqual(free.rowDetail(reportsModels: true), .saved, "비용만 표시해도 토큰 내역은 유지")
        free.modelBreakdown = ModelUsageBreakdown(
            totalTokens: 200, totalCostUSD: 0,
            models: [ModelUsageEntry(model: "free-model", totalTokens: 200, costUSD: 0)], sourceNote: ""
        )
        XCTAssertEqual(free.rowDetail(reportsModels: true), .breakdown)

        var unpriced = period([MetricValue(number: 200, kind: .count, label: "tokens")])
        unpriced.modelBreakdown = ModelUsageBreakdown(
            totalTokens: 200, totalCostUSD: nil,
            models: [ModelUsageEntry(model: "new-model", totalTokens: 200, costUSD: nil)], sourceNote: ""
        )
        XCTAssertEqual(unpriced.rowDetail(reportsModels: true), .breakdown)
    }

    func testChartRowOpensItsTrendOnlyWithData() {
        var chart = WidgetData(title: "Usage Trend", icon: .providerMark("codex"), kind: .count, used: 0, limit: nil)
        chart.isChart = true
        XCTAssertNil(chart.rowDetail(reportsModels: true), "표시할 차트 포인트가 없으면 상세를 열지 않음")
        chart.chartPoints = [.init(value: 120, label: "2026-11-18")]
        XCTAssertEqual(chart.rowDetail(reportsModels: true), .trend)
        chart.hasData = false
        XCTAssertNil(chart.rowDetail(reportsModels: true))
    }

    func testSavedBreakdownReasonPrefersNoticeThenStaleness() {
        let stale = StalenessHint(label: "Outdated", tooltip: "Last updated 2h ago")
        L10n.withLanguage(.english) {
            XCTAssertEqual(UsageBreakdownSavedState.reason(notice: "Sign in again", staleness: stale), "Sign in again")
            XCTAssertEqual(UsageBreakdownSavedState.reason(notice: nil, staleness: stale), "Last updated 2h ago")
            XCTAssertEqual(UsageBreakdownSavedState.reason(notice: nil, staleness: nil), "Refresh to load the details for this range.")
        }
    }

    private func period(_ values: [MetricValue]) -> WidgetData {
        var data = WidgetData(title: "Today", icon: .providerMark("codex"), kind: .dollars, used: 0, limit: nil)
        data.isUsagePeriod = true
        data.values = values
        return data
    }

    func testEmptyFamilyWithoutANoticeStaysHidden() {
        let provider = Provider(id: "kimi", displayName: "Kimi", icon: .providerMark("kimi"))
        let family = DashboardFamily(
            id: provider.id, provider: provider, displayName: provider.displayName,
            accounts: [DashboardAccount(provider: provider, providerName: provider.displayName, name: nil, lines: [])]
        )
        XCTAssertFalse(family.isVisible(headerNotice: { _ in nil }))
    }

    func testNoDataLimitAndValueRowsHideWhilePeriodAndChartRowsStay() {
        XCTAssertTrue(line(hasData: true).isVisible)
        XCTAssertFalse(line(hasData: false).isVisible, "데이터 없는 한도·값 행은 숨김")
        XCTAssertTrue(line(hasData: false) { $0.isUsagePeriod = true }.isVisible, "기간 행은 No data로 유지")
        XCTAssertTrue(line(hasData: false) { $0.isChart = true }.isVisible, "차트 행은 No data로 유지")
    }

    func testPriorityAmountUsesTheReportedUnboundedValue() {
        let provider = Provider(id: "openrouter", displayName: "OpenRouter", icon: .providerMark("openrouter"))
        let descriptor = WidgetDescriptor.values(id: "openrouter.balance", provider: provider, title: "Balance")
        let snapshot = ProviderSnapshot.make(
            provider: provider, plan: nil,
            lines: [.values(label: descriptor.metricLabel, values: [.init(number: 42.5, kind: .dollars)])],
            refreshedAt: Date()
        )
        let data = WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())

        XCTAssertEqual(data.used, 0)
        XCTAssertEqual(data.amountText, "$42.50")
    }

    func testResetExpiryRowNeedsAnAvailableCredit() {
        XCTAssertFalse(line(hasData: true) { $0.showsResetExpiries = true }.isVisible, "남은 초기화가 없으면 숨김")
        XCTAssertFalse(line(hasData: false) { $0.showsResetExpiries = true }.isVisible)
    }

    func testLastResetClaimKeepsTheSameRowAndDetailUntilItCloses() throws {
        let provider = MockData.codex
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets", provider: provider, title: "Rate Limit Resets", showsResetExpiries: true
        )
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: .init(
            auth: CodexAuth(tokens: CodexTokens(accessToken: "fixture-token")), source: .keychain
        )))
        var data = descriptor.sample
        data.hasData = true
        data.codexResetClaimBinding = binding
        data.values = [.init(number: 1, kind: .count, label: "available")]
        data.expiriesAt = [Date(timeIntervalSince1970: 1_800_000_000)]

        func account(_ data: WidgetData, retaining: [String: CodexResetClaimBinding]) -> DashboardAccount {
            DashboardAccount(
                provider: provider, providerName: "Codex", name: "Work", email: "work@example.com",
                lines: [.init(descriptor: descriptor, data: data)], retainingResetClaims: retaining
            )
        }

        let before = try XCTUnwrap(account(data, retaining: [:]).lines.first)
        data.values = [.init(number: 0, kind: .count, label: "available")]
        data.expiriesAt = []
        let retained = [descriptor.id: binding]
        let during = account(data, retaining: retained)
        XCTAssertTrue(during.isVisible(headerNotice: { _ in nil }), "유일한 행이어도 계정 상세 앵커 유지")
        let after = try XCTUnwrap(during.lines.first)
        XCTAssertEqual(after.id, before.id)
        XCTAssertEqual(after.data.resetCreditCount, 0)
        XCTAssertEqual(during.showingEmail.name, "work@example.com")
        XCTAssertEqual(during.showingEmail.lines.map(\.id), [after.id])
        XCTAssertNil(during.showingEmail.hidingEmail.name)
        XCTAssertEqual(during.showingEmail.hidingEmail.lines.map(\.id), [after.id])
        for style in DashboardLayoutStyle.allCases {
            let original = DashboardLiveRow(line: before, layoutStyle: style)
            let updated = DashboardLiveRow(line: after, layoutStyle: style, retainsResetClaimRow: true)
            XCTAssertTrue(original.needsClock)
            XCTAssertTrue(updated.needsClock, "만료 목록이 비어도 팝오버를 소유한 뷰 유지")
            XCTAssertTrue(updated.hasDetail)
        }
        XCTAssertTrue(account(data, retaining: [:]).lines.isEmpty, "상세를 닫으면 일반 0개 숨김 복귀")
        data.codexResetClaimBinding = try XCTUnwrap(CodexResetClaimBinding(authState: .init(
            auth: CodexAuth(tokens: CodexTokens(accessToken: "different-fixture-token")), source: .keychain
        )))
        XCTAssertTrue(account(data, retaining: retained).lines.isEmpty, "교체 계정에는 이전 요청의 행을 남기지 않음")
    }

    func testResetClaimResultOutlivesPointerExitAndDismissCancelsItsDelayedRelease() async throws {
        let hold = Duration.milliseconds(80)
        let resultHold = expectation(description: "Result pin waits for the hold duration")
        let dismissedHold = expectation(description: "Old result pin waits before dismissal")
        let cancelledHold = expectation(description: "Dismissing cancels the old result hold")
        let resumedHold = expectation(description: "Old result hold resumes after reopening")
        var scheduledHold = resultHold
        var pendingWait: CheckedContinuation<Void, Never>?
        let state = HoverPopoverState(
            hideGrace: .milliseconds(1),
            waitForPinRelease: { delay in
                XCTAssertEqual(delay, hold)
                guard !Task.isCancelled else { return }
                let isOldHold = scheduledHold === dismissedHold
                await withTaskCancellationHandler {
                    await withCheckedContinuation {
                        pendingWait = $0
                        scheduledHold.fulfill()
                    }
                } onCancel: {
                    if isOldHold { cancelledHold.fulfill() }
                }
                if isOldHold { resumedHold.fulfill() }
            })
        defer {
            state.dismiss()
            pendingWait?.resume()
        }

        state.isPresented = true
        state.setPinned(true)
        state.detailHover(false)
        state.releasePin(after: hold)
        await fulfillment(of: [resultHold], timeout: 3)
        XCTAssertTrue(state.isPresented)
        XCTAssertTrue(state.isPinned)

        let closed = expectation(description: "Unpinning closes the popover after the pointer has left")
        withObservationTracking {
            _ = state.isPresented
        } onChange: {
            closed.fulfill()
        }
        try XCTUnwrap(pendingWait).resume()
        pendingWait = nil
        await fulfillment(of: [closed], timeout: 3)
        XCTAssertFalse(state.isPinned)
        XCTAssertFalse(state.isPresented, "결과를 읽을 시간 뒤에는 포인터 이탈 닫기 복귀")

        scheduledHold = dismissedHold
        state.isPresented = true
        state.setPinned(true)
        state.releasePin(after: hold)
        await fulfillment(of: [dismissedHold], timeout: 3)
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.isPinned)
        await fulfillment(of: [cancelledHold], timeout: 3)

        state.isPresented = true
        state.setPinned(true)
        try XCTUnwrap(pendingWait).resume()
        pendingWait = nil
        await fulfillment(of: [resumedHold], timeout: 3)
        XCTAssertTrue(state.isPinned, "이전 결과의 예약이 새 확인의 고정을 풀지 않음")
    }

    func testSharedHomeOnlyRowsHideOnlyOnExtraAccountCards() {
        for suffix in ["trend", "today", "yesterday", "last30", "resetWatch"] {
            XCTAssertTrue(AppContainer.hidesMetric("codex@ab12cd34.\(suffix)", onCard: "codex@ab12cd34"))
            XCTAssertFalse(AppContainer.hidesMetric("codex.\(suffix)", onCard: "codex"), "공유 홈 카드는 그대로 표시")
        }
        XCTAssertFalse(AppContainer.hidesMetric("codex@ab12cd34.weekly", onCard: "codex@ab12cd34"))
        XCTAssertTrue(
            AppContainer.hidesMetric("claude@profile-work.last30", onCard: "claude@profile-work"), "공통 이력은 한 곳만 표시")
        for suffix in ["session", "monthly", "individualCredits", "spark", "sparkWeekly", "sparkMonthly", "credits", "rateLimitResets"] {
            XCTAssertFalse(AppContainer.hidesMetric("codex@ab12cd34.\(suffix)", onCard: "codex@ab12cd34"))
        }
        XCTAssertFalse(
            AppContainer.hidesMetric("cursor@remote.today", onCard: "cursor@remote"), "Claude·Codex 밖의 카드는 대상 아님")
        XCTAssertFalse(AppContainer.isSharedHomeOnlyMetric("codex.today", cardID: "codex@ab12cd34"), "다른 카드의 지표는 대상 아님")
    }

    private func line(hasData: Bool, configure: (inout WidgetData) -> Void = { _ in }) -> DashboardLine {
        var data = WidgetData(title: "Row", icon: .providerMark("codex"), kind: .percent, used: 10, limit: 100)
        data.hasData = hasData
        configure(&data)
        let descriptor = WidgetDescriptor(id: "codex.row", providerID: "codex", metricLabel: "Row", sample: data)
        return DashboardLine(descriptor: descriptor, data: data)
    }
}

@MainActor
final class ResetWatchRefreshGateTests: XCTestCase {
    func testShownWatchIsFetched() {
        let layout = makeLayout()
        layout.setMetricEnabled("codex.resetWatch", true)
        XCTAssertTrue(AppContainer.needsResetWatch(layout: layout, notificationsEnabled: false))
    }

    func testHiddenWatchIsFetchedOnlyForAlerts() {
        let layout = makeLayout()
        layout.setMetricEnabled("codex.resetWatch", false)
        XCTAssertTrue(AppContainer.needsResetWatch(layout: layout, notificationsEnabled: true))
        XCTAssertFalse(AppContainer.needsResetWatch(layout: layout, notificationsEnabled: false), "표시도 알림도 없으면 조회 중단")
    }

    func testLegacyWatchOnAnExtraAccountCardDoesNotOverrideTheSharedHiddenChoice() throws {
        let providers = [CodexProvider.makeProvider(id: "codex"), CodexProvider.makeProvider(id: "codex@ab12cd34")]
        let registry = WidgetRegistry(
            providers: providers, descriptors: providers.flatMap { CodexProvider(provider: $0).widgetDescriptors })
        let name = "EgasuTests.ResetWatchGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        defaults.set(["codex.resetWatch"], forKey: "layout.disabledMetrics")
        defaults.set(
            try JSONEncoder().encode([PlacedWidget(descriptorID: "codex@ab12cd34.resetWatch")]), forKey: "layout")
        let layout = LayoutStore(registry: registry, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(layout.isMetricEnabled("codex.resetWatch"))
        XCTAssertFalse(layout.isMetricEnabled("codex@ab12cd34.resetWatch"))

        XCTAssertFalse(
            AppContainer.needsResetWatch(layout: layout, notificationsEnabled: false),
            "추가 계정 카드는 Reset Watch 행을 숨기므로 조회 이유가 아님"
        )
    }

    private func makeLayout() -> LayoutStore {
        let name = "EgasuTests.ResetWatchGate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return LayoutStore(
            registry: WidgetRegistry.from(ProviderCatalog.make()), defaults: defaults, storageKey: "layout")
    }
}
