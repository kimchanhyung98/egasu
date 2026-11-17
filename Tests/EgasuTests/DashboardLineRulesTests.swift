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
                provider: provider, providerName: "Codex", name: "Work",
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
        let state = HoverPopoverState(hideGrace: .milliseconds(1))
        state.isPresented = true
        state.setPinned(true)
        state.detailHover(false)
        state.releasePin(after: .milliseconds(80))
        try await Task.sleep(for: .milliseconds(15))
        XCTAssertTrue(state.isPresented)
        XCTAssertTrue(state.isPinned)

        let deadline = ContinuousClock.now + .seconds(2)
        while state.isPresented && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(state.isPresented, "결과를 읽을 시간 뒤에는 포인터 이탈 닫기 복귀")

        state.isPresented = true
        state.setPinned(true)
        state.releasePin(after: .milliseconds(30))
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        state.isPresented = true
        state.setPinned(true)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertTrue(state.isPinned, "이전 결과의 예약이 새 확인의 고정을 풀지 않음")
        state.dismiss()
    }

    func testSharedHomeOnlyRowsHideOnlyOnExtraAccountCards() {
        for suffix in ["trend", "today", "yesterday", "last30", "resetWatch"] {
            XCTAssertTrue(AppContainer.hidesMetric("codex@ab12cd34.\(suffix)", onCard: "codex@ab12cd34"))
            XCTAssertFalse(AppContainer.hidesMetric("codex.\(suffix)", onCard: "codex"), "공유 홈 카드는 그대로 표시")
        }
        XCTAssertFalse(AppContainer.hidesMetric("codex@ab12cd34.weekly", onCard: "codex@ab12cd34"))
        XCTAssertTrue(
            AppContainer.hidesMetric("claude@profile-work.last30", onCard: "claude@profile-work"), "공통 이력은 한 곳만 표시")
        for suffix in ["session", "spark", "sparkWeekly", "credits", "rateLimitResets"] {
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
