import XCTest
@testable import Egasu

@MainActor
final class WidgetDataStoreAutomationTests: XCTestCase {
    func testFreshQuotaCallbackPreservesTriggerAndExcludesCacheHits() async {
        let fixture = Fixture()
        var triggers: [RefreshTrigger] = []
        fixture.store.onFreshSnapshot = { _, _, trigger in triggers.append(trigger) }

        await fixture.store.refresh(providerID: "codex", force: true, trigger: .manual)
        await fixture.store.refresh(providerID: "codex")
        await fixture.store.refreshAfterWeeklyTimer(providerID: "codex", isCurrent: { true })

        XCTAssertEqual(triggers, [.manual, .weeklyTimer])
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
    }

    func testActiveAutomationSuspendsRefreshWithoutReplacingLastGoodQuota() async {
        let fixture = Fixture()
        await fixture.store.refresh(providerID: "codex", force: true)
        let snapshot = fixture.store.snapshots["codex"]
        var suspended = true
        fixture.store.isRefreshSuspended = { _ in suspended }

        let outcome = await fixture.store.refresh(providerID: "codex", force: true, trigger: .manual)

        XCTAssertEqual(outcome, .skipped)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
        XCTAssertEqual(fixture.store.snapshots["codex"], snapshot)
        XCTAssertNil(fixture.store.errorMessage(for: "codex"))
        suspended = false
        await fixture.store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(fixture.runtime.refreshCount, 2)
    }

    func testPostTimerRefreshStopsWhenBindingChanges() async {
        let fixture = Fixture()
        var current = true
        var skipped = 0
        fixture.store.isRefreshSuspended = { _ in
            skipped += 1
            current = false
            return true
        }
        await fixture.store.refreshAfterWeeklyTimer(providerID: "codex", isCurrent: { current })
        XCTAssertEqual(fixture.runtime.refreshCount, 0)
        XCTAssertEqual(skipped, 1)
    }

    func testAutomationWarningUsesExistingHeaderWithoutChangingQuotaOrCache() async {
        let fixture = Fixture()
        await fixture.store.refresh(providerID: "codex", force: true)
        let snapshot = fixture.store.snapshots["codex"]

        fixture.store.setAutomationWarning(["Weekly timer could not be confirmed."], for: "codex")

        XCTAssertEqual(fixture.store.headerNotice(for: "codex"), "Weekly timer could not be confirmed.")
        XCTAssertEqual(fixture.store.snapshots["codex"], snapshot)
        XCTAssertNil(fixture.store.warningMessage(for: "codex"))
        XCTAssertNil(fixture.store.providerErrors["codex"])
        fixture.store.setAutomationWarning(nil, for: "codex")
        XCTAssertNil(fixture.store.headerNotice(for: "codex"))
    }

    func testMultipleAutomationWarningsTranslateAfterLanguageChangesWithoutReplacingWarnings() async {
        let fixture = Fixture()
        await fixture.store.refresh(providerID: "codex", force: true)
        let snapshot = fixture.store.snapshots["codex"]
        let warnings = [
            "Usage timer message could not be prepared. Refresh to try again.",
            "Usage timer automation could not update its saved state."
        ]
        fixture.store.setAutomationWarning(warnings, for: "codex")

        let expected: [(LanguageSetting, String)] = [
            (.korean, "사용량 타이머 메시지를 준비하지 못했습니다. 새로고침하여 다시 시도하세요. 사용량 타이머 자동화의 저장된 상태를 갱신하지 못했습니다."),
            (.japanese, "使用量タイマーのメッセージを準備できませんでした。更新して、もう一度試してください。 使用量タイマーの自動処理で保存済みの状態を更新できませんでした。"),
            (.english, warnings.joined(separator: " "))
        ]
        for (language, message) in expected {
            L10n.withLanguage(language) {
                XCTAssertEqual(fixture.store.headerNotice(for: "codex"), message)
            }
        }
        XCTAssertEqual(fixture.store.snapshots["codex"], snapshot)
        XCTAssertEqual(fixture.runtime.refreshCount, 1)
        fixture.store.setAutomationWarning(nil, for: "codex")
        XCTAssertNil(fixture.store.headerNotice(for: "codex"))
    }

    @MainActor
    private final class Fixture {
        let suite = "EgasuTests.Automation.\(UUID().uuidString)"
        let defaults: UserDefaults
        let runtime: CountingProviderRuntime
        let store: WidgetDataStore

        init() {
            defaults = UserDefaults(suiteName: suite)!
            let provider = CodexProvider.makeProvider()
            runtime = CountingProviderRuntime(
                provider: provider, descriptors: [],
                snapshot: ProviderSnapshot(
                    providerID: provider.id, displayName: provider.displayName,
                    lines: [.progress(label: "Weekly", used: 0, limit: 100, format: .percent)],
                    liveQuotaObservedAt: Date()
                )
            )
            store = WidgetDataStore(
                registry: .from([runtime]), providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults
            )
        }

        isolated deinit { defaults.removePersistentDomain(forName: suite) }
    }
}
