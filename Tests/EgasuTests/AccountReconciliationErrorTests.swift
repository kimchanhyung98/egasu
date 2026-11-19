import XCTest
@testable import Egasu

@MainActor
final class AccountReconciliationErrorTests: XCTestCase {
    func testClaudeKeychainReconciliationFailureOffersPriorityRetryAfterUsageRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let error = KeychainError.readFailed("Fixture Keychain rejection")
        AppContainer.applyExternalClaudeReconciliationError(
            AppContainer.externalClaudeReconciliationFailure(for: error),
            to: fixture.store, accountSwitch: fixture.coordinator,
            startedAt: fixture.coordinator.generation
        )
        var observedQuota = false
        fixture.store.onFreshSnapshot = { _, _, _ in observedQuota = true }
        _ = await fixture.store.refresh(providerID: "claude", force: true)

        XCTAssertTrue(fixture.store.needsKeychainApproval("claude"))
        XCTAssertNotNil(fixture.store.localSnapshots["claude"])
        XCTAssertFalse(observedQuota)
        let provider = Runtime().provider
        let account = DashboardAccount(provider: provider, providerName: "Claude", name: nil, lines: [])
        L10n.withLanguage(.korean) {
            let board = fixture.store.priorityBoard(accounts: [account], pinned: [], now: Date())
            XCTAssertEqual(board.notices.map(\.account.id), ["claude"])
            XCTAssertTrue(board.notices.first?.message.contains("키체인") == true)
        }
    }

    func testCurrentReconciliationErrorIsPublishedAndSuccessfulReconciliationClearsIt() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var invalidations: [Set<String>] = []
        fixture.store.onQuotaInvalidated = { invalidations.append($0 ?? []) }

        AppContainer.applyExternalClaudeReconciliationError(
            ProviderRefreshFailure(message: "Sign-in update failed."), to: fixture.store,
            accountSwitch: fixture.coordinator,
            startedAt: fixture.coordinator.generation
        )

        XCTAssertEqual(fixture.store.errorMessage(for: "claude"), "Sign-in update failed.")
        XCTAssertEqual(
            fixture.store.refreshResults["claude"],
            .failed(ProviderRefreshFailure(message: "Sign-in update failed.")))
        XCTAssertEqual(invalidations, [Set(["claude"])])

        AppContainer.applyExternalClaudeReconciliationError(
            nil, to: fixture.store, accountSwitch: fixture.coordinator,
            startedAt: fixture.coordinator.generation
        )

        XCTAssertNil(fixture.store.errorMessage(for: "claude"))
        XCTAssertEqual(invalidations.count, 1)
    }

    func testReconciliationFailureTranslatesOnlyItsDisplayedMessage() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let raw =
            "egasu couldn't update the selected Claude sign-in. The saved account was left unchanged. Check the app log and try again."
        let failure = AppContainer.externalClaudeReconciliationFailure(
            for: AccountIdentityReplacementError.invalidTransaction)
        XCTAssertEqual(failure.message, raw)
        AppContainer.applyExternalClaudeReconciliationError(
            failure, to: fixture.store, accountSwitch: fixture.coordinator,
            startedAt: fixture.coordinator.generation
        )

        XCTAssertEqual(fixture.store.refreshResults["claude"]?.failure?.message, raw)
        XCTAssertEqual(
            L10n.withLanguage(.korean) { fixture.store.headerNotice(for: "claude") },
            "선택한 Claude 계정의 로그인을 업데이트하지 못했습니다. 저장된 계정은 변경하지 않았습니다. 앱 로그를 확인한 후 다시 시도하세요.")
    }

    func testConcurrentCLILoginChangeAsksForRefreshInsteadOfSigningInAgain() {
        let failure = AppContainer.externalClaudeReconciliationFailure(for: ClaudeAuthError.credentialsChanged)
        XCTAssertEqual(failure.message, "Claude login changed during refresh. Refresh again.")
        for language in [LanguageSetting.english, .korean, .japanese] {
            L10n.withLanguage(language) {
                XCTAssertEqual(
                    failure.localizedMessage, UserFacingErrors.message(ClaudeAuthError.credentialsChanged))
            }
        }
    }

    func testAuthenticationConflictsAndSwitchRecoveryFailuresKeepActionableDashboardErrorPresentation() throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let errors: [any Error] = [
            ClaudeAuthError.rotationInProgress,
            AccountCredentialSwitcher.Error.switchRecoveryRequired,
            AccountCredentialSwitcher.Error.selectionSaveFailed,
            AccountCredentialSwitcher.Error.conflictingClaudeAuthentication
        ]
        for error in errors {
            let failure = AppContainer.externalClaudeReconciliationFailure(for: error)
            AppContainer.applyExternalClaudeReconciliationError(
                failure, to: fixture.store, accountSwitch: fixture.coordinator,
                startedAt: fixture.coordinator.generation
            )

            XCTAssertEqual(fixture.store.refreshResults["claude"]?.failure?.message, error.localizedDescription)
            for language in [LanguageSetting.english, .korean, .japanese] {
                L10n.withLanguage(language) {
                    XCTAssertEqual(fixture.store.headerNotice(for: "claude"), UserFacingErrors.message(error))
                }
            }
        }
    }

    func testReconciliationErrorCannotOverwriteStateWhileSwitchIsReserved() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.store.setExternalProviderError("Current account failure.", for: "claude")
        var invalidations: [Set<String>] = []
        fixture.store.onQuotaInvalidated = { invalidations.append($0 ?? []) }
        let previousGeneration = fixture.coordinator.generation
        let task = try XCTUnwrap(
            fixture.coordinator.start(
                profileID: "target", waitForRefreshes: {}, operation: {},
                onFailure: { XCTFail("Unexpected switch failure: \($0)") }
            ))
        XCTAssertTrue(fixture.coordinator.isSwitching)

        for generation in [previousGeneration, fixture.coordinator.generation] {
            AppContainer.applyExternalClaudeReconciliationError(
                ProviderRefreshFailure(message: "Pre-switch failure."), to: fixture.store,
                accountSwitch: fixture.coordinator,
                startedAt: generation
            )
        }

        XCTAssertEqual(fixture.store.errorMessage(for: "claude"), "Current account failure.")
        XCTAssertTrue(invalidations.isEmpty)
        await task.value
    }

    func testCompletedSwitchDiscardsOldErrorButAcceptsNewRefreshError() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let previousGeneration = fixture.coordinator.generation
        let task = try XCTUnwrap(
            fixture.coordinator.start(
                profileID: "target", waitForRefreshes: {},
                operation: { _ = await fixture.store.refresh(providerID: "claude", force: true) },
                onFailure: { XCTFail("Unexpected switch failure: \($0)") }
            ))
        await task.value
        XCTAssertFalse(fixture.coordinator.isSwitching)
        XCTAssertEqual(fixture.store.refreshResults["claude"], .succeeded)
        let snapshot = try XCTUnwrap(fixture.store.localSnapshots["claude"])
        var invalidations: [Set<String>] = []
        fixture.store.onQuotaInvalidated = { invalidations.append($0 ?? []) }

        AppContainer.applyExternalClaudeReconciliationError(
            ProviderRefreshFailure(message: "Pre-switch failure."), to: fixture.store,
            accountSwitch: fixture.coordinator,
            startedAt: previousGeneration
        )

        XCTAssertNil(fixture.store.errorMessage(for: "claude"))
        XCTAssertEqual(fixture.store.refreshResults["claude"], .succeeded)
        XCTAssertEqual(fixture.store.localSnapshots["claude"], snapshot)
        XCTAssertTrue(invalidations.isEmpty)

        AppContainer.applyExternalClaudeReconciliationError(
            ProviderRefreshFailure(message: "New sign-in failure."), to: fixture.store,
            accountSwitch: fixture.coordinator,
            startedAt: fixture.coordinator.generation
        )

        XCTAssertEqual(fixture.store.errorMessage(for: "claude"), "New sign-in failure.")
        XCTAssertEqual(fixture.store.localSnapshots["claude"], snapshot)
        XCTAssertEqual(invalidations, [Set(["claude"])])
    }

    @MainActor
    private struct Fixture {
        let suite = "EgasuTests.AccountReconciliationError.\(UUID().uuidString)"
        let defaults: UserDefaults
        let store: WidgetDataStore
        let coordinator = AccountSwitchCoordinator()

        init() throws {
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            let runtime = Runtime()
            store = WidgetDataStore(
                registry: .from([runtime]), providers: [runtime],
                cache: ProviderSnapshotCache(userDefaults: defaults), defaults: defaults,
                providerIdentityKeys: ["claude": "account"]
            )
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }

    private final class Runtime: ProviderRuntime {
        let provider = Provider(id: "claude", displayName: "Claude", icon: .providerMark("claude"))
        let widgetDescriptors: [WidgetDescriptor] = []

        func hasLocalCredentials() async -> Bool { true }
        func refresh() async -> ProviderSnapshot {
            ProviderSnapshot(providerID: "claude", displayName: "Claude", lines: [])
        }
    }
}
