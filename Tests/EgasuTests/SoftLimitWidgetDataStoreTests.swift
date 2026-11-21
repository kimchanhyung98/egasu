import Observation
import os
import XCTest
@testable import Egasu

@MainActor
final class SoftLimitWidgetDataStoreTests: XCTestCase {
    func testEstimatedOpenCodeWeeklyUsageShowsOnlyTheGuideEvenAboveThreshold() async throws {
        let provider = OpenCodeProvider()
        let weekly = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "opencode.weekly" })
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        let now = Date()
        let snapshot = ProviderSnapshot.make(
            provider: provider.provider, plan: "Go",
            lines: [
                .progress(label: "Weekly", used: 29, limit: 30, format: .dollars, periodDurationMs: MetricPeriod.weekMs)
            ],
            refreshedAt: now, liveQuotaObservedAt: now
        )
        let runtime = TestProviderRuntime(provider: provider.provider, descriptors: [weekly], snapshot: snapshot)
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { now }, softLimitSettings: { settings }
        )
        await store.refreshAll(force: true)
        let data = store.data(for: weekly)
        XCTAssertEqual(data.softLimitMarkerFraction, 0.9)
        XCTAssertNil(data.softLimitReachedUntil)
        XCTAssertEqual(data.softLimitStatusText, L10n.errors("Soft limit at %@%% used", "90"))
    }

    func testQuotaKeepsGuideWhenReadingExpiresResetsOrRefreshFails() async throws {
        let provider = CodexProvider()
        let weekly = try XCTUnwrap(provider.widgetDescriptors.first { $0.id == "codex.weekly" })
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ttl = RefreshSetting.interval(for: provider.provider.id)
        let guide = L10n.errors("Soft limit at %@%% used", "90")
        let reached = L10n.errors("Soft limit reached at %@%% used", "90")
        for reset: Date? in [now.addingTimeInterval(15), nil] {
            let defaults = makeDefaults()
            let cache = ProviderSnapshotCache(userDefaults: defaults, now: { now })
            let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
            settings.enabled = true
            let snapshot = ProviderSnapshot.make(
                provider: provider.provider, plan: nil,
                lines: [
                    .progress(
                        label: "Weekly", used: 96, limit: 100, format: .percent, resetsAt: reset,
                        periodDurationMs: MetricPeriod.weekMs)
                ],
                refreshedAt: now, liveQuotaObservedAt: now
            )
            cache.store(snapshot)
            let runtime = TogglingProviderRuntime(
                provider: provider.provider, descriptors: [weekly], first: snapshot,
                second: .error(provider: provider.provider, message: "Refresh failed")
            )
            let store = WidgetDataStore(
                registry: .from([runtime]), providers: [runtime], cache: cache, defaults: defaults, now: { now },
                softLimitSettings: { settings }
            )
            XCTAssertEqual(store.data(for: weekly).softLimitStatusText, guide)
            await store.refreshAll(force: true)
            let live = store.data(for: weekly)
            let expiry = reset ?? now.addingTimeInterval(ttl)
            XCTAssertEqual(live.softLimitReachedUntil, expiry)
            XCTAssertEqual(live.presented(at: expiry.addingTimeInterval(-1)).softLimitStatusText, reached)
            let expired = live.presented(at: expiry)
            XCTAssertEqual(expired.softLimitStatusText, guide)
            XCTAssertEqual(expired.softLimitMarkerFraction, live.softLimitMarkerFraction)
            await store.refreshAll(force: true)
            let failed = store.data(for: weekly)
            XCTAssertEqual(failed.used, 96)
            XCTAssertEqual(failed.softLimitMarkerFraction, live.softLimitMarkerFraction)
            XCTAssertEqual(failed.softLimitStatusText, guide)
        }
    }

    func testDataUsesCurrentEnabledWindowWithoutAnotherRefresh() async {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("codex"))
        let monthly =
            WidgetDescriptor
            .percent(id: "fixture.monthly", provider: provider, title: "Monthly")
            .supportingSoftLimit(.monthly)
        let weekly = WidgetDescriptor
            .percent(id: "fixture.weekly", provider: provider, title: "Weekly")
            .supportingSoftLimit(.weekly)
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .progress(
                    label: "Monthly", used: 40, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.monthMs
                ),
                .progress(
                    label: "Weekly", used: 50, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.weekMs
                )
            ]
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [monthly, weekly],
            snapshot: snapshot
        )
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        settings.thresholdPercent = 93
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [monthly, weekly]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            softLimitSettings: { settings }
        )

        await store.refreshAll(force: true)
        XCTAssertEqual(store.data(for: monthly).softLimitUsedFraction, 0.93)
        XCTAssertEqual(store.data(for: weekly).softLimitUsedFraction, 0.93)

        let invalidated = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.data(for: weekly).softLimitUsedFraction
        } onChange: {
            invalidated.withLock { $0 = true }
        }
        settings.thresholdPercent = 92
        XCTAssertTrue(invalidated.withLock { $0 })
        XCTAssertEqual(store.data(for: weekly).softLimitUsedFraction ?? -1, 0.92, accuracy: 0.0001)

        settings.window = .monthly
        settings.thresholdPercent = 90
        XCTAssertEqual(store.data(for: monthly).softLimitUsedFraction ?? -1, 0.90, accuracy: 0.0001)
        XCTAssertNil(store.data(for: weekly).softLimitUsedFraction)

        let guideChanged = OSAllocatedUnfairLock(initialState: false)
        withObservationTracking {
            _ = store.data(for: monthly).softLimitUsedFraction
        } onChange: {
            guideChanged.withLock { $0 = true }
        }
        settings.setLabsAvailable(false)
        XCTAssertTrue(guideChanged.withLock { $0 })
        XCTAssertNil(store.data(for: monthly).softLimitUsedFraction)
        settings.setLabsAvailable(true)
        XCTAssertNil(store.data(for: monthly).softLimitUsedFraction)
    }

    func testDataRequiresResolvedWindowDurationToMatchDescriptorOptIn() async {
        let provider = Provider(id: "fixture", displayName: "Fixture", icon: .providerMark("codex"))
        let exact = WidgetDescriptor
            .percent(id: "fixture.exact", provider: provider, title: "Exact")
            .supportingSoftLimit(.monthly)
        let dynamic = WidgetDescriptor
            .percent(id: "fixture.dynamic", provider: provider, title: "Dynamic")
            .supportingSoftLimit(.monthly)
        let snapshot = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .progress(
                    label: "Exact", used: 40, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.monthMs
                ),
                .progress(
                    label: "Dynamic", used: 50, limit: 100, format: .percent,
                    periodDurationMs: 3 * 60 * 60 * 1000
                )
            ]
        )
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [exact, dynamic],
            snapshot: snapshot
        )
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        settings.window = .monthly
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [exact, dynamic]),
            providers: [runtime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults,
            softLimitSettings: { settings }
        )

        await store.refreshAll(force: true)

        XCTAssertEqual(store.data(for: exact).softLimitUsedFraction ?? -1, 0.90, accuracy: 0.0001)
        XCTAssertNil(store.data(for: dynamic).softLimitUsedFraction)
    }

    func testSoftLimitAndResetWatchKeepIndependentMarkersAndPresentation() async throws {
        let provider = CodexProvider()
        let descriptors = provider.widgetDescriptors
        let weekly = try XCTUnwrap(descriptors.first { $0.id == "codex.weekly" })
        let forecast = try XCTUnwrap(descriptors.first { $0.id == "codex.resetWatch" })
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        settings.thresholdPercent = 95
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let deadline = now.addingTimeInterval(300)
        let snapshot = ProviderSnapshot(
            providerID: "codex", displayName: "Codex",
            lines: [.progress(label: weekly.metricLabel, used: 95, limit: 100, format: .percent,
                    periodDurationMs: MetricPeriod.weekMs)
            ],
            refreshedAt: now, liveQuotaObservedAt: now
        )
        let runtime = TestProviderRuntime(provider: provider.provider, descriptors: descriptors, snapshot: snapshot)
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { now }, softLimitSettings: { settings }
        )
        await store.refreshAll(force: true)
        store.setCodexResetWatch(
            CodexResetWatch(
                chancePercent: 75, deadline: deadline, communityYesPercent: 79
            ))

        for mode in [WidgetDisplayMode.used, .remaining] {
            store.meterStyle = mode
            let quota = store.data(for: weekly)
            let watch = store.data(for: forecast)
            XCTAssertEqual(quota.softLimitMarkerFraction ?? -1, mode == .used ? 0.95 : 0.05, accuracy: 0.0001)
            XCTAssertEqual(quota.softLimitStatusText, "Soft limit reached at 95% used")
            XCTAssertNil(quota.communityVoteTick)
            XCTAssertNil(watch.softLimitUsedFraction)
            XCTAssertNil(watch.softLimitMarkerFraction)
            XCTAssertNil(watch.softLimitStatusText)
            XCTAssertEqual(watch.fraction, 0.75)
            XCTAssertEqual(watch.communityVoteTick, 0.79)
            XCTAssertEqual(watch.communityVoteLabel, "79% expect a reset")
            XCTAssertFalse(watch.hasMeterStyleToggle)
            XCTAssertTrue(watch.presented(at: deadline).hasData)
            XCTAssertEqual(watch.presented(at: deadline).boundedHeadline, "0% chance")
            XCTAssertNil(watch.presented(at: deadline).communityVoteTick)
            XCTAssertTrue(quota.presented(at: deadline).hasData)
        }
    }

    func testAccountCardsKeepIndependentUsageAndShareOnlyTheGuideAndForecast() async throws {
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        settings.thresholdPercent = 95
        let cards = [
            AccountUsageSnapshotCard(id: "claude@profile-review", profileID: "review-claude", family: "claude"),
            AccountUsageSnapshotCard(id: "codex@profile-review", profileID: "review-codex", family: "codex")
        ]
        let runtimes = ProviderCatalog.make(defaults: defaults, snapshotCards: cards)
        let registry = WidgetRegistry.from(runtimes)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = ["claude": 40.0, cards[0].id: 95.0, "codex": 70.0, cards[1].id: 98.0]
        let fixtures = try usage.map { id, used in
            let provider = try XCTUnwrap(registry.provider(id: id))
            let snapshot = ProviderSnapshot(
                providerID: id, displayName: provider.displayName,
                lines: [
                    .progress(
                        label: "Weekly", used: used, limit: 100, format: .percent,
                        periodDurationMs: MetricPeriod.weekMs)
                ],
                refreshedAt: now, liveQuotaObservedAt: now
            )
            return TestProviderRuntime(
                provider: provider, descriptors: registry.descriptors(for: id), snapshot: snapshot)
        }
        let store = WidgetDataStore(
            registry: .from(fixtures), providers: fixtures, cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { now }, softLimitSettings: { settings }
        )
        await store.refreshAll(force: true)
        store.setCodexResetWatch(
            CodexResetWatch(
                chancePercent: 45, deadline: now.addingTimeInterval(300), communityYesPercent: 79
            ))

        for (id, used) in usage {
            let descriptor = try XCTUnwrap(registry.descriptor(id: "\(id).weekly"))
            XCTAssertEqual(descriptor.softLimitWindows, [.weekly])
            let data = store.data(for: descriptor)
            XCTAssertEqual(data.providerID, id)
            XCTAssertEqual(data.used, used)
            XCTAssertEqual(data.softLimitUsedFraction, 0.95)
            XCTAssertEqual(
                data.softLimitStatusText,
                used >= 95
                    ? "Soft limit reached at 95% used" : "Soft limit at 95% used")
        }
        for id in ["codex", cards[1].id] {
            let watch = store.data(for: try XCTUnwrap(registry.descriptor(id: "\(id).resetWatch")))
            XCTAssertEqual(watch.providerID, id)
            XCTAssertEqual(watch.used, 45)
            XCTAssertEqual(watch.communityVoteTick, 0.79)
            XCTAssertNil(watch.softLimitMarkerFraction)
        }
        settings.enabled = false
        for (id, used) in usage {
            let data = store.data(for: try XCTUnwrap(registry.descriptor(id: "\(id).weekly")))
            XCTAssertEqual(data.used, used)
            XCTAssertNil(data.softLimitMarkerFraction)
        }
    }

    func testGuideChangesLeaveQuotaStateNotificationsAndLimitsAPIUnchanged() async throws {
        let provider = CodexProvider()
        let registry = WidgetRegistry.from([provider])
        let weekly = try XCTUnwrap(registry.descriptor(id: "codex.weekly"))
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        let notifications = NotificationSettingsStore(defaults: defaults)
        notifications.critical = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var posts: [String] = []
        let store = WidgetDataStore(
            registry: registry, providers: [], defaults: defaults, now: { now },
            notificationSettings: { notifications }, softLimitSettings: { settings },
            postNotification: { id, _, _, _, isCurrent in
                guard isCurrent() else { return false }
                posts.append(id)
                return true
            }
        )
        var reset = now.addingTimeInterval(600)
        func setUsage(_ used: Double) {
            store.snapshots["codex"] = ProviderSnapshot(
                providerID: "codex", displayName: "Codex",
                lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent,
                                  resetsAt: reset, periodDurationMs: MetricPeriod.weekMs)],
                refreshedAt: now
            )
        }
        func limits() -> Data {
            LocalLimitsAPI.encode(providerIDs: ["codex"], state: .init(
                enabledOrderedIDs: ["codex"], knownIDs: ["codex"], snapshots: store.snapshots,
                limitDescriptors: store.limitDescriptorsByProvider, generatedAt: now
            ))
        }
        setUsage(89)
        await store.evaluateNotifications(now: now)
        let baseline = store.data(for: weekly)
        let baselineLimits = limits()

        for threshold in SoftLimitSettingsStore.thresholdRange {
            settings.enabled = true
            settings.thresholdPercent = threshold
            for mode in [WidgetDisplayMode.used, .remaining] {
                store.meterStyle = mode
                let data = store.data(for: weekly)
                XCTAssertNotNil(data.softLimitMarkerFraction)
                XCTAssertEqual(data.used, baseline.used)
                XCTAssertEqual(data.limit, baseline.limit)
                XCTAssertEqual(data.resetsAt, baseline.resetsAt)
                XCTAssertEqual(data.remainingFraction, baseline.remainingFraction)
                XCTAssertEqual(data.meterState(now: now), baseline.meterState(now: now))
                XCTAssertEqual(limits(), baselineLimits)
                await store.evaluateNotifications(now: now)
                XCTAssertTrue(posts.isEmpty)
            }
        }

        setUsage(91)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["codex.underTenPercent"])
        settings.enabled = false
        await store.evaluateNotifications(now: now)
        settings.enabled = true
        settings.window = .monthly
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["codex.underTenPercent"])
        XCTAssertNil(store.data(for: weekly).softLimitMarkerFraction)
        reset = reset.addingTimeInterval(7 * 24 * 60 * 60)
        setUsage(89)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts.count, 1)
        setUsage(91)
        await store.evaluateNotifications(now: now)
        XCTAssertEqual(posts, ["codex.underTenPercent", "codex.underTenPercent"])

    }

    func testAccountCardsKeepGuidesSeparateFromSharedHomeResetWatch() throws {
        let defaults = makeDefaults()
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        let cardIDs = ["claude", "claude@profile-work", "codex", "codex@profile-work"]
        let providers = cardIDs.map { id in
            ProviderAccountID.family(of: id) == "claude"
                ? ClaudeProvider.makeProvider(id: id) : CodexProvider.makeProvider(id: id)
        }
        let descriptors = providers.flatMap { provider in
            ProviderAccountID.family(of: provider.id) == "claude"
                ? ClaudeProvider(provider: provider).widgetDescriptors
                : CodexProvider(provider: provider).widgetDescriptors
        }
        let registry = WidgetRegistry(providers: providers, descriptors: descriptors)
        let metricIDs = ["claude.weekly", "codex.weekly", "codex.resetWatch"]
        let layout = LayoutStore(
            registry: registry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: metricIDs, migrationBaselineMetricIDs: metricIDs,
            defaultPinnedMetricIDs: ["codex.weekly"]
        )
        let store = WidgetDataStore(registry: registry, providers: [], defaults: defaults, softLimitSettings: { settings })
        let usage = ["claude": 30.0, "claude@profile-work": 40, "codex": 90, "codex@profile-work": 95]
        for (id, used) in usage {
            store.snapshots[id] = .init(providerID: id, displayName: id, lines: [
                .progress(label: "Weekly", used: used, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs)
            ])
        }
        store.setCodexResetWatch(.init(chancePercent: 75, deadline: .distantFuture, communityYesPercent: 60))
        layout.setMetric("codex.weekly", pinned: true)
        let originalPlaced = layout.placed
        let originalPins = layout.priorityPinIDs

        let groups = layout.displayGroups
        XCTAssertEqual(groups.map(\.id).sorted(), cardIDs.sorted())
        for group in groups {
            // 추가 계정 카드는 공유 홈 전용 행(Reset Watch 등)을 숨김 — 대시보드 계정 섹션과 같은 규칙.
            let widgets = group.widgets.filter { !AppContainer.hidesMetric($0.descriptorID, onCard: group.id) }
            for display in [WidgetDisplayMode.used, .remaining] {
                store.meterStyle = display
                let rows = try widgets.map { store.data(for: try XCTUnwrap(layout.descriptor(for: $0))) }
                let quota = try XCTUnwrap(rows.first { $0.title == "Weekly" })
                XCTAssertEqual(quota.used, usage[group.id])
                XCTAssertEqual(quota.softLimitMarkerFraction ?? -1, display == .used ? 0.90 : 0.10, accuracy: 0.0001)
                XCTAssertEqual(rows.filter(\.isForecast).count, group.id == "codex" ? 1 : 0)
                XCTAssertTrue(rows.filter(\.isForecast).allSatisfy { $0.softLimitMarkerFraction == nil })
            }
        }
        XCTAssertEqual(layout.placed, originalPlaced)
        XCTAssertEqual(layout.priorityPinIDs, originalPins)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "EgasuTests.SoftLimit.WidgetDataStore.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }
}
