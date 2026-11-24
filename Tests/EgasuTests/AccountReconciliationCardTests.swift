import XCTest
@testable import Egasu

@MainActor
final class AccountReconciliationCardTests: XCTestCase {
    func testCombinedRecoveryOfUnmappedProfilePreservesOtherCodexFailure() async throws {
        let fixture = try CodexReSignInRecoveryTests.Fixture()
        defer { fixture.cleanUp() }
        let inactive = try fixture.store.add(family: "codex", label: "Personal", identityKey: "old")
        try fixture.switcher.saveSnapshot(fixture.credential("new", account: "new"), for: inactive)
        _ = try fixture.store.beginIdentityReplacement(
            profileID: inactive.id, with: "new", replacesSharedAuthentication: false)
        let result = try await fixture.importer.reconcileSelectedClaudeSharedAuthenticationAfterStartup(
            in: fixture.store)
        XCTAssertEqual(result, .updated(profileID: inactive.id))
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        let store = WidgetDataStore(
            registry: .from([]), providers: [],
            cache: ProviderSnapshotCache(userDefaults: fixture.defaults), defaults: fixture.defaults)
        let otherFailure = ProviderRefreshFailure(message: "Other Codex failure")
        store.setAccountReconciliationFailure(otherFailure, for: "codex")
        let coordinator = AccountSwitchCoordinator()
        let snapshotID = AccountUsageCardPlanner.cardID(family: "codex", profileID: inactive.id)
        store.setAccountReconciliationFailure(otherFailure, for: snapshotID)
        for nowMapped in [false, true] {
            var mapping = ["codex": fixture.profile.id]
            if nowMapped { mapping[snapshotID] = inactive.id }
            AppContainer.publishAccountReconciliation(
                .success(true), codexRecoveryOnly: false, in: fixture.store, to: store,
                accountSwitch: coordinator, startedAt: coordinator.generation,
                profileIDsByCard: mapping, previousCodexProfileID: inactive.id)
            XCTAssertEqual(store.reconciliationFailure(for: "codex"), otherFailure)
            XCTAssertEqual(store.reconciliationFailure(for: snapshotID), nowMapped ? nil : otherFailure)
        }
    }

    func testInactiveCodexRecoveryFailureInvalidatesOnlyItsSnapshotCard() async throws {
        let fixture = try CodexReSignInRecoveryTests.Fixture()
        defer { fixture.cleanUp() }
        let inactive = try fixture.store.add(family: "codex", label: "Personal", identityKey: "old")
        XCTAssertEqual(fixture.store.preferredProfileID(family: "codex"), fixture.profile.id)
        let snapshotID = AccountUsageCardPlanner.cardID(family: "codex", profileID: inactive.id)
        let providers = ["codex", snapshotID].map { id in
            TestProviderRuntime(
                provider: Provider(id: id, displayName: id, icon: .providerMark("codex")),
                descriptors: [], snapshot: ProviderSnapshot(providerID: id, displayName: id, lines: []))
        }
        let store = WidgetDataStore(
            registry: .from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: fixture.defaults), defaults: fixture.defaults)
        let coordinator = AccountSwitchCoordinator()
        var invalidated: [Set<String>] = []
        store.onQuotaInvalidated = { invalidated.append($0 ?? []) }
        let replacement = fixture.credential("new", account: "new")
        try fixture.switcher.saveSnapshot(replacement, for: inactive)
        _ = try fixture.store.beginIdentityReplacement(
            profileID: inactive.id, with: "new", replacesSharedAuthentication: false)
        let directory = try fixture.workspace.prepare(family: "codex", profileID: inactive.id)
        let blocker = directory.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: blocker, withIntermediateDirectories: false)
        let mapping = ["codex": fixture.profile.id, snapshotID: inactive.id]
        let journal = try fixture.store.pendingIdentityReplacement()
        for (card, retries) in [("codex", false), (snapshotID, true)] {
            XCTAssertEqual(
                AppContainer.shouldRetryCodexReconciliation(
                    for: card, transaction: journal, in: fixture.store, to: store, profileIDsByCard: mapping), retries)
        }
        func publish(_ result: Result<Bool, Error>, cards: [String: String]) {
            AppContainer.publishAccountReconciliation(
                result, codexRecoveryOnly: true, in: fixture.store, to: store,
                accountSwitch: coordinator, startedAt: coordinator.generation, profileIDsByCard: cards,
                codexRetryCardID: snapshotID, previousCodexProfileID: inactive.id)
        }
        do {
            _ = try await fixture.importer.reconcileCodexIdentityReplacementAfterStartup(in: fixture.store)
            XCTFail("Expected a workspace write failure")
        } catch {
            publish(.failure(error), cards: ["codex": fixture.profile.id])
            XCTAssertNotNil(store.accountReconciliationNotice)
            XCTAssertTrue(invalidated.isEmpty)
            publish(.failure(error), cards: mapping)
        }
        XCTAssertNotNil(store.refreshResults[snapshotID]?.failure)
        XCTAssertNil(store.refreshResults["codex"]?.failure)
        XCTAssertEqual(invalidated, [Set([snapshotID])])
        let previousDefault = ProviderRefreshFailure(message: "Existing default failure")
        store.setAccountReconciliationFailure(previousDefault, for: "codex")
        try FileManager.default.removeItem(at: blocker)
        let repaired = try await fixture.importer.reconcileCodexIdentityReplacementAfterStartup(in: fixture.store)
        XCTAssertEqual(repaired, .updated(profileID: inactive.id))
        publish(.success(true), cards: mapping)
        XCTAssertNil(store.refreshResults[snapshotID]?.failure)
        XCTAssertEqual(store.refreshResults["codex"]?.failure, previousDefault)
    }
}
