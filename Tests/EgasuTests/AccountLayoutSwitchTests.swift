import XCTest
@testable import Egasu

@MainActor
final class AccountLayoutSwitchTests: XCTestCase {
    func testMetricSettingsFollowBothProfilesAcrossSwitchAndRelaunch() throws {
        let defaults = makeDefaults()
        let initial = catalog(selected: "personal")
        let layout = makeLayout(defaults: defaults, catalog: initial)
        let workID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "work")
        let personalID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "personal")
        layout.setMetricEnabled("\(workID).weekly", false)
        XCTAssertTrue(layout.reorderMetric(dragged: "\(workID).credits", target: "\(workID).session", in: workID))
        layout.setMetricEnabled("codex.credits", false)
        XCTAssertTrue(layout.reorderProvider(dragged: "cursor", target: "codex"))
        let providerOrder = layout.providerOrder

        let next = catalog(selected: "work")
        layout.replaceRegistry(next.registry, profileIDsByCardID: next.mapping)
        let detailID = "codex"
        XCTAssertEqual(detailID, "codex")
        XCTAssertEqual(next.mapping[detailID], "work")
        XCTAssertNotNil(layout.provider(id: detailID), "전환 후에도 열린 상세가 현재 카탈로그의 계정 표시")
        assertWorkSettings(layout, cardID: detailID)
        XCTAssertFalse(layout.isMetricEnabled("\(personalID).credits"))
        XCTAssertTrue(layout.isMetricEnabled("\(personalID).weekly"))
        XCTAssertEqual(layout.providerOrder, providerOrder, "계정 전환은 프로바이더 순서를 바꾸지 않음")
        XCTAssertFalse(layout.canUndo, "전환 전 카드 ID를 담은 실행 취소는 폐기")

        let relaunched = makeLayout(defaults: defaults, catalog: next)
        assertWorkSettings(relaunched, cardID: "codex")
        relaunched.replaceRegistry(initial.registry, profileIDsByCardID: initial.mapping)
        assertWorkSettings(relaunched, cardID: workID)
        XCTAssertFalse(relaunched.isMetricEnabled("codex.credits"))
    }

    private func assertWorkSettings(
        _ layout: LayoutStore, cardID: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(layout.isMetricEnabled("\(cardID).weekly"), file: file, line: line)
        XCTAssertTrue(layout.isMetricEnabled("\(cardID).credits"), file: file, line: line)
        XCTAssertEqual(
            layout.metricOrder(for: cardID), ["credits", "session", "weekly"].map { "\(cardID).\($0)" }, file: file,
            line: line)
    }

    func testSwitchWhileAppIsClosedKeepsAnAccountsMetricsFullyHidden() {
        let defaults = makeDefaults()
        let initial = makeLayout(defaults: defaults, catalog: catalog(selected: "personal"))
        let workID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "work")
        for descriptor in initial.orderedSupportedMetrics(for: workID) {
            initial.setMetricEnabled(descriptor.id, false)
        }

        let relaunched = makeLayout(defaults: defaults, catalog: catalog(selected: "work"))

        XCTAssertFalse(relaunched.displayGroups.contains { $0.id == "codex" }, "모두 숨긴 계정을 새 카드로 오인해 기본값을 넣지 않음")
        let personalID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "personal")
        XCTAssertEqual(relaunched.displayGroups.first { $0.id == personalID }?.widgets.count, 3)
    }

    func testRebindingTheSameCatalogPreservesUnavailableProfileSettings() {
        let defaults = makeDefaults()
        let personal = catalog(selected: "personal", profileIDs: ["personal"])
        let layout = makeLayout(defaults: defaults, catalog: personal)
        layout.setMetricEnabled("codex.weekly", false)
        let work = catalog(selected: "work", profileIDs: ["work"])
        XCTAssertEqual(personal.registry.providers, work.registry.providers)

        layout.replaceRegistry(work.registry, profileIDsByCardID: work.mapping)

        XCTAssertTrue(layout.isMetricEnabled("codex.weekly"), "새 계정은 이전 활성 계정의 숨김을 물려받지 않음")
        let relaunched = makeLayout(defaults: defaults, catalog: personal)
        XCTAssertFalse(relaunched.isMetricEnabled("codex.weekly"), "복귀한 계정은 보관된 설정 사용")
    }

    private func catalog(selected: String, profileIDs: [String] = ["personal", "work"]) -> (
        registry: WidgetRegistry, mapping: [String: String]
    ) {
        let profiles = profileIDs.map {
            AccountProfile(id: $0, family: "codex", label: $0, identityKey: $0, createdAt: .distantPast)
        }
        let cards = AccountUsageCardPlanner.snapshotCards(
            profiles: profiles, preferredProfileIDs: ["codex": selected],
            availableSnapshotProfileIDs: Set(profileIDs), sharedHomeIdentityKeys: ["codex": selected]
        )
        var mapping = Dictionary(uniqueKeysWithValues: cards.map { ($0.id, $0.profileID) })
        mapping["codex"] = selected
        let providers = (["codex"] + cards.map(\.id) + ["cursor"]).map {
            Provider(id: $0, displayName: $0, icon: .providerMark("codex"))
        }
        let descriptors = providers.flatMap { provider in
            ["session", "weekly", "credits"].map { suffix in
                WidgetDescriptor(
                    id: "\(provider.id).\(suffix)", providerID: provider.id, metricLabel: suffix,
                    sample: WidgetData(title: suffix, icon: provider.icon, kind: .percent, used: 0, limit: 100)
                )
            }
        }
        return (WidgetRegistry(providers: providers, descriptors: descriptors), mapping)
    }

    private func makeLayout(defaults: UserDefaults, catalog: (registry: WidgetRegistry, mapping: [String: String]))
        -> LayoutStore
    {
        LayoutStore(
            registry: catalog.registry, defaults: defaults, storageKey: "layout",
            defaultMetricIDs: ["codex.session", "codex.weekly", "codex.credits"],
            migrationBaselineMetricIDs: ["codex.session", "codex.weekly", "codex.credits"],
            defaultPinnedMetricIDs: [], profileIDsByCardID: catalog.mapping
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "EgasuTests.AccountLayoutSwitch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
