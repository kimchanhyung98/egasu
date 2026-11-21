import XCTest
@testable import Egasu

final class LocalLimitsAPITests: XCTestCase {
    private let fetchedAt = EgasuISO8601.date(from: "2026-07-13T01:39:30.000Z")!
    private let generatedAt = EgasuISO8601.date(from: "2026-07-13T01:40:00.000Z")!

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }

    @MainActor
    private func exportedResources(_ runtime: any ProviderRuntime, line: MetricLine) throws -> [String: [String: Any]] {
        let id = runtime.provider.id
        let snapshot = ProviderSnapshot.make(provider: runtime.provider, plan: nil, lines: [line], refreshedAt: fetchedAt)
        let state = LocalUsageAPI.State(enabledOrderedIDs: [id], knownIDs: [id], snapshots: [id: snapshot],
                                        limitDescriptors: [id: runtime.widgetDescriptors], generatedAt: generatedAt)
        let root = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let providers = try XCTUnwrap(root["providers"] as? [String: [String: Any]])
        return try XCTUnwrap(providers[id]?["resources"] as? [String: [String: Any]])
    }

    func testClaudeExpiryTracksLastQuotaObservationDespiteLocalRefreshAndCooldown() throws {
        let snapshot = ProviderSnapshot(
            providerID: "claude@work", displayName: "Claude", lines: [], refreshedAt: generatedAt,
            quotaObservedAt: fetchedAt, usageRetryAfter: fetchedAt.addingTimeInterval(3600)
        )
        var state = LocalUsageAPI.State(
            enabledOrderedIDs: ["claude@work"], knownIDs: ["claude@work"],
            snapshots: ["claude@work": snapshot], generatedAt: fetchedAt.addingTimeInterval(899)
        )
        func encoded() throws -> [String: Any] {
            let root = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
            return try XCTUnwrap((root["providers"] as? [String: Any])?["claude@work"] as? [String: Any])
        }
        let fresh = try encoded()
        XCTAssertEqual(fresh["fetchedAt"] as? String, EgasuISO8601.string(from: fetchedAt))
        XCTAssertEqual(fresh["expiresAt"] as? String, EgasuISO8601.string(from: fetchedAt.addingTimeInterval(900)))
        XCTAssertEqual(fresh["stale"] as? Bool, false)
        state.generatedAt = fetchedAt.addingTimeInterval(900)
        XCTAssertEqual(try encoded()["stale"] as? Bool, true)
        state.snapshots["claude@work"]?.quotaObservedAt = nil
        state.generatedAt = generatedAt
        XCTAssertEqual(try encoded()["stale"] as? Bool, true)
    }

    @MainActor
    func testExportsBusinessCreditsWithoutFlex() throws {
        let provider = CodexProvider()
        let line = MetricLine.progress(label: "Individual Credits", used: 898.386, limit: 2500,
                                       format: .count(suffix: "credits"))
        let resources = try exportedResources(provider, line: line)
        XCTAssertEqual(resources["individualCredits"]?["used"] as? Double, 898.386)
        XCTAssertEqual(resources["individualCredits"]?["unit"] as? String, "credits")
        XCTAssertNil(resources["credits"])
    }

    func testLimitsEnvelopeCarriesRawScalarsAndFreshnessWithoutUIPresentation() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let session = WidgetDescriptor.percent(id: "codex.session", provider: provider, title: "Session")
            .exportingLimit("session", unit: "percent")
        let credits = WidgetDescriptor.combined(
            id: "codex.credits", provider: provider, title: "Extra Usage", metricLabel: "Credits"
        )
        .exportingLimit("credits", kind: .balance, unit: "credits", source: .value(kind: .count, label: "credits"))
        .exportingLimit("creditValue", kind: .balance, unit: "usd", source: .value(kind: .dollars))
        let snapshot = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            plan: "Pro",
            lines: [
                .progress(
                    label: "Session", used: 42, limit: 100, format: .percent,
                    resetsAt: EgasuISO8601.date(from: "2026-07-13T06:00:00.000Z"),
                    periodDurationMs: 18_000_000,
                    colorHex: "#ff0000"
                ),
                .values(label: "Credits", values: [
                    MetricValue(number: 32.84, kind: .dollars),
                    MetricValue(number: 821, kind: .count, label: "credits")
                ]),
                .chart(label: "Usage Trend", points: [], note: "UI only")
            ],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["codex"],
            knownIDs: ["codex"],
            snapshots: ["codex": snapshot],
            limitDescriptors: ["codex": [session, credits]],
            generatedAt: generatedAt
        )

        let response = LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state)
        let root = try json(response.body)
        let providerJSON = try XCTUnwrap((root["providers"] as? [String: Any])?["codex"] as? [String: Any])
        let resources = try XCTUnwrap(providerJSON["resources"] as? [String: Any])
        let sessionJSON = try XCTUnwrap(resources["session"] as? [String: Any])
        let creditsJSON = try XCTUnwrap(resources["credits"] as? [String: Any])

        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(root["schema"] as? String, "openusage.limits.v1")
        XCTAssertEqual(root["generatedAt"] as? String, "2026-07-13T01:40:00.000Z")
        XCTAssertEqual(providerJSON["plan"] as? String, "Pro")
        XCTAssertEqual(providerJSON["fetchedAt"] as? String, "2026-07-13T01:39:30.000Z")
        XCTAssertEqual(providerJSON["expiresAt"] as? String, "2026-07-13T01:44:30.000Z")
        XCTAssertEqual(providerJSON["stale"] as? Bool, false)
        XCTAssertEqual(sessionJSON["kind"] as? String, "consumption")
        XCTAssertEqual(sessionJSON["unit"] as? String, "percent")
        XCTAssertEqual(sessionJSON["used"] as? Double, 42)
        XCTAssertEqual(sessionJSON["limit"] as? Double, 100)
        XCTAssertEqual(sessionJSON["remaining"] as? Double, 58)
        XCTAssertEqual(try XCTUnwrap(sessionJSON["utilization"] as? Double), 0.42, accuracy: 0.000_001)
        XCTAssertEqual(sessionJSON["windowSeconds"] as? Double, 18_000)
        XCTAssertEqual(creditsJSON["kind"] as? String, "balance")
        XCTAssertEqual(creditsJSON["available"] as? Double, 821)
        XCTAssertNotNil(resources["creditValue"])
        XCTAssertNil(resources["Usage Trend"])
        XCTAssertNil(sessionJSON["color"])
        XCTAssertNil(sessionJSON["subtitle"])
        XCTAssertNil(sessionJSON["label"])

        var expiredState = state
        expiredState.generatedAt = fetchedAt.addingTimeInterval(RefreshSetting.interval)
        let expiredRoot = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: expiredState).body)
        let expiredProviders = try XCTUnwrap(expiredRoot["providers"] as? [String: Any])
        let expiredProvider = try XCTUnwrap(expiredProviders["codex"] as? [String: Any])
        XCTAssertEqual(expiredProvider["stale"] as? Bool, true)
    }

    func testUsageAndLimitsProjectTheSameRenderedSnapshot() throws {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let session = WidgetDescriptor.percent(id: "codex.session", provider: provider, title: "Session")
            .exportingLimit("session", unit: "percent")
        let snapshot = ProviderSnapshot(
            providerID: "codex",
            displayName: "Codex",
            lines: [.progress(label: "Session", used: 73, limit: 100, format: .percent)],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["codex"],
            knownIDs: ["codex"],
            snapshots: ["codex": snapshot],
            limitDescriptors: ["codex": [session]],
            generatedAt: generatedAt
        )

        let usage = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: XCTUnwrap(LocalUsageAPI.respond(method: "GET", path: "/v1/usage", state: state).body)
            ) as? [[String: Any]]
        )
        let usageLine = try XCTUnwrap((usage.first?["lines"] as? [[String: Any]])?.first)
        let limitsRoot = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let limitsProvider = try XCTUnwrap((limitsRoot["providers"] as? [String: Any])?["codex"] as? [String: Any])
        let limitsSession = try XCTUnwrap((limitsProvider["resources"] as? [String: Any])?["session"] as? [String: Any])

        XCTAssertEqual(usageLine["used"] as? Double, 73)
        XCTAssertEqual(limitsSession["used"] as? Double, 73)
    }

    func testKnownProviderRouteUsesSameEnvelopeAndReportsMissingSnapshotAsEmpty() throws {
        var state = LocalUsageAPI.State(
            enabledOrderedIDs: [],
            knownIDs: ["codex"],
            snapshots: [:],
            generatedAt: generatedAt
        )
        // known이지만 미fetch → 형태 불변, 빈 envelope의 200
        let pending = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/codex", state: state)
        XCTAssertEqual(pending.status, 200)
        let pendingRoot = try json(pending.body)
        XCTAssertTrue((pendingRoot["providers"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(LocalUsageAPI.respond(method: "GET", path: "/v1/limits/nope", state: state).status, 404)

        state.errors["codex"] = "Not logged in"
        let failed = LocalUsageAPI.respond(method: "GET", path: "/v1/limits/codex", state: state)
        let root = try json(failed.body)
        let errors = try XCTUnwrap(root["errors"] as? [[String: Any]])
        XCTAssertEqual(failed.status, 200)
        XCTAssertTrue((root["providers"] as? [String: Any])?.isEmpty == true)
        XCTAssertEqual(errors.first?["providerId"] as? String, "codex")
        XCTAssertEqual(errors.first?["message"] as? String, "Not logged in")
    }

    func testFlexibleConsumptionExportsUncappedValueWithoutInventingLimit() throws {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let extra = WidgetDescriptor.boundedDollars(
            id: "claude.extra", provider: provider, title: "Extra Usage",
            metricLabel: "Extra usage spent", limit: 100
        ).exportingLimit("extraUsage", unit: "usd", source: .progressOrValue(kind: .dollars))
        let snapshot = ProviderSnapshot(
            providerID: "claude",
            displayName: "Claude",
            lines: [.values(label: "Extra usage spent", values: [MetricValue(number: 12.5, kind: .dollars)])],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["claude"],
            knownIDs: ["claude"],
            snapshots: ["claude": snapshot],
            limitDescriptors: ["claude": [extra]],
            generatedAt: generatedAt
        )

        let root = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let claude = try XCTUnwrap(providers["claude"] as? [String: Any])
        let resources = try XCTUnwrap(claude["resources"] as? [String: Any])
        let resource = try XCTUnwrap(resources["extraUsage"] as? [String: Any])

        XCTAssertEqual(resource["used"] as? Double, 12.5)
        XCTAssertNil(resource["limit"])
        XCTAssertNil(resource["remaining"])
        XCTAssertNil(resource["utilization"])
    }

    func testProgressResourceUnitFollowsRuntimeMetricFormat() throws {
        let provider = Provider(id: "cursor", displayName: "Cursor", icon: .providerMark("cursor"))
        let total = WidgetDescriptor.percent(
            id: "cursor.usage", provider: provider, title: "Total Usage", metricLabel: "Total usage"
        ).exportingLimit("totalUsage", unit: "percent")
        let snapshot = ProviderSnapshot(
            providerID: "cursor",
            displayName: "Cursor",
            lines: [.progress(
                label: "Total usage", used: 37, limit: 750,
                format: .count(suffix: "requests")
            )],
            refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["cursor"],
            knownIDs: ["cursor"],
            snapshots: ["cursor": snapshot],
            limitDescriptors: ["cursor": [total]],
            generatedAt: generatedAt
        )

        let root = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits", state: state).body)
        let providers = try XCTUnwrap(root["providers"] as? [String: Any])
        let cursor = try XCTUnwrap(providers["cursor"] as? [String: Any])
        let resources = try XCTUnwrap(cursor["resources"] as? [String: Any])
        let resource = try XCTUnwrap(resources["totalUsage"] as? [String: Any])

        XCTAssertEqual(resource["unit"] as? String, "requests")
        XCTAssertEqual(resource["used"] as? Double, 37)
        XCTAssertEqual(resource["limit"] as? Double, 750)
    }

    @MainActor
    func testOpenCodeExportsOnlyTheReportedCurrencyOrPercentResource() throws {
        let provider = OpenCodeProvider()
        let measured = try exportedResources(provider, line: .progress(label: "Weekly", used: 20, limit: 100, format: .percent))
        XCTAssertEqual(measured["goWeekly"]?["unit"] as? String, "percent")
        XCTAssertNil(measured["weekly"])
        let estimated = try exportedResources(provider, line: .progress(label: "Weekly", used: 6, limit: 30, format: .dollars))
        XCTAssertEqual(estimated["weekly"]?["estimated"] as? Bool, true)
        XCTAssertNil(estimated["goWeekly"])
    }

    @MainActor
    func testEveryProviderDeclaresTheApprovedPublicResourceKeys() {
        let defaults = UserDefaults(suiteName: "LocalLimitsAPITests.\(UUID().uuidString)")!
        let registry = WidgetRegistry.from(ProviderCatalog.make(defaults: defaults))
        let actual = registry.limitDescriptorsByProvider.mapValues { descriptors in
            Set(descriptors.flatMap(\.limitResources).map(\.key))
        }
        let expected: [String: Set<String>] = [
            "claude": ["session", "weekly", "sonnet", "fable", "extraUsage"],
            "codex": [
                "session", "weekly", "monthly", "spark", "sparkWeekly", "sparkMonthly", "credits", "creditValue",
                "rateLimitResets", "individualCredits"
            ],
            "cursor": ["totalUsage", "autoUsage", "apiUsage", "onDemand", "requests", "credits"],
            "antigravity": ["geminiSession", "geminiWeekly", "nonGeminiSession", "nonGeminiWeekly", "argonWeekly"],
            "copilot": ["premiumCredits", "extraUsage", "orgCredits", "orgSpend", "chat", "completions"],
            "devin": ["daily", "weekly", "extraUsageBalance"],
            "grok": ["weekly", "monthly"],
            "kimi": ["session", "weekly", "totalUsage", "extraUsage", "extraUsageBalance"],
            "kiro": ["credits"],
            "opencode": ["session", "weekly", "monthly", "goSession", "goWeekly", "goMonthly"],
            "openrouter": ["credits", "balance", "keyLimit"],
            "zai": ["session", "weekly", "monthly", "webSearches"]
        ]

        XCTAssertEqual(actual, expected)
    }

    @MainActor
    func testKimiExportsMonthlyTotalWithoutSeparateCodeContribution() throws {
        let provider = KimiProvider()
        let mapped = try KimiUsageMapper.map([
            "usages": ["limit_month_total": ["used_ratio": 0.25], "limit_month_code": ["used_ratio": 0.15]]
        ])
        let snapshot = ProviderSnapshot(
            providerID: "kimi", displayName: "Kimi", lines: mapped.lines, refreshedAt: fetchedAt
        )
        let state = LocalUsageAPI.State(
            enabledOrderedIDs: ["kimi"], knownIDs: ["kimi"], snapshots: ["kimi": snapshot],
            limitDescriptors: ["kimi": provider.widgetDescriptors], generatedAt: generatedAt
        )

        let root = try json(LocalUsageAPI.respond(method: "GET", path: "/v1/limits/kimi", state: state).body)
        let kimi = try XCTUnwrap((root["providers"] as? [String: Any])?["kimi"] as? [String: Any])
        let resources = try XCTUnwrap(kimi["resources"] as? [String: Any])
        let total = try XCTUnwrap(resources["totalUsage"] as? [String: Any])

        XCTAssertEqual(Set(resources.keys), ["totalUsage"])
        XCTAssertEqual(total["unit"] as? String, "percent")
        XCTAssertEqual(total["used"] as? Double, 25)
        XCTAssertEqual(total["limit"] as? Double, 100)
        XCTAssertEqual(total["remaining"] as? Double, 75)
    }
}
