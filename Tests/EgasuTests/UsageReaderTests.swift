import XCTest
@testable import Egasu

@MainActor
final class UsageReaderTests: XCTestCase {
    private final class StubProvider: ProviderRuntime {
        let provider: Provider
        var widgetDescriptors: [WidgetDescriptor] {
            descriptorsOverride ?? [
                .percent(id: "\(provider.id).weekly", provider: provider, title: "Weekly")
                    .exportingLimit("weekly", unit: "percent", estimated: estimated)
                    .supportingSoftLimit(.weekly, acceptsMissingDuration: true)
            ]
        }
        var descriptorsOverride: [WidgetDescriptor]?
        var refreshCount = 0
        var refreshError: String?
        var refreshedAt = Date()
        var observedAt: Date?
        var used = 20.0
        var estimated = false
        var onRefresh: (() -> Void)?
        var incompleteQuotaWindows: Set<SoftLimitWindow>?

        init(id: String = "stub") {
            self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        }

        func hasLocalCredentials() async -> Bool { true }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            onRefresh?()
            if let refreshError {
                return .error(provider: provider, message: refreshError)
            }
            var snapshot = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [.progress(label: "Weekly", used: used, limit: 100, format: .percent)],
                refreshedAt: refreshedAt, liveQuotaObservedAt: observedAt
            )
            snapshot.incompleteQuotaWindows = incompleteQuotaWindows
            return snapshot
        }
    }

    private func defaults() -> UserDefaults {
        let suite = "UsageReaderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func enableSoftLimit(_ defaults: UserDefaults) {
        defaults.set(true, forKey: UpdaterController.betaChannelDefaultsKey)
        SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).enabled = true
    }

    func testPreflightComparesTerminalHomeAgainstTheBoundQuotaHome() {
        let home = URL(fileURLWithPath: "/fixture/user", isDirectory: true)
        XCTAssertTrue(
            UsageReader.matchesTerminalHome(
                boundHome: "/fixture/user/.codex", defaultDirectory: ".codex", override: nil, homeDirectory: home))
        XCTAssertFalse(
            UsageReader.matchesTerminalHome(
                boundHome: "/fixture/user/.config/codex", defaultDirectory: ".codex", override: nil, homeDirectory: home
            ))
        XCTAssertTrue(
            UsageReader.matchesTerminalHome(
                boundHome: "/fixture/user/.config/codex", defaultDirectory: ".codex", override: "~/.config/codex",
                homeDirectory: home))
        XCTAssertFalse(
            UsageReader.matchesTerminalHome(
                boundHome: "/fixture/user/.claude", defaultDirectory: ".claude", override: "/fixture/other",
                homeDirectory: home))
    }

    func testClaudePreflightDistinguishesKeychainScopesAtTheSameHome() {
        let explicit = FakeEnvironment(["CLAUDE_CONFIG_DIR": "~/.claude"])
        let canonical = FakeEnvironment(["CLAUDE_CONFIG_DIR": "/fixture/user/.claude"])
        let implicit = FakeEnvironment()
        XCTAssertTrue(
            UsageReader.matchesClaudeTerminalScope(terminal: explicit, usage: explicit, pinsSharedHome: false))
        XCTAssertFalse(
            UsageReader.matchesClaudeTerminalScope(terminal: explicit, usage: canonical, pinsSharedHome: false))
        XCTAssertFalse(
            UsageReader.matchesClaudeTerminalScope(terminal: implicit, usage: explicit, pinsSharedHome: false))
        XCTAssertFalse(
            UsageReader.matchesClaudeTerminalScope(terminal: explicit, usage: explicit, pinsSharedHome: true))
        XCTAssertTrue(
            UsageReader.matchesClaudeTerminalScope(terminal: implicit, usage: explicit, pinsSharedHome: true))
        let staging = FakeEnvironment(["USER_TYPE": "ant", "USE_STAGING_OAUTH": "1"])
        XCTAssertFalse(
            UsageReader.matchesClaudeTerminalScope(terminal: implicit, usage: staging, pinsSharedHome: false))
    }

    func testPreflightChecksOnlyRequestedActiveCardAndUsesLatestThreshold() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let base = StubProvider(id: "team")
        let other = StubProvider(id: "team@other")
        base.observedAt = Date()
        base.used = 75
        base.onRefresh = { SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).thresholdPercent = 75 }
        let reader = UsageReader(userDefaults: defaults, providers: [base, other])
        let result = try await reader.checkSoftLimit(cardID: "team")
        XCTAssertEqual(result, .reached)
        XCTAssertEqual(base.refreshCount, 1)
        XCTAssertEqual(other.refreshCount, 0)
    }

    func testDisabledUnknownAndUnsupportedChecksDoNotRefresh() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        let disabled = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(disabled, .disabled)
        enableSoftLimit(defaults)
        ProviderEnablementStore(defaults: defaults).setEnabled(false, for: "stub")
        let unavailable = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(unavailable, .unknown)
        do {
            _ = try await reader.checkSoftLimit(cardID: "stub@missing")
            XCTFail("Expected an unknown card error")
        } catch UsageReaderError.unknownProvider(let id) {
            XCTAssertEqual(id, "stub@missing")
        }
        ProviderEnablementStore(defaults: defaults).setEnabled(true, for: "stub")
        SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).window = .monthly
        let unsupported = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(unsupported, .unknown)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testPreflightChecksOpenCodeForLiveUsageAndIgnoresMissingMeasurements() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let openCode = StubProvider(id: "opencode")
        openCode.descriptorsOverride = OpenCodeProvider().widgetDescriptors
        let mixed = StubProvider()
        mixed.descriptorsOverride =
            [
                .percent(id: "stub.estimatedWeekly", provider: mixed.provider, title: "Estimated Weekly")
                    .exportingLimit("estimatedWeekly", unit: "percent", estimated: true)
                    .supportingSoftLimit(.weekly, acceptsMissingDuration: true)
            ] + mixed.widgetDescriptors
        mixed.observedAt = Date()
        mixed.used = 95
        let reader = UsageReader(userDefaults: defaults, providers: [openCode, mixed])

        let ignored = try await reader.checkSoftLimit(cardID: "opencode")
        let reached = try await reader.checkSoftLimit(cardID: "stub")

        XCTAssertEqual(ignored, .unknown)
        XCTAssertEqual(openCode.refreshCount, 1)
        XCTAssertEqual(reached, .reached)
        XCTAssertEqual(mixed.refreshCount, 1)
    }

    func testPreflightFileLogDistinguishesDisabledProviderAndUnresolvedIdentity() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sink = LogFile(directory: directory, fileName: "egasu.log")
        let original = AppLog.sink
        AppLog.sink = sink
        AppLog.reloadLevel(.info)
        defer {
            AppLog.sink = original
            AppLog.reloadLevel()
            try? FileManager.default.removeItem(at: directory)
        }
        let provider = StubProvider(id: "codex")
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        ProviderEnablementStore(defaults: defaults).setEnabled(false, for: "codex")
        _ = try await reader.checkSoftLimit(cardID: "codex")
        ProviderEnablementStore(defaults: defaults).setEnabled(true, for: "codex")
        _ = try await reader.checkSoftLimit(cardID: "codex")
        let logs = try String(contentsOf: sink.fileURL, encoding: .utf8)
        let decisions = logs.components(separatedBy: .newlines).filter { $0.contains("Soft Limit preflight:") }
        XCTAssertEqual(decisions.count, 2)
        XCTAssertEqual(decisions.first?.hasSuffix("provider=codex status=unknown reason=provider_disabled"), true)
        XCTAssertEqual(decisions.last?.hasSuffix("provider=codex status=unknown reason=identity_unresolved"), true)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testAccountScopedPreflightUsesMatchedCacheAndRejectsUnresolvedLogin() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider(id: "codex")
        provider.observedAt = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.store(await provider.refresh(), producedByIdentityKey: "current")
        provider.refreshCount = 0
        let reader = UsageReader(userDefaults: defaults, providers: [provider], identityKeys: { ["codex": "current"] })
        let valid = try await reader.checkSoftLimit(cardID: "codex")
        XCTAssertEqual(valid, .belowLimit)
        cache.invalidateLiveQuota(providerID: "codex", identity: "current")
        let invalidated = try await reader.checkSoftLimit(cardID: "codex")
        XCTAssertEqual(invalidated, .unknown)
        let unresolved = try await UsageReader(userDefaults: defaults, providers: [provider]).checkSoftLimit(
            cardID: "codex")
        XCTAssertEqual(unresolved, .unknown)
        XCTAssertEqual(provider.refreshCount, 1)

        let changed = UsageReader(
            userDefaults: defaults, providers: [provider], identityKeys: { ["codex": "new-login"] })
        provider.refreshError = "Unable to authenticate"
        let failed = try await changed.checkSoftLimit(cardID: "codex")
        XCTAssertEqual(failed, .unknown)
        XCTAssertEqual(provider.refreshCount, 2)
    }

    func testPreflightRecognizesSharedInvalidationDuringRefresh() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider(id: "codex")
        let observedAt = Date().addingTimeInterval(-1)
        let cache = ProviderSnapshotCache(userDefaults: defaults, now: { observedAt.addingTimeInterval(1) })
        provider.observedAt = observedAt
        provider.used = 95
        provider.onRefresh = { cache.invalidateLiveQuota(providerID: "codex", identity: "current") }
        let reader = UsageReader(userDefaults: defaults, providers: [provider], identityKeys: { ["codex": "current"] })

        let result = try await reader.checkSoftLimit(cardID: "codex")

        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertTrue(cache.isQuotaInvalidated(providerID: "codex", observedAt: observedAt))
    }

    func testPreflightRefreshesFreshDisplayCacheWithoutLiveQuotaForManagedProviders() async throws {
        for id in ["codex", "claude"] {
            let defaults = defaults()
            enableSoftLimit(defaults)
            let provider = StubProvider(id: id)
            let cache = ProviderSnapshotCache(userDefaults: defaults)
            cache.store(await provider.refresh(), producedByIdentityKey: "current")
            provider.refreshCount = 0
            provider.observedAt = Date()
            provider.used = 95
            let reader = UsageReader(userDefaults: defaults, providers: [provider], identityKeys: { [id: "current"] })

            let result = try await reader.checkSoftLimit(cardID: id)

            XCTAssertEqual(result, .reached, id)
            XCTAssertEqual(provider.refreshCount, 1, id)
            XCTAssertNil(cache.snapshot(providerID: id)?.liveQuotaObservedAt, id)
        }
    }

    func testKimiPreflightRechecksCurrentQuotaAndNeverReusesUnstampedCache() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider(id: "kimi")
        provider.observedAt = Date()
        provider.used = 95
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.store(await provider.refresh())
        provider.refreshCount = 0
        provider.used = 70
        let reader = UsageReader(userDefaults: defaults, providers: [provider])

        let below = try await reader.checkSoftLimit(cardID: "kimi")
        XCTAssertEqual(below, .belowLimit)
        provider.used = 90
        let reached = try await reader.checkSoftLimit(cardID: "kimi")
        XCTAssertEqual(reached, .reached)
        XCTAssertEqual(provider.refreshCount, 2)
    }

    func testPreflightRechecksIncompleteCachedQuotaBeforeReturningUnknown() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider(id: "codex")
        provider.observedAt = Date()
        provider.incompleteQuotaWindows = [.monthly]
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.store(await provider.refresh(), producedByIdentityKey: "current")
        provider.incompleteQuotaWindows = nil
        let reader = UsageReader(userDefaults: defaults, providers: [provider], identityKeys: { ["codex": "current"] })

        let result = try await reader.checkSoftLimit(cardID: "codex")

        XCTAssertEqual(result, .belowLimit)
        XCTAssertEqual(provider.refreshCount, 2)
    }

    func testPreflightDoesNotPublishAnotherAccountsQuotaDuringAccountSwitch() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider(id: "claude")
        provider.refreshedAt = Date().addingTimeInterval(-RefreshSetting.interval(for: "claude") - 1)
        provider.observedAt = provider.refreshedAt
        let original = await provider.refresh()
        ProviderSnapshotCache(userDefaults: defaults).store(original, producedByIdentityKey: "account-a")
        provider.refreshCount = 0
        provider.refreshedAt = Date()
        provider.observedAt = provider.refreshedAt
        var login = "account-a"
        provider.onRefresh = {
            login = "account-b"
            provider.used = 95
        }
        let reader = UsageReader(userDefaults: defaults, providers: [provider], identityKeys: { ["claude": login] })

        let switched = try await reader.checkSoftLimit(cardID: "claude")
        XCTAssertEqual(switched, .unknown)
        XCTAssertEqual(provider.refreshCount, 1)
        let appCache = ProviderSnapshotCache(userDefaults: defaults)
        XCTAssertEqual(appCache.producedByIdentityKey(providerID: "claude"), "account-a")
        XCTAssertEqual(appCache.loadSnapshots(providerIDs: ["claude"])["claude"]?.lines, original.lines)

        login = "account-a"
        provider.onRefresh = nil
        provider.used = 20
        let returned = try await reader.checkSoftLimit(cardID: "claude")
        XCTAssertEqual(returned, .belowLimit)
        XCTAssertEqual(provider.refreshCount, 2)
    }

    func testFailedPreflightDoesNotInvalidateSharedQuota() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider()
        let observedAt = Date().addingTimeInterval(-1)
        provider.observedAt = observedAt
        let appCache = ProviderSnapshotCache(userDefaults: defaults)
        appCache.store(await provider.refresh())
        provider.refreshCount = 0
        provider.refreshError = "Unavailable"
        let reader = UsageReader(userDefaults: defaults, providers: [provider])

        let preflight = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(preflight, .unknown)
        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertFalse(appCache.isQuotaInvalidated(providerID: "stub", observedAt: observedAt))

        _ = try await reader.read(providerID: "stub", force: true)
        XCTAssertEqual(provider.refreshCount, 2)
        XCTAssertTrue(appCache.isQuotaInvalidated(providerID: "stub", observedAt: observedAt))
    }

    func testUnstampedPreflightReadsCurrentLoginAndHonorsRetryAfter() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider()
        provider.observedAt = Date()
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.store(await provider.refresh())
        provider.used = 95
        provider.refreshCount = 0
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        let result = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(result, .reached)
        XCTAssertEqual(provider.refreshCount, 1)

        var waiting = await provider.refresh()
        waiting.liveQuotaObservedAt = nil
        waiting.usageRetryAfter = Date().addingTimeInterval(120)
        cache.store(waiting)
        provider.refreshCount = 0
        let backedOff = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(backedOff, .unknown)
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testEstimatedExpiredAndFailedPreflightsAreUnknown() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider()
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        provider.observedAt = Date()
        provider.estimated = true
        let estimate = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(estimate, .unknown)
        provider.estimated = false
        provider.observedAt = Date().addingTimeInterval(-RefreshSetting.interval - 5)
        let expired = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(expired, .unknown)
        provider.refreshError = "Unavailable"
        let error = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(error, .unknown)
    }

    func testPartialQuotaOnlyAllowsVerifiedPeriods() async throws {
        let defaults = defaults()
        enableSoftLimit(defaults)
        let provider = StubProvider()
        provider.observedAt = Date()
        provider.incompleteQuotaWindows = [.monthly]
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        let partial = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(partial, .unknown)

        provider.used = 95
        let reached = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(reached, .reached)

        provider.used = 20
        SoftLimitSettingsStore(defaults: defaults, labsAvailable: true).window = .weekly
        let weekly = try await reader.checkSoftLimit(cardID: "stub")
        XCTAssertEqual(weekly, .belowLimit)
    }

    func testReadsSharedSnapshotCacheWithoutRefreshing() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        ProviderSnapshotCache(userDefaults: defaults).store(await provider.refresh())
        provider.refreshCount = 0

        let result = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "stub")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        XCTAssertNotNil((object["providers"] as? [String: Any])?["stub"])
        XCTAssertEqual(provider.refreshCount, 0)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testOpenCodeReadRechecksCurrentLoginEvenWithinCacheTTL() async throws {
        let defaults = defaults()
        ProviderEnablementStore(defaults: defaults).setEnabled(true, for: "opencode")
        let provider = StubProvider(id: "opencode")
        let cache = ProviderSnapshotCache(userDefaults: defaults)
        cache.store(await provider.refresh())
        provider.used = 84
        let reader = UsageReader(userDefaults: defaults, providers: [provider])
        let result = try await reader.read(providerID: "opencode")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let cards = try XCTUnwrap(root["providers"] as? [String: [String: Any]])
        let resources = try XCTUnwrap(cards["opencode"]?["resources"] as? [String: [String: Any]])
        XCTAssertEqual(resources["weekly"]?["used"] as? Double, 84)
        provider.refreshError = "OpenCode sign-in changed."
        let failed = try await reader.read()
        let failedRoot = try XCTUnwrap(JSONSerialization.jsonObject(with: failed.data) as? [String: Any])
        XCTAssertNil((failedRoot["providers"] as? [String: Any])?["opencode"])
        XCTAssertEqual(provider.refreshCount, 3)
    }

    func testUnresolvedClaudeIdentityRejectsFreshPersistedCacheBeforeReturning() async throws {
        let defaults = defaults()
        let provider = StubProvider(id: "claude")
        ProviderSnapshotCache(userDefaults: defaults).store(
            await provider.refresh(), producedByIdentityKey: "previous-account"
        )
        provider.refreshCount = 0
        provider.refreshError = "Claude account identity could not be verified."

        let result = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "claude")
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertTrue(try XCTUnwrap(root["providers"] as? [String: Any]).isEmpty)
        XCTAssertEqual(result.warnings, ["claude: Claude account identity could not be verified."])
    }

    func testForceUsesSharedProviderAndStoresResult() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        let reader = UsageReader(userDefaults: defaults, providers: [provider])

        let result = try await reader.read(providerID: "stub", force: true)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let cached = ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["stub"])

        XCTAssertEqual(provider.refreshCount, 1)
        XCTAssertNotNil((object["providers"] as? [String: Any])?["stub"])
        XCTAssertEqual(cached["stub"]?.line(label: "Weekly"), .progress(
            label: "Weekly",
            used: 20,
            limit: 100,
            format: .percent,
            resetsAt: nil,
            periodDurationMs: nil,
            colorHex: nil
        ))
    }

    func testStalePersistedSnapshotRefreshesBeforeReading() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        provider.refreshedAt = Date().addingTimeInterval(-RefreshSetting.interval - 1)
        ProviderSnapshotCache(userDefaults: defaults).store(await provider.refresh())
        provider.refreshCount = 0
        provider.refreshedAt = Date()

        let result = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "stub")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])

        XCTAssertNotNil((object["providers"] as? [String: Any])?["stub"])
        XCTAssertEqual(provider.refreshCount, 1)
    }

    func testForcedProviderReadRefreshesOnlyRequestedProvider() async throws {
        let defaults = defaults()
        let requested = StubProvider(id: "requested")
        let other = StubProvider(id: "other")

        _ = try await UsageReader(userDefaults: defaults, providers: [requested, other])
            .read(providerID: "requested", force: true)

        XCTAssertEqual(requested.refreshCount, 1)
        XCTAssertEqual(other.refreshCount, 0)
    }

    func testUnknownProviderFailsBeforeRefresh() async {
        let defaults = defaults()
        let provider = StubProvider()

        do {
            _ = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "missing", force: true)
            XCTFail("Expected unknown provider error")
        } catch UsageReaderError.unknownProvider(let providerID) {
            XCTAssertEqual(providerID, "missing")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(provider.refreshCount, 0)
    }

    func testFailedForceWithoutCacheReturnsMachineReadableError() async throws {
        let defaults = defaults()
        let provider = StubProvider()
        provider.refreshError = "Not logged in"

        let result = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(providerID: "stub", force: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let errors = try XCTUnwrap(root["errors"] as? [[String: Any]])

        XCTAssertEqual(result.warnings, ["stub: Not logged in"])
        XCTAssertEqual(errors.first?["providerId"] as? String, "stub")
        XCTAssertEqual(errors.first?["message"] as? String, "Not logged in")
    }

    func testTrustedCLIOutputKeepsResolvedAccountName() async throws {
        let defaults = defaults()
        let store = ProviderAccountsStore(defaults: defaults)
        store.reconcile(with: [
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-a",
                label: "first@example.com",
                sources: [ProviderAccountSource(kind: .defaultHome, anchor: "/test/a", holdsDefaultSource: true)]
            ),
            ProviderAccountsStore.AccountObservation(
                family: "claude",
                identityKey: "acct-b",
                label: "second@example.com",
                sources: [ProviderAccountSource(kind: .configDir, anchor: "/test/b", holdsDefaultSource: false)]
            ),
        ])
        let providerID = ProviderAccountID.make(family: "claude", identityKey: "acct-b")
        let provider = StubProvider(id: providerID)

        let result = try await UsageReader(userDefaults: defaults, providers: [provider])
            .read(providerID: providerID, force: true)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])

        XCTAssertEqual(
            (providers[providerID] as? [String: Any])?["displayName"] as? String,
            "Claude — second@example.com"
        )
    }
}
