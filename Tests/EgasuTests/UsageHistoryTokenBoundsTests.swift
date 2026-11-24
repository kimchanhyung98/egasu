import XCTest
@testable import Egasu

final class UsageHistoryTokenBoundsTests: XCTestCase {
    private let now = Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 23, hour: 12))!
    private let day = "2026-11-23"
    private let descriptor = UsageHistoryDescriptor(scope: .machineLocal, estimatedCost: true, sourceNote: "logs")

    func testMergedPeerCountsMustNotOverflowAfterDocumentValidation() throws {
        let first = document("first", tokens: 10)
        let second = document("second", tokens: Int.max)
        try first.validate()
        try second.validate()
        let normalPeer = document("normal", tokens: 7)
        let local = ProviderSnapshot(
            providerID: "codex", displayName: "Codex", lines: [], usageHistory: first.providers["codex"])

        let result = UsageHistoryAggregator.merged(
            localSnapshots: ["codex": local], peerDocuments: [second, normalPeer], descriptors: ["codex": descriptor],
            now: now)

        let history = try XCTUnwrap(result["codex"])
        XCTAssertEqual(history.series.daily.first?.totalTokens, 17)
        XCTAssertEqual(history.series.daily.first?.costUSD, 2)
        XCTAssertTrue(history.hasRejectedNumericContributions)
        let rendered = UsageHistorySnapshotRenderer.render(
            local: local, history: history, descriptor: descriptor, now: now)
        XCTAssertNotNil(rendered.warning)
        XCTAssertTrue(rendered.isDegraded == true)
    }

    func testPeriodOverflowRejectsTheEntireContributionBeforeApplyingCosts() throws {
        let normal = history(tokens: 10)
        let oversized = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                .init(date: day, totalTokens: Int.max, costUSD: 5),
                .init(date: "2026-11-22", totalTokens: 1, costUSD: 7)
            ]), unknownModelsByDay: [day: ["rejected-model"]])
        try document("oversized", history: oversized).validate()

        let merged = UsageHistoryAggregator.mergeHistories([normal, oversized], now: now)

        XCTAssertEqual(merged.series.daily, normal.series.daily)
        XCTAssertTrue(merged.unknownModelsByDay.isEmpty)
        XCTAssertTrue(merged.hasRejectedNumericContributions)
        _ = UsageHistorySnapshotRenderer.render(local: snapshot(), history: merged, descriptor: descriptor, now: now)
    }

    func testModelAndVariantBudgetsProtectTheirIndependentSums() throws {
        for variants in [false, true] {
            let normal = modelHistory(tokens: 2, variantTokens: variants ? 2 : nil)
            let oversized = modelHistory(tokens: variants ? 1 : Int.max, variantTokens: variants ? Int.max : nil)
            try document("oversized", history: oversized).validate()

            let merged = UsageHistoryAggregator.mergeHistories([normal, oversized], now: now)

            XCTAssertEqual(merged.modelUsage?.daily.first?.models.first?.totalTokens, 2)
            XCTAssertEqual(merged.series.daily, normal.series.daily)
            XCTAssertTrue(merged.hasRejectedNumericContributions)
            _ = UsageHistorySnapshotRenderer.render(
                local: snapshot(), history: merged, descriptor: descriptor, now: now)
        }
    }

    func testEmptyVariantsStillReserveTheRenderersFallbackBudget() throws {
        let oversized = modelHistory(tokens: 1, variantTokens: Int.max, name: " Model ")
        var fallback = modelHistory(tokens: 1, variantTokens: nil)
        fallback.modelUsage?.daily[0].models[0].variants = []
        try document("first", history: oversized).validate()
        try document("second", history: fallback).validate()

        let merged = UsageHistoryAggregator.mergeHistories([oversized, fallback], now: now)

        XCTAssertTrue(merged.hasRejectedNumericContributions)
        XCTAssertEqual(merged.series.daily.first?.totalTokens, 1)
    }

    func testIndependentModelTotalsAreNotAddedTogether() throws {
        let first = modelHistory(tokens: Int.max, variantTokens: nil, name: "First")
        let second = modelHistory(tokens: 1, variantTokens: nil, name: "Second")
        let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

        XCTAssertFalse(merged.hasRejectedNumericContributions)
        XCTAssertEqual(merged.series.daily.first?.totalTokens, 2)
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.count, 2)
        _ = UsageHistorySnapshotRenderer.render(local: snapshot(), history: merged, descriptor: descriptor, now: now)
    }

    func testIndependentVariantSlugsAreNotAddedTogether() throws {
        var first = modelHistory(tokens: 1, variantTokens: Int.max)
        var second = modelHistory(tokens: 1, variantTokens: 1)
        first.modelUsage?.daily[0].models[0].variants?[0].model = "first-slug"
        second.modelUsage?.daily[0].models[0].variants?[0].model = "second-slug"
        let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

        XCTAssertFalse(merged.hasRejectedNumericContributions)
        XCTAssertEqual(merged.series.daily.first?.totalTokens, 2)
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.first?.variants?.count, 2)
        _ = UsageHistorySnapshotRenderer.render(local: snapshot(), history: merged, descriptor: descriptor, now: now)
    }

    func testAnExplicitVariantPreventsFallbackForTheMergedDayModel() {
        let first = modelHistory(tokens: 1, variantTokens: Int.max)
        let second = modelHistory(tokens: 1, variantTokens: nil)
        let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

        XCTAssertFalse(merged.hasRejectedNumericContributions)
        XCTAssertEqual(merged.series.daily.first?.totalTokens, 2)
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.first?.totalTokens, 2)
        XCTAssertEqual(merged.modelUsage?.daily.first?.models.first?.variants?.first?.totalTokens, Int.max)
        _ = UsageHistorySnapshotRenderer.render(local: snapshot(), history: merged, descriptor: descriptor, now: now)
    }

    func testPeriodBudgetsUseNormalizedModelAndRawVariantKeys() throws {
        for variants in [false, true] {
            let first = modelHistory(
                tokens: variants ? 1 : Int.max, variantTokens: variants ? Int.max : nil,
                name: " Model ")
            var second = modelHistory(tokens: 1, variantTokens: variants ? 1 : nil, name: "model")
            second.modelUsage?.daily[0].date = "2026-11-22"
            second.series.daily[0].date = "2026-11-22"
            try document("first", history: first).validate()
            try document("second", history: second).validate()

            let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

            XCTAssertTrue(merged.hasRejectedNumericContributions)
            XCTAssertEqual(merged.series.daily.first?.totalTokens, 1)
            _ = UsageHistorySnapshotRenderer.render(
                local: snapshot(), history: merged, descriptor: descriptor, now: now)
        }
    }

    func testModelsWithoutASeriesDayDoNotConsumeThePeriodBudget() throws {
        for variants in [false, true] {
            let first = modelHistory(tokens: variants ? 1 : Int.max, variantTokens: variants ? Int.max : nil)
            var second = modelHistory(tokens: 1, variantTokens: variants ? 1 : nil)
            second.modelUsage?.daily[0].date = "2026-11-22"
            try document("second", history: second).validate()
            let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

            XCTAssertFalse(merged.hasRejectedNumericContributions)
            XCTAssertEqual(merged.series.daily.first?.totalTokens, 2)
            XCTAssertEqual(merged.modelUsage?.daily.count, 2)
            _ = UsageHistorySnapshotRenderer.render(
                local: snapshot(), history: merged, descriptor: descriptor, now: now)

            var activation = history(tokens: 1)
            activation.series.daily[0].date = "2026-11-22"
            let activated = UsageHistoryAggregator.mergeHistories([first, second, activation], now: now)
            XCTAssertTrue(activated.hasRejectedNumericContributions)
            XCTAssertEqual(activated.series.daily, merged.series.daily)
            XCTAssertEqual(activated.modelUsage, merged.modelUsage)
        }
    }

    func testNoSpendRowsSkipPeriodModelBudgetsUntilUsageArrives() {
        var first = modelHistory(tokens: Int.max, variantTokens: nil)
        var second = modelHistory(tokens: 1, variantTokens: nil)
        first.series.daily[0].totalTokens = 0
        first.series.daily[0].costUSD = 0
        second.series.daily[0] = .init(date: "2026-11-22", totalTokens: 0, costUSD: 0)
        second.modelUsage?.daily[0].date = "2026-11-22"
        let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

        XCTAssertFalse(merged.hasRejectedNumericContributions)
        XCTAssertEqual(merged.modelUsage?.daily.count, 2)
        let rendered = UsageHistorySnapshotRenderer.render(
            local: snapshot(), history: merged, descriptor: descriptor, now: now)
        XCTAssertTrue(rendered.lines.isEmpty)
        for tokens in [0, 1] {
            let activation = history(tokens: tokens)
            let activated = UsageHistoryAggregator.mergeHistories([first, second, activation], now: now)
            XCTAssertTrue(activated.hasRejectedNumericContributions)
            XCTAssertEqual(activated.series, merged.series)
        }
    }

    func testHiddenZeroTokenModelsDoNotConsumeTheRenderersVariantBudget() {
        var first = modelHistory(tokens: 0, variantTokens: Int.max)
        var second = modelHistory(tokens: 0, variantTokens: 1)
        first.modelUsage?.daily[0].models[0].costUSD = nil
        second.modelUsage?.daily[0].models[0].costUSD = nil
        second.modelUsage?.daily[0].date = "2026-11-22"
        second.series.daily[0].date = "2026-11-22"
        let merged = UsageHistoryAggregator.mergeHistories([first, second], now: now)

        XCTAssertFalse(merged.hasRejectedNumericContributions)
        XCTAssertEqual(merged.series.daily.count, 2)
        _ = UsageHistorySnapshotRenderer.render(local: snapshot(), history: merged, descriptor: descriptor, now: now)
    }

    func testDeviceOrderingKeepsAcceptedContributionsStable() throws {
        let first = document("a", tokens: 10)
        let oversized = document("b", tokens: Int.max)
        let last = document("c", tokens: 7)
        for documents in [[first, oversized, last], [last, oversized, first], [oversized, first, last]] {
            let merged = UsageHistoryAggregator.merged(
                localSnapshots: [:], peerDocuments: documents, descriptors: ["codex": descriptor], now: now)
            XCTAssertEqual(merged["codex"]?.series.daily.first?.totalTokens, 17)
            XCTAssertTrue(merged["codex"]?.hasRejectedNumericContributions == true)
        }
    }

    func testRowsOutsideTheWindowDoNotConsumeAnyTokenBudget() throws {
        var mixed = history(tokens: 10)
        mixed.series.daily += [
            .init(date: "2026-10-01", totalTokens: Int.max, costUSD: 9),
            .init(date: "2026-11-24", totalTokens: Int.max, costUSD: 9)
        ]
        mixed.modelUsage = ModelUsageSeries(daily: [
            .init(date: "2026-10-01", models: [.init(model: "old", totalTokens: Int.max, costUSD: 9)]),
            .init(date: "2026-11-24", models: [.init(model: "future", totalTokens: Int.max, costUSD: 9)])
        ])
        mixed.unknownModelsByDay = ["2026-10-01": ["old"], "2026-11-24": ["future"]]
        try document("mixed", history: mixed).validate()

        let merged = UsageHistoryAggregator.mergeHistories([mixed], now: now)

        XCTAssertEqual(merged.series.daily, history(tokens: 10).series.daily)
        XCTAssertNil(merged.modelUsage)
        XCTAssertTrue(merged.unknownModelsByDay.isEmpty)
        XCTAssertFalse(merged.hasRejectedNumericContributions)
    }

    func testAnExactMaximumAndZeroCostOnlyContributionRemainRenderable() throws {
        var maximum = history(tokens: Int.max)
        maximum.modelUsage = modelHistory(tokens: Int.max, variantTokens: Int.max).modelUsage
        var costOnly = history(tokens: 0)
        costOnly.modelUsage = modelHistory(tokens: 0, variantTokens: 0).modelUsage
        let merged = UsageHistoryAggregator.mergeHistories([maximum, costOnly], now: now)

        XCTAssertEqual(merged.series.daily.first?.totalTokens, Int.max)
        XCTAssertEqual(merged.series.daily.first?.costUSD, 2)
        XCTAssertFalse(merged.hasRejectedNumericContributions)
        let rendered = UsageHistorySnapshotRenderer.render(
            local: snapshot(), history: merged, descriptor: descriptor, now: now)
        XCTAssertNotNil(rendered.line(label: "Last 30 Days"))
        XCTAssertNil(rendered.warning)
    }

    func testRejectedProviderDoesNotDiscardOtherProvidersAndWarningsStayRuntimeOnly() throws {
        let good = history(tokens: 10)
        let bad = history(tokens: Int.max)
        let local = ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [], usageHistory: good)
        let peer = UsageHistoryDocument(
            deviceID: "peer", deviceName: "Peer", updatedAt: now, providers: ["codex": bad, "grok": good, "cursor": bad]
        )
        try peer.validate()
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: ["codex": local], peerDocuments: [peer],
            descriptors: [
                "codex": descriptor, "grok": descriptor,
                "cursor": .init(scope: .accountWide, estimatedCost: false, sourceNote: "server")
            ], now: now)
        let rejected = try XCTUnwrap(merged["codex"])
        XCTAssertTrue(rejected.hasRejectedNumericContributions)
        XCTAssertEqual(merged["grok"]?.series.daily, good.series.daily)
        XCTAssertFalse(merged["grok"]?.hasRejectedNumericContributions == true)
        XCTAssertNil(merged["cursor"])

        let encoded = try JSONEncoder().encode(rejected)
        let decoded = try JSONDecoder().decode(ProviderUsageHistory.self, from: encoded)
        XCTAssertFalse(decoded.hasRejectedNumericContributions)
        XCTAssertEqual(decoded.series, rejected.series)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["hasRejectedNumericContributions"])
    }

    func testHistoryWarningKeepsLocalQuotaAndExistingFailure() {
        var local = snapshot()
        local.plan = "Pro"
        local.warning = "Local warning"
        local.warningPresentation = [.init("Local warning")]
        local.reportedPartialFailure = .storage
        local.liveQuotaObservedAt = now
        local.lines = [.progress(label: "Session", used: 25, limit: 100, format: .percent)]
        var rejected = history(tokens: 10)
        rejected.hasRejectedNumericContributions = true

        var rendered = UsageHistorySnapshotRenderer.render(
            local: local, history: rejected, descriptor: descriptor, now: now)
        UsageHistorySnapshotRenderer.addInvalidHistoryWarning(to: &rendered)

        XCTAssertEqual(rendered.plan, local.plan)
        XCTAssertEqual(rendered.liveQuotaObservedAt, local.liveQuotaObservedAt)
        XCTAssertEqual(rendered.line(label: "Session"), local.line(label: "Session"))
        XCTAssertEqual(rendered.reportedPartialFailure, .storage)
        XCTAssertEqual(rendered.warningPresentation?.count, 2)
        XCTAssertTrue(rendered.warning?.contains("Local warning") == true)
    }

    func testHistoryWarningKeepsRawWarningsWithoutPresentation() {
        var local = snapshot()
        local.warning = "Local warning"
        local.warningPresentation = nil

        UsageHistorySnapshotRenderer.addInvalidHistoryWarning(to: &local)

        XCTAssertTrue(local.localizedWarning?.contains("Local warning") == true)
        XCTAssertEqual(local.warningPresentation?.count, 2)
        let expected = local.warning
        UsageHistorySnapshotRenderer.addInvalidHistoryWarning(to: &local)
        XCTAssertEqual(local.warning, expected)

        var duplicate = snapshot()
        duplicate.warning = UsageHistoryDocumentError.invalidValue.localizedDescription
        duplicate.warningPresentation = nil
        UsageHistorySnapshotRenderer.addInvalidHistoryWarning(to: &duplicate)
        XCTAssertEqual(duplicate.warning, UsageHistoryDocumentError.invalidValue.localizedDescription)
        XCTAssertEqual(duplicate.warningPresentation?.count, 1)
    }

    func testHistoryWarningKeepsDerivedRateLimitFailure() {
        var local = snapshot()
        local.usageRetryAfter = now.addingTimeInterval(60)
        XCTAssertNil(local.reportedPartialFailure)
        XCTAssertEqual(local.partialRefreshErrorCategory, .rateLimited)

        UsageHistorySnapshotRenderer.addInvalidHistoryWarning(to: &local)

        XCTAssertEqual(local.partialRefreshErrorCategory, .rateLimited)
        XCTAssertEqual(local.reportedPartialFailure, .rateLimited)
    }

    @MainActor
    func testRejectedRemoteOnlyHistoryStillWarnsOnTheEnabledFamily() throws {
        let suite = "EgasuTests.HistoryBounds." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = CodexProvider.makeProvider()
        let registry = WidgetRegistry(
            providers: [provider],
            descriptors: [
                WidgetDescriptor.usageTrend(provider: provider)
                    .exportingHistory(scope: .machineLocal, estimatedCost: true, sourceNote: "test")
            ])
        let store = WidgetDataStore(
            registry: registry, providers: [], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { self.now }, providerIdentityKeys: ["codex": "local-account"])
        let oversized = ProviderUsageHistory(
            series: DailyUsageSeries(daily: [
                .init(date: day, totalTokens: Int.max, costUSD: 5),
                .init(date: "2026-11-22", totalTokens: 1, costUSD: 7)
            ]))
        let peer = UsageHistoryDocument(
            deviceID: "peer", deviceName: "Peer", updatedAt: now,
            providers: ["codex@deadbeef": oversized], identities: ["codex@deadbeef": "other-account"])
        try peer.validate()

        store.setPeerHistoryDocuments([peer], ownDeviceID: "local")

        XCTAssertEqual(store.snapshots["codex"]?.warning, UsageHistoryDocumentError.invalidValue.localizedDescription)
        XCTAssertNil(store.snapshots["codex"]?.line(label: "Today"))
        store.clearPeerHistoryDocuments()
        XCTAssertNil(store.snapshots["codex"])
    }

    private func history(tokens: Int) -> ProviderUsageHistory {
        ProviderUsageHistory(series: DailyUsageSeries(daily: [.init(date: day, totalTokens: tokens, costUSD: 1)]))
    }

    private func modelHistory(tokens: Int, variantTokens: Int?, name: String = "Model") -> ProviderUsageHistory {
        ProviderUsageHistory(
            series: DailyUsageSeries(daily: [.init(date: day, totalTokens: 1, costUSD: 1)]),
            modelUsage: ModelUsageSeries(daily: [
                .init(
                    date: day,
                    models: [
                        .init(
                            model: name, totalTokens: tokens, costUSD: 1,
                            variants: variantTokens.map { [.init(model: "Model", totalTokens: $0, costUSD: 1)] })
                    ])
            ]))
    }

    private func snapshot() -> ProviderSnapshot {
        ProviderSnapshot(providerID: "codex", displayName: "Codex", lines: [])
    }

    private func document(_ id: String, history: ProviderUsageHistory) -> UsageHistoryDocument {
        UsageHistoryDocument(deviceID: id, deviceName: id, updatedAt: now, providers: ["codex": history])
    }

    private func document(_ id: String, tokens: Int) -> UsageHistoryDocument {
        document(id, history: history(tokens: tokens))
    }
}
