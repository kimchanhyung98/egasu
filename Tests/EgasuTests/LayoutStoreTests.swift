import XCTest
@testable import Egasu

@MainActor
final class LayoutStoreTests: XCTestCase {
    func testRemoveClearsDragStateAndAllowsRepeatedRemoval() {
        let store = makeStore("RepeatedRemoval")
        let first = PlacedWidget(id: UUID(), descriptorID: DefaultLayout.metricIDs(in: .mock)[0])
        let second = PlacedWidget(id: UUID(), descriptorID: DefaultLayout.metricIDs(in: .mock)[1])
        store.placed = [first, second]
        store.draggingID = first.id

        store.remove(first.id)

        XCTAssertNil(store.draggingID)
        XCTAssertEqual(store.placed, [second])

        store.remove(second.id)

        XCTAssertTrue(store.placed.isEmpty)
    }

    // MARK: - Undo (#603)

    func testUndoRestoresRemovedMetricToSamePosition() {
        let store = makeStore("UndoRestoresPosition")
        // 순서 고정과 이웃 metric 확보를 위해 Claude 전체 set 활성화
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)
        let enabledBefore = store.placed.filter { $0.descriptorID.hasPrefix("claude.") }.map(\.descriptorID)

        store.setMetricEnabled("claude.weekly", false)
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())

        XCTAssertTrue(store.isMetricEnabled("claude.weekly"))
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)
        XCTAssertEqual(
            store.placed.filter { $0.descriptorID.hasPrefix("claude.") }.map(\.descriptorID),
            enabledBefore
        )
    }

    func testUndoReversesEnable() {
        let store = makeStore("UndoEnable")
        store.setMetricEnabled("cursor.credits", false)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"), "undo turns an enabled metric back off")
    }

    func testUndoReversesMetricReorder() {
        let store = makeStore("UndoReorderMetric")
        for id in ["claude.session", "claude.weekly", "claude.extra", "claude.today"] {
            store.setMetricEnabled(id, true)
        }
        let orderBefore = store.orderedSupportedMetrics(for: "claude").map(\.id)

        XCTAssertTrue(store.reorderMetric(dragged: "claude.today", target: "claude.session", in: "claude"))
        XCTAssertNotEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id), orderBefore,
                       "undo restores the exact prior metric order")
    }

    func testUndoReversesProviderReorder() {
        let store = makeStore("UndoReorderProvider")
        let orderBefore = store.customizeGroups.map(\.provider.id)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))
        XCTAssertNotEqual(store.customizeGroups.map(\.provider.id), orderBefore)

        XCTAssertTrue(store.undo())
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), orderBefore,
                       "undo restores the exact prior provider order")
    }

    func testUndoReversesPinAndUnpin() {
        let store = makeStore("UndoPin")
        XCTAssertTrue(store.isMetricEnabled("cursor.usage"))
        XCTAssertFalse(store.isMetricPinned("cursor.usage"))

        store.setMetric("cursor.usage", pinned: true)
        XCTAssertTrue(store.isMetricPinned("cursor.usage"))
        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricPinned("cursor.usage"), "undo reverses a pin")

        store.setMetric("cursor.usage", pinned: true)
        store.setMetric("cursor.usage", pinned: false)
        XCTAssertFalse(store.isMetricPinned("cursor.usage"))
        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricPinned("cursor.usage"), "undo reverses an unpin")
    }

    func testUndoWalksBackMultipleMixedSteps() {
        let store = makeStore("UndoMultiStep", hiddenMetricIDs: ["cursor.credits"])
        store.setMetricEnabled("cursor.credits", true)
        store.setMetric("cursor.usage", pinned: true)
        store.setMetricEnabled("claude.session", false)

        XCTAssertTrue(store.undo())
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertTrue(store.isMetricPinned("cursor.usage"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricPinned("cursor.usage"))
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testUndoIsNotItselfRecorded() {
        // undo 자체가 step으로 기록되면 ⌘Z가 무한 왕복 — 미기록 보장
        let store = makeStore("UndoNotRecorded", hiddenMetricIDs: ["cursor.credits"])
        store.setMetricEnabled("cursor.credits", true)
        XCTAssertTrue(store.canUndo)

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo, "undo leaves nothing new to undo")
    }

    func testUndoStackIsCappedAtMaxDepth() {
        let store = makeStore("UndoMaxDepth")
        // pin 토글 반복으로 cap 초과 step 생성
        store.setMetricEnabled("claude.weekly", true)
        var pinned = false
        for _ in 0..<(LayoutUndoHistory.maxDepth + 10) {
            pinned.toggle()
            store.setMetric("claude.weekly", pinned: pinned)
        }
        var steps = 0
        while store.undo() { steps += 1 }
        XCTAssertEqual(steps, LayoutUndoHistory.maxDepth)
    }

    func testNoOpActionDoesNotRecordUndoStep() {
        let store = makeStore("UndoNoOp", hiddenMetricIDs: ["cursor.credits"])
        store.setMetricEnabled("cursor.credits", true)  // 실제 step 1건
        // 이미 켜진 metric 재활성화·self-target reorder는 no-op — step 미기록
        store.setMetricEnabled("cursor.credits", true)
        store.reorderMetric(dragged: "claude.weekly", target: "claude.weekly", in: "claude")

        XCTAssertTrue(store.undo())
        XCTAssertFalse(store.canUndo)
    }

    func testUndoWithEmptyHistoryIsNoOp() {
        let store = makeStore("UndoEmpty")
        let before = store.placed.map(\.descriptorID)

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    func testResetToDefaultClearsUndoHistory() {
        let store = makeStore("UndoResetAllClears")
        store.setMetricEnabled("claude.weekly", true)
        store.setMetricEnabled("claude.weekly", false)
        XCTAssertTrue(store.canUndo)

        store.resetToDefault()

        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testResetProviderClearsUndoHistory() {
        let store = makeStore("UndoResetProviderClears", hiddenMetricIDs: ["cursor.credits", "cursor.requests"])
        store.setMetricEnabled("cursor.credits", true)
        store.setMetricEnabled("cursor.requests", true)
        XCTAssertTrue(store.canUndo)

        store.resetProvider("claude")

        // snapshot은 whole-layout 단위 — reset은 전체 stack 폐기
        XCTAssertFalse(store.canUndo)
        XCTAssertFalse(store.undo())
    }

    func testDirectRemoveDoesNotRecordUndo() {
        // 저수준 `remove(_:)`는 user-facing seam이 아니어서 undo stack 미기록
        let store = makeStore("UndoDirectRemove")
        store.placed = [PlacedWidget(descriptorID: "claude.weekly")]
        guard let widget = store.placed.first(where: { $0.descriptorID == "claude.weekly" }) else {
            return XCTFail("metric was not placed")
        }

        store.remove(widget.id)

        XCTAssertFalse(store.canUndo)
    }

    func testSavedEmptyLayoutDoesNotRestoreDefaults() {
        let defaults = makeDefaults("EmptyLayout")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        for widget in store.placed {
            store.remove(widget.id)
        }

        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.placed.isEmpty)
    }

    func testUnreadableStoredLayoutIsNotMistakenForFreshInstall() {
        let defaults = makeDefaults("UnreadableExistingLayout")
        let original = Data("not valid layout data".utf8)
        defaults.set(original, forKey: "layout")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        XCTAssertTrue(store.placed.isEmpty, "손상된 저장 상태를 새 설치의 기본 표시로 바꾸지 않음")
        XCTAssertEqual(defaults.data(forKey: "layout"), original)
        XCTAssertNil(defaults.object(forKey: "layout.disabledMetrics"))
    }

    func testUnreadableSeedMarkerKeepsExistingUserBaseline() {
        let defaults = makeDefaults("UnreadableSeedMarker")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(Data("not valid seeded-default data".utf8), forKey: "layout.seededDefaults")

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session"])
    }

    func testExistingLayoutAutoSeedsOnlyDefaultsAddedAfterBaseline() {
        let defaults = makeDefaults("SeedNewDefault")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)

        let oldRegistry = WidgetRegistry(
            providers: WidgetRegistry.mock.providers,
            descriptors: WidgetRegistry.mock.descriptors.filter { $0.id != "claude.today" }
        )
        _ = LayoutStore(
            registry: oldRegistry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"], migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session", "claude.weekly"]
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.session", "claude.today"])
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"), "baseline defaults the user already removed stay off")
    }

    func testDisablingAutoSeededDefaultDoesNotReAddOnReload() {
        let defaults = makeDefaults("SeedOnce")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        let oldRegistry = WidgetRegistry(
            providers: WidgetRegistry.mock.providers,
            descriptors: WidgetRegistry.mock.descriptors.filter { $0.id != "claude.today" }
        )
        _ = LayoutStore(
            registry: oldRegistry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ["claude.session"], migrationBaselineMetricIDs: ["claude.session"]
        )

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        guard let seeded = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("new default was not seeded")
        }

        store.remove(seeded.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testFreshLayoutTreatsCurrentDefaultsAsAlreadySeeded() {
        let defaults = makeDefaults("FreshSeeded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        guard let today = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("fresh store did not include all current defaults")
        }

        store.remove(today.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testLegacyEmptyLayoutStaysEmptyWithUnknownDefaults() {
        let defaults = makeDefaults("UnknownSeed")
        saveStored([PlacedWidget](), forKey: "layout", in: defaults)

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["missing.metric", "claude.session"],
            migrationBaselineMetricIDs: []
        )

        XCTAssertTrue(store.placed.isEmpty)
        XCTAssertFalse(store.isMetricEnabled("missing.metric"))
    }

    func testHiddenOptionalMetricCanBeEnabledAfterRelaunch() {
        let defaults = makeDefaults("EnableOptional")
        saveStored([PlacedWidget(descriptorID: "cursor.usage")], forKey: "layout", in: defaults)
        _ = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertFalse(reloaded.isMetricEnabled("cursor.requests"))

        reloaded.setMetricEnabled("cursor.requests", true)

        XCTAssertTrue(LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
            .isMetricEnabled("cursor.requests"))
    }

    func testNewMetricIsEnabledAfterRetiringOnDemandState() {
        let defaults = makeDefaults("SeedNewExpanded")
        // 신규 metric 출시 이전의 기존 layout + 그 metric을 모르는 저장된 expanded set fixture
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.weekly"], forKey: "layout.expandedMetrics")

        let oldRegistry = WidgetRegistry(
            providers: WidgetRegistry.mock.providers,
            descriptors: WidgetRegistry.mock.descriptors.filter { $0.id != "claude.today" }
        )
        _ = LayoutStore(
            registry: oldRegistry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ["claude.session"], migrationBaselineMetricIDs: ["claude.session"]
        )

        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )

        // 기존 숨김을 유지하며 새로 등록된 지표만 기본 켜짐.
        XCTAssertTrue(store.isMetricEnabled("claude.today"))

        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: ["claude.session"]
        )
        XCTAssertTrue(reloaded.isMetricEnabled("claude.today"))
        XCTAssertFalse(reloaded.isMetricEnabled("claude.weekly"))
    }

    func testAddAndResetCancelDragState() {
        let store = makeStore("CancelDrag")
        let first = store.placed[0]

        store.draggingID = first.id
        store.remove(first.id)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.add(first.descriptorID)
        XCTAssertNil(store.draggingID)

        store.draggingID = UUID()
        store.resetToDefault()
        XCTAssertNil(store.draggingID)
    }

    func testAddAndRemoveTogglePlacement() {
        let store = makeStore("Toggle", hiddenMetricIDs: ["cursor.credits"])
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.add("cursor.credits")
        XCTAssertTrue(store.isMetricEnabled("cursor.credits"))

        guard let widget = store.placed.first(where: { $0.descriptorID == "cursor.credits" }) else {
            return XCTFail("missing widget")
        }
        store.remove(widget.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))
    }

    func testTogglingMetricDoesNotChangeCustomizeOrder() {
        let store = makeStore("ToggleKeepsOrder", hiddenMetricIDs: ["cursor.credits"])
        let before = store.orderedSupportedMetrics(for: "cursor").map(\.id)
        XCTAssertFalse(store.isMetricEnabled("cursor.credits"))

        store.setMetricEnabled("cursor.credits", true)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)

        store.setMetricEnabled("cursor.credits", false)
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), before)
    }

    func testFreshCustomizeOrderFollowsProviderDeclarations() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(),
            CodexProvider(),
            DevinProvider(),
            GrokProvider(),
            CursorProvider(),
            ZAIProvider()
        ])
        let store = LayoutStore(registry: registry, defaults: makeDefaults("FreshCustomizeOrder"), storageKey: "layout")

        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "claude").map(\.id),
            [
                "claude.session", "claude.weekly", "claude.fable", "claude.trend", "claude.extra",
                "claude.sonnet", "claude.today", "claude.yesterday", "claude.last30"
            ])
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "codex").map(\.id),
            [
                "codex.session", "codex.weekly", "codex.monthly", "codex.trend", "codex.resetWatch",
                "codex.rateLimitResets", "codex.spark", "codex.sparkWeekly", "codex.sparkMonthly", "codex.credits",
                "codex.today", "codex.yesterday", "codex.last30"
            ])
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "devin").map(\.id),
            [
                "devin.daily", "devin.weekly", "devin.extra"
            ])
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "grok").map(\.id),
            [
                "grok.weekly", "grok.monthly", "grok.payAsYouGo",
                "grok.trend", "grok.today", "grok.yesterday", "grok.last30"
            ])
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "zai").map(\.id),
            [
                "zai.session", "zai.weekly", "zai.monthly", "zai.webSearches"
            ])
        // Cursor spend tile + usage trend 활성 — live meter 뒤에 선언 순서로 배치
        XCTAssertEqual(store.orderedSupportedMetrics(for: "cursor").map(\.id), [
            "cursor.usage", "cursor.auto", "cursor.api", "cursor.onDemand", "cursor.requests",
            "cursor.credits", "cursor.trend", "cursor.today", "cursor.yesterday", "cursor.last30"
        ])
    }

    func testFreshDefaultLayoutEnablesAllProviderMetrics() {
        let registry = WidgetRegistry.from([
            ClaudeProvider(), CodexProvider(), DevinProvider(), GrokProvider(), CursorProvider()
        ])
        let store = LayoutStore(registry: registry, defaults: makeDefaults("AllMetricDefaults"), storageKey: "layout")

        XCTAssertEqual(Set(store.placed.map(\.descriptorID)), Set(registry.descriptors.map(\.id)))
        XCTAssertTrue(store.priorityPinIDs.isEmpty)
        for group in store.customizeGroups {
            XCTAssertEqual(group.metrics.map(\.id), registry.descriptors(for: group.provider.id).map(\.id))
        }
    }

    func testSavedCustomizationWinsOverChangedForkDefaults() throws {
        let defaults = makeDefaults("SavedCustomization")
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        persistence.savePlaced([
            PlacedWidget(descriptorID: "claude.session"),
            PlacedWidget(descriptorID: "claude.weekly")
        ])
        persistence.saveMetricOrder(["claude": ["claude.weekly", "claude.session"]])
        persistence.saveSeededDefaults(Set(DefaultLayout.metricIDs(in: WidgetRegistry.from([ClaudeProvider()]))))
        persistence.savePriorityPins([])

        let store = LayoutStore(
            registry: WidgetRegistry.from([ClaudeProvider()]),
            defaults: defaults,
            storageKey: "layout"
        )

        XCTAssertEqual(store.placed.map(\.descriptorID), ["claude.weekly", "claude.session"])
        XCTAssertEqual(Array(store.orderedSupportedMetrics(for: "claude").map(\.id).prefix(2)), [
            "claude.weekly", "claude.session"
        ])
        XCTAssertTrue(store.priorityPinIDs.isEmpty)
    }

    func testMetricOrderPersistsWhileMetricIsDisabled() {
        let defaults = makeDefaults("DisabledMetricOrder")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"]
        )
        let original = store.orderedSupportedMetrics(for: "claude").map(\.id)
        guard let first = original.first else { return XCTFail("missing Claude metrics") }
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        store.reorderMetric(dragged: "claude.extra", target: first, in: "claude")

        XCTAssertEqual(store.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
        XCTAssertFalse(store.isMetricEnabled("claude.extra"))

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"]
        )
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")

        reloaded.setMetricEnabled("claude.extra", true)
        XCTAssertEqual(reloaded.orderedSupportedMetrics(for: "claude").map(\.id).first, "claude.extra")
    }

    func testFreshStoreStartsWithoutPriorityPins() {
        XCTAssertTrue(makeStore("NoPins").priorityPinIDs.isEmpty)
    }

    func testPriorityPinsPersistAcrossReload() {
        let defaults = makeDefaults("PinsReload")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        store.setMetric("cursor.usage", pinned: true)
        XCTAssertTrue(LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout").isMetricPinned("cursor.usage"))

        store.setMetric("cursor.usage", pinned: false)
        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertTrue(reloaded.priorityPinIDs.isEmpty, "비운 고정은 다시 채우지 않음")
    }

    func testResetToDefaultClearsPriorityPins() {
        let defaults = makeDefaults("ResetPins")
        let persistence = LayoutPersistence(defaults: defaults, storageKey: "layout")
        defaults.set(["claude.session"], forKey: "layout.menuBarPins")
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertEqual(store.migrateMenuBarStars(), 1)
        XCTAssertTrue(store.isMetricPinned("claude.session"))

        store.resetToDefault()

        XCTAssertTrue(store.priorityPinIDs.isEmpty)
        XCTAssertEqual(persistence.loadPins(), ["claude.session"])
        let reloaded = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
        XCTAssertNil(reloaded.migrateMenuBarStars(), "초기화한 고정을 이전 별표로 다시 채우지 않음")
        XCTAssertTrue(reloaded.priorityPinIDs.isEmpty)
    }

    func testProviderReorderMovesAnAbsentAccountCardWithItsFamily() {
        let defaults = makeDefaults("ReorderAbsentAccountCard")
        let storageKey = "layout"
        let hidden = "claude@hidden"
        LayoutPersistence(defaults: defaults, storageKey: storageKey).saveProviderOrder([
            "claude", hidden, "cursor",
        ])
        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: storageKey)

        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        XCTAssertEqual(
            Array(store.providerOrder.prefix(3)),
            ["cursor", "claude", hidden],
            "the family block moves together, so the card returns beside its provider"
        )
        XCTAssertEqual(
            LayoutPersistence(defaults: defaults, storageKey: storageKey).loadProviderOrder()?.contains(hidden),
            true,
            "the absent card keeps its place for the launch it returns on"
        )
    }

    func testALegacyProviderLayoutIsCopiedToItsAccountCard() {
        // 이전 버전의 패밀리 설정 — 첫 실행에 카드마다 같은 선택으로 복사
        let claude = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let work = Provider(id: "claude@work", displayName: "Claude — Work", icon: .providerMark("claude"))
        func descriptor(_ id: String, _ provider: Provider) -> WidgetDescriptor {
            WidgetDescriptor(
                id: id,
                providerID: provider.id,
                metricLabel: id,
                sample: WidgetData(title: id, icon: provider.icon, kind: .percent, used: 0, limit: 100)
            )
        }
        let registry = WidgetRegistry(
            providers: [claude, work],
            descriptors: [
                descriptor("claude.session", claude),
                descriptor("claude.sonnet", claude),
                descriptor("claude@work.session", work),
                descriptor("claude@work.sonnet", work),
            ]
        )
        let defaults = makeDefaults("AccountCardSeeding")
        saveStored([PlacedWidget(descriptorID: "claude.session")], forKey: "layout", in: defaults)
        defaults.set(["claude.session", "claude.sonnet"], forKey: "layout.seededDefaults")

        let store = LayoutStore(
            registry: registry,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session"]
        )

        XCTAssertTrue(store.isMetricEnabled("claude@work.session"))
        XCTAssertFalse(
            store.isMetricEnabled("claude.sonnet"),
            "the family's own disabled default stays exactly as the user left it"
        )
        XCTAssertFalse(
            store.isMetricEnabled("claude@work.sonnet"),
            "the card starts from the family's choice instead of app defaults"
        )
    }

    func testResetToDefaultRestoresProviderOrderAndMarksDefaultsSeeded() {
        let defaults = makeDefaults("ResetSeeded")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertTrue(store.reorderProvider(dragged: "cursor", target: "claude"))

        store.resetToDefault()
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), MockData.providers.map(\.id))
        guard let today = store.placed.first(where: { $0.descriptorID == "claude.today" }) else {
            return XCTFail("reset did not restore current defaults")
        }

        store.remove(today.id)

        let reloaded = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.today"],
            migrationBaselineMetricIDs: []
        )
        XCTAssertEqual(reloaded.placed.map(\.descriptorID), ["claude.session"])
    }

    func testDisplayGroupsFollowTheSingleSavedOrder() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DisplayOrder"),
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "claude.weekly"]
        )
        XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))

        let group = store.displayGroups.first { $0.provider.id == "claude" }
        XCTAssertEqual(group?.widgets.compactMap { store.descriptor(for: $0)?.id }, ["claude.weekly", "claude.session"])
    }

    func testLegacyFoldedOnlyProviderStillShowsRows() {
        let defaults = makeDefaults("FoldedOnly")
        saveStored([PlacedWidget(descriptorID: "claude.session"), PlacedWidget(descriptorID: "claude.weekly")],
                   forKey: "layout", in: defaults)
        defaults.set(["claude.session", "claude.weekly"], forKey: "layout.expandedMetrics")

        let store = LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")

        XCTAssertEqual(store.displayGroups.first { $0.provider.id == "claude" }?.widgets.map(\.descriptorID),
                       ["claude.session", "claude.weekly"])
        XCTAssertNil(defaults.object(forKey: "layout.expandedMetrics"))
    }

    func testResetProviderRestoresOneProviderAndLeavesOthersAndOrderUntouched() {
        let defaults = makeDefaults("ResetOneProvider")
        let store = LayoutStore(
            registry: .mock,
            defaults: defaults,
            storageKey: "layout",
            defaultMetricIDs: ["claude.session", "codex.session"],
            migrationBaselineMetricIDs: [],
            defaultPinnedMetricIDs: ["claude.session", "codex.session"]
        )

        // per-provider reset의 provider 순서 보존 확인용 사전 reorder
        store.reorderProvider(dragged: "cursor", target: "claude")
        let orderBefore = store.customizeGroups.map(\.provider.id)

        // reset이 복원할 모든 차원에서 Claude를 default와 다르게 변경
        store.setMetricEnabled("claude.weekly", true)
        store.setMetric("claude.weekly", pinned: true)
        store.reorderMetric(dragged: "claude.extra", target: "claude.session", in: "claude")

        // Claude reset이 건드리면 안 되는 Codex도 변경
        store.setMetricEnabled("codex.weekly", true)
        store.setMetric("codex.weekly", pinned: true)

        store.resetProvider("claude")

        // Claude 표시·순서 복원, Priority 고정 해제.
        XCTAssertTrue(store.isMetricEnabled("claude.session"))
        XCTAssertFalse(store.isMetricEnabled("claude.weekly"))
        XCTAssertFalse(store.isMetricPinned("claude.session"), "프로바이더 초기화는 Priority 고정을 비움")
        XCTAssertFalse(store.isMetricPinned("claude.weekly"))
        XCTAssertEqual(
            store.orderedSupportedMetrics(for: "claude").map(\.id),
            MockData.descriptors(for: "claude").map(\.id)
        )

        // Codex는 영향 없음
        XCTAssertTrue(store.isMetricEnabled("codex.weekly"))
        XCTAssertTrue(store.isMetricPinned("codex.weekly"))

        // provider 순서 유지 — contents-only reset
        XCTAssertEqual(store.customizeGroups.map(\.provider.id), orderBefore)
    }

    func testResetProviderIsNoOpForUnknownProvider() {
        let store = makeStore("ResetUnknownProvider")
        let before = store.placed.map(\.descriptorID)
        store.resetProvider("nope")
        XCTAssertEqual(store.placed.map(\.descriptorID), before)
    }

    // MARK: - Customize master/detail (L1 list + L2 detail)

    func testCustomizeProviderRowsIncludesAllProvidersRegardlessOfEnablement() {
        // Codex 비활성 시에도 L1 목록에 registry 순서대로 표시(greyed)
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("RowsIncludeDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        XCTAssertEqual(store.customizeProviderRows.map(\.id), MockData.providers.map(\.id))
        let codex = store.customizeProviderRows.first { $0.id == "codex" }
        XCTAssertNotNil(codex, "disabled provider stays visible in L1")
        XCTAssertFalse(codex?.isEnabled ?? true, "disabled provider row reports isEnabled false")
        XCTAssertTrue(store.customizeProviderRows.first { $0.id == "claude" }?.isEnabled ?? false)
    }

    func testCustomizeProviderRowsCarriesMetricCounts() {
        let store = makeStore("RowCounts")
        for row in store.customizeProviderRows {
            XCTAssertEqual(row.metricCount, MockData.descriptors(for: row.id).count)
        }
    }

    func testDisabledProviderStillListsItsMetricsForTheAccountDetail() {
        let store = LayoutStore(
            registry: .mock,
            defaults: makeDefaults("DetailWhenDisabled"),
            storageKey: "layout",
            isProviderEnabled: { id in id != "codex" }
        )
        // customizeGroups는 disabled provider 제외, 지원 지표 목록은 유지
        XCTAssertNil(store.customizeGroups.first { $0.provider.id == "codex" })
        XCTAssertEqual(store.orderedSupportedMetrics(for: "codex").map(\.id), MockData.descriptors(for: "codex").map(\.id))
    }

    func testAccountDetailListsMetricsInTheSavedFlatOrder() {
        let store = makeStore("AccountDetailOrder")
        XCTAssertTrue(store.reorderMetric(dragged: "claude.weekly", target: "claude.session", in: "claude"))

        XCTAssertEqual(
            store.accountSettingsMetrics(for: "claude").map(\.id),
            ["claude.weekly", "claude.session", "claude.extra"]
        )
        XCTAssertEqual(store.sharedSettingsMetrics(for: "claude").map(\.id), ["claude.today"])
    }

    func testAccountDetailHasNoMetricsForUnknownProvider() {
        XCTAssertTrue(makeStore("DetailUnknown").accountSettingsMetrics(for: "nope").isEmpty)
    }

    func testMetricCountMatchesRegistryDescriptors() {
        let store = makeStore("MetricCount")
        for id in MockData.providers.map(\.id) {
            XCTAssertEqual(store.metricCount(for: id), MockData.descriptors(for: id).count)
        }
        XCTAssertEqual(store.metricCount(for: "missing"), 0)
    }

    private func makeStore(_ name: String, hiddenMetricIDs: [String] = []) -> LayoutStore {
        let defaults = makeDefaults(name)
        if !hiddenMetricIDs.isEmpty { defaults.set(hiddenMetricIDs, forKey: "layout.disabledMetrics") }
        return LayoutStore(registry: .mock, defaults: defaults, storageKey: "layout")
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.LayoutStore.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func saveStored<T: Encodable>(_ value: T, forKey key: String, in defaults: UserDefaults) {
        defaults.set(try! JSONEncoder().encode(value), forKey: key)
    }
}
