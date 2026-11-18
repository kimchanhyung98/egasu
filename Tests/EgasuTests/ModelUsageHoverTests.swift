import XCTest
@testable import Egasu

@MainActor
final class ModelUsageHoverTests: XCTestCase {
    func testValuesLineCodableRoundTripsModelBreakdown() throws {
        let breakdown = sampleBreakdown()
        let line = MetricLine.values(
            label: "Today",
            values: [MetricValue(number: 3, kind: .dollars), MetricValue(number: 300, kind: .count, label: "tokens")],
            modelBreakdown: breakdown
        )

        let data = try JSONEncoder().encode(line)
        let decoded = try JSONDecoder().decode(MetricLine.self, from: data)

        XCTAssertEqual(decoded, line)
    }

    func testDataStoreResolvesModelBreakdownOntoSpendRow() {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let descriptor = WidgetDescriptor.spendTiles(provider: provider).first { $0.id == "claude.today" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeDefaults("resolve")
        )
        store.snapshots[provider.id] = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3, kind: .dollars, estimated: true),
                        MetricValue(number: 300, kind: .count, label: "tokens")
                    ],
                    modelBreakdown: sampleBreakdown()
                )
            ]
        )

        let data = store.data(for: descriptor)

        XCTAssertTrue(data.hasModelBreakdown)
        XCTAssertEqual(data.modelBreakdown?.models.map(\.model), ["alpha", "beta"])
        XCTAssertEqual(data.modelBreakdown?.sourceNote, "From test logs")
    }

    func testDataStoreAllowsSingleModelBreakdown() {
        let provider = Provider(id: "codex", displayName: "Codex", icon: .providerMark("codex"))
        let descriptor = WidgetDescriptor.spendTiles(provider: provider).first { $0.id == "codex.today" }!
        let runtime = TestProviderRuntime(
            provider: provider,
            descriptors: [descriptor],
            snapshot: ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
        )
        let store = WidgetDataStore(
            registry: WidgetRegistry(providers: [provider], descriptors: [descriptor]),
            providers: [runtime],
            defaults: makeDefaults("single-model")
        )
        store.snapshots[provider.id] = ProviderSnapshot(
            providerID: provider.id,
            displayName: provider.displayName,
            lines: [
                .values(
                    label: "Today",
                    values: [
                        MetricValue(number: 3, kind: .dollars, estimated: true),
                        MetricValue(number: 300, kind: .count, label: "tokens")
                    ],
                    modelBreakdown: ModelUsageBreakdown(
                        totalTokens: 300,
                        totalCostUSD: 3,
                        models: [ModelUsageEntry(model: "gpt-5.5", totalTokens: 300, costUSD: 3)],
                        sourceNote: "From Codex test logs"
                    )
                )
            ]
        )

        let data = store.data(for: descriptor)

        XCTAssertTrue(data.hasModelBreakdown)
        XCTAssertEqual(data.modelBreakdown?.models.map(\.model), ["gpt-5.5"])
    }

    func testHoverPopoverStateOpensThenClosesAroundBothRegions() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        XCTAssertFalse(state.isPresented)

        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "opens after the reveal dwell while the row is hovered")

        state.inlineHover(false)
        state.detailHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented, "stays open while the cursor is inside the popover")

        state.detailHover(false)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertFalse(state.isPresented, "closes once the cursor has left both the row and the popover")
    }

    func testHoverPopoverStateQuickPassDoesNotOpen() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(60), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        state.inlineHover(false)
        try? await Task.sleep(for: .milliseconds(90))
        XCTAssertFalse(state.isPresented, "a quick pass over the row never opens the popover")
    }

    func testHoverPopoverStateDismissForcesClosed() async {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        state.inlineHover(true)
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertTrue(state.isPresented)

        state.dismiss()
        XCTAssertFalse(state.isPresented, "teardown closes it immediately")
    }

    func testExplicitDetailsStayOpenAfterBothHoverRegionsAreLeft() async throws {
        let state = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        state.openDetails()
        XCTAssertTrue(state.openedExplicitly)
        state.inlineHover(false)
        state.detailHover(false)

        try await Task.sleep(for: .milliseconds(40))

        XCTAssertTrue(state.isPresented, "클릭으로 연 상세는 포인터가 벗어나도 유지")
        state.dismiss()
        XCTAssertFalse(state.openedExplicitly)
        XCTAssertFalse(state.isPresented)
    }

    func testDetailDoesNotReopenAfterItsDataReturns() {
        let state = HoverPopoverState()
        state.openDetails()
        state.detailAvailabilityChanged(true)
        XCTAssertTrue(state.isPresented)
        XCTAssertTrue(state.openedExplicitly)

        state.detailAvailabilityChanged(false)
        XCTAssertFalse(state.isPresented)
        XCTAssertFalse(state.openedExplicitly)

        state.detailAvailabilityChanged(true)
        XCTAssertFalse(state.isPresented)
    }

    func testPanelDismissalClearsExplicitPinnedAndPendingDetails() async throws {
        let explicit = HoverPopoverState(revealDelay: .milliseconds(1), hideGrace: .milliseconds(1))
        let pending = HoverPopoverState(revealDelay: .milliseconds(20), hideGrace: .milliseconds(1))
        explicit.openDetails()
        explicit.setPinned(true)
        pending.inlineHover(true)

        HoverPopoverState.dismissAll()
        try await Task.sleep(for: .milliseconds(50))

        for state in [explicit, pending] {
            XCTAssertFalse(state.isPresented)
            XCTAssertFalse(state.openedExplicitly)
            XCTAssertFalse(state.isPinned)
            XCTAssertFalse(state.overInline)
        }
    }

    private func sampleBreakdown() -> ModelUsageBreakdown {
        ModelUsageBreakdown(
            totalTokens: 300,
            totalCostUSD: 3,
            models: [
                ModelUsageEntry(model: "alpha", totalTokens: 100, costUSD: 1),
                ModelUsageEntry(model: "beta", totalTokens: 200, costUSD: 2)
            ],
            sourceNote: "From test logs"
        )
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.ModelUsageHover.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
