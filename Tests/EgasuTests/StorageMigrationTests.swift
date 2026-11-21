import XCTest
@testable import Egasu

@MainActor
final class StorageMigrationTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        try await super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "StorageMigrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suiteName = "EgasuTests.StorageMigration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
        try await super.tearDown()
    }

    // MARK: - Names

    func testProductionUsesEgasuAndOtherBundlesStaySeparate() {
        XCTAssertEqual(StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage").name, "egasu")
        XCTAssertEqual(StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev").name, "egasu.dev")
        XCTAssertTrue(
            StorageNamespace(bundleIdentifier: "com.apple.dt.xctest.tool").name.hasPrefix("egasu.suite."))
        XCTAssertNotEqual(StorageNamespace.current.name, "egasu", "테스트는 실제 운영 저장소를 쓰지 않음")
        XCTAssertEqual(
            AccountCredentialVault.service(
                family: "claude", profileID: "p1",
                namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev")),
            "egasu.dev Account Authentication v1 claude p1"
        )
        XCTAssertEqual(
            AccountCredentialVault.legacyService(family: "claude", profileID: "p1"),
            "OpenUsage Account Authentication v1 claude p1")
    }

    // MARK: - Files

    func testProductionMovesItsFoldersOnceAndLeavesOtherAppsFiles() throws {
        let legacy = try makeLegacyFolder()
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage")

        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))

        let target = root.appendingPathComponent("Application Support/egasu")
        for entry in [
            "AccountSignIn/claude/p1/.claude.json", "log-scan-cache/index.json", "codex-weekly-timer-attempts.json"
        ] {
            XCTAssertTrue(exists(target.appendingPathComponent(entry)), entry)
            XCTAssertFalse(exists(legacy.appendingPathComponent(entry)), "운영은 이동: \(entry)")
        }
        XCTAssertTrue(exists(legacy.appendingPathComponent("com.robinebers.openusage.lock")), "원본 OpenUsage 앱 파일은 그대로")
        XCTAssertTrue(exists(root.appendingPathComponent("config/egasu/openrouter.json")))
        XCTAssertTrue(exists(root.appendingPathComponent("config/openusage/openrouter.json")), "API 키는 복사만")
        XCTAssertFalse(try StorageMigration.runIfNeeded(environment), "완료 뒤에는 다시 확인하지 않음")
    }

    func testWeeklyTimerReservationsRemainEffectiveAfterMigration() throws {
        let legacyURL = root.appendingPathComponent("Application Support/OpenUsage/codex-weekly-timer-attempts.json")
        let legacyStore = UsageTimerAttemptStore(fileURL: legacyURL)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        _ = try XCTUnwrap(legacyStore.begin(accountKey: "fixture", resetBefore: nil, now: now))
        _ = try XCTUnwrap(legacyStore.begin(accountKey: "fixture", resetBefore: nil, now: now.addingTimeInterval(301)))

        XCTAssertTrue(try StorageMigration.runIfNeeded(makeEnvironment(namespace: "com.kimchanhyung98.openusage")))

        let migratedStore = UsageTimerAttemptStore(
            fileURL: root.appendingPathComponent("Application Support/egasu/codex-weekly-timer-attempts.json")
        )
        XCTAssertEqual(try migratedStore.attempt(for: "fixture")?.attemptedAt, now.addingTimeInterval(301))
        XCTAssertFalse(try migratedStore.canAttempt(accountKey: "fixture", now: now.addingTimeInterval(602)))
        XCTAssertEqual(
            try migratedStore.sendLimitResetsAt(accountKey: "fixture", now: now.addingTimeInterval(602)),
            now.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertEqual(
            UsageTimerAttemptStore().fileURL,
            StorageNamespace.current.applicationSupportDirectory()
                .appendingPathComponent("codex-weekly-timer-attempts.json")
        )
    }

    func testDevelopmentBuildCopiesStateAndLeavesProductionDataInPlace() throws {
        let legacy = try makeLegacyFolder()

        try StorageMigration.runIfNeeded(makeEnvironment(namespace: "com.kimchanhyung98.openusage.dev"))

        let target = root.appendingPathComponent("Application Support/egasu.dev")
        XCTAssertTrue(exists(target.appendingPathComponent("AccountSignIn/claude/p1/.claude.json")))
        XCTAssertTrue(exists(legacy.appendingPathComponent("AccountSignIn/claude/p1/.claude.json")), "운영 앱 데이터는 그대로")
        XCTAssertFalse(exists(target.appendingPathComponent("log-scan-cache")), "캐시는 새로 만듦")
    }

    func testRequiredStateFailureStopsBeforeKeychainAndCanRetry() throws {
        let legacy = try makeLegacyFolder()
        try saveRegistry(["registered"])
        let keychain = MigrationKeychain()
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage", keychain: keychain)
        let target = root.appendingPathComponent("Application Support/egasu")
        try write("blocked", to: target)
        XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
        XCTAssertEqual(keychain.readCount, 0)
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.configCompletedKey))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertTrue(exists(legacy.appendingPathComponent("codex-weekly-timer-attempts.json")))
        try FileManager.default.removeItem(at: target)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertTrue(exists(target.appendingPathComponent("codex-weekly-timer-attempts.json")))
    }

    func testCacheFailureContinuesKeychainAndLeavesMigrationIncomplete() throws {
        let legacy = root.appendingPathComponent("Application Support/OpenUsage")
        try write("cache", to: legacy.appendingPathComponent("log-scan-cache/index.json"))
        try write("blocked", to: root.appendingPathComponent("Application Support/egasu"))
        try saveRegistry(["registered"])
        let keychain = MigrationKeychain()
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage", keychain: keychain)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertGreaterThan(keychain.readCount, 0)
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertTrue(defaults.bool(forKey: StorageMigration.configCompletedKey))
        XCTAssertTrue(exists(legacy.appendingPathComponent("log-scan-cache/index.json")))
    }

    func testExistingClaudeRecordWaitsForLegacyLeaseAndKeepsLockInode() async throws {
        for bundleID in ["com.kimchanhyung98.openusage", "com.kimchanhyung98.openusage.dev"] {
            var environment = makeEnvironment(namespace: bundleID)
            environment.applicationSupportRoot = root.appendingPathComponent(environment.namespace.name)
            let legacy = environment.applicationSupportRoot.appendingPathComponent("OpenUsage/claude-usage-state")
            let target = environment.applicationSupportRoot.appendingPathComponent(
                "\(environment.namespace.name)/claude-usage-state")
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var original = ClaudeUsageStateStore.Record()
            original.rateLimited(now: now, retryAfterSeconds: 600)
            try await saveClaudeState(original, account: "account", directory: legacy)
            let lock = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasSuffix(".json.lock") })
            let before = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber)
            let store = ClaudeUsageStateStore(directory: legacy)
            var lease: ClaudeUsageStateStore.Lease? = try await store.acquire(
                accountKey: "account", usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            XCTAssertThrowsError(try StorageMigration.runForCLI(environment))
            XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
            let usage = ClaudeMappedUsage(
                plan: "Pro", lines: [.text(label: "Note", value: "Saved")], quotaObservedAt: now)
            var updated = ClaudeUsageStateStore.Record()
            updated.succeeded(usage, at: now)
            try lease?.save(updated)
            lease = nil
            try StorageMigration.runForCLI(environment)
            let restored = try await loadClaudeState(account: "account", directory: target)
            XCTAssertEqual(restored.lastGood, usage)
            let after = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(before, after)
        }
    }

    func testRelativeConfigSymlinkCopiesContents() throws {
        let directory = root.appendingPathComponent("config/openusage")
        try write("fixture", to: directory.appendingPathComponent("actual.json"))
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("openrouter.json").path, withDestinationPath: "actual.json")
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage")
        try StorageMigration.runForCLI(environment)
        XCTAssertEqual(
            try String(contentsOf: root.appendingPathComponent("config/egasu/openrouter.json"), encoding: .utf8),
            "fixture")
    }

    func testActiveLegacyLeaseStopsMigrationUntilSaved() async throws {
        for bundleID in ["com.kimchanhyung98.openusage", "com.kimchanhyung98.openusage.dev"] {
            var environment = makeEnvironment(namespace: bundleID)
            environment.applicationSupportRoot = root.appendingPathComponent(environment.namespace.name)
            let legacy = environment.applicationSupportRoot.appendingPathComponent("OpenUsage/claude-usage-state")
            let target = environment.applicationSupportRoot.appendingPathComponent(
                "\(environment.namespace.name)/claude-usage-state")
            let store = ClaudeUsageStateStore(directory: legacy)
            var lease: ClaudeUsageStateStore.Lease? = try await store.acquire(
                accountKey: "account", usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
            let lock = try XCTUnwrap(
                FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
                    .first { $0.lastPathComponent.hasSuffix(".json.lock") })
            let before = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber)
            XCTAssertThrowsError(try StorageMigration.runForCLI(environment))
            XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
            var record = ClaudeUsageStateStore.Record()
            record.rateLimited(now: Date(timeIntervalSince1970: 1_800_000_000), retryAfterSeconds: 3600)
            try lease?.save(record)
            lease = nil
            try StorageMigration.runForCLI(environment)
            let migrated = try await loadClaudeState(account: "account", directory: target)
            XCTAssertEqual(migrated.retryAfter, record.retryAfter)
            let after = try XCTUnwrap(
                FileManager.default.attributesOfItem(atPath: lock.path)[.systemFileNumber] as? NSNumber)
            XCTAssertEqual(before, after)
        }
    }

    // MARK: - Keychain

    func testCLIFirstRunCopiesAPIKeysWithoutCompletingAppMigration() throws {
        let legacy = try makeLegacyFolder()
        try write(#"{"apiKey":"zai-test"}"#, to: root.appendingPathComponent("config/openusage/zai.json"))
        try saveRegistry(["registered"])
        let keychain = MigrationKeychain()
        let pending = PendingKeychainMigration(defaults: defaults)
        let environment = makeEnvironment(
            namespace: "com.kimchanhyung98.openusage.dev", keychain: keychain, pending: pending)

        try StorageMigration.runForCLI(environment)

        for name in StorageMigration.configFiles {
            XCTAssertEqual(
                try Data(contentsOf: root.appendingPathComponent("config/egasu.dev/\(name)")),
                try Data(contentsOf: root.appendingPathComponent("config/openusage/\(name)"))
            )
        }
        XCTAssertTrue(exists(legacy.appendingPathComponent("AccountSignIn/claude/p1/.claude.json")))
        XCTAssertFalse(exists(root.appendingPathComponent("Application Support/egasu.dev")))
        XCTAssertFalse(exists(root.appendingPathComponent("config/egasu")))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertTrue(defaults.bool(forKey: StorageMigration.configCompletedKey))
        XCTAssertFalse(pending.contains(family: "codex", profileID: "registered"))
        XCTAssertEqual(keychain.readCount, 0)

        XCTAssertTrue(try StorageMigration.runIfNeeded(environment), "앱 첫 실행의 상태·Keychain 이전은 별도로 유지")
    }

    func testCLIMigrationKeepsExistingKeysAcrossRepeatedAppAndCLIStarts() throws {
        _ = try makeLegacyFolder()
        let target = root.appendingPathComponent("config/egasu/openrouter.json")
        let currentKey = #"{"apiKey":"newer-key"}"#
        try write(currentKey, to: target)
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage")

        try StorageMigration.runForCLI(environment)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        try StorageMigration.runForCLI(environment)

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), currentKey)
        XCTAssertTrue(exists(root.appendingPathComponent("config/openusage/openrouter.json")))
    }

    func testCLIReportsConfigMigrationFailureWithoutMarkingItComplete() throws {
        _ = try makeLegacyFolder()
        try write("not a directory", to: root.appendingPathComponent("config/egasu"))

        XCTAssertThrowsError(try StorageMigration.runForCLI(makeEnvironment(namespace: "com.kimchanhyung98.openusage")))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.configCompletedKey))
        XCTAssertTrue(exists(root.appendingPathComponent("config/openusage/openrouter.json")))
    }

    func testCLILeavesDeletedKeysAbsentAfterCompletedAppMigration() throws {
        _ = try makeLegacyFolder()
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage")
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        let target = root.appendingPathComponent("config/egasu/openrouter.json")
        try FileManager.default.removeItem(at: target)
        defaults.removeObject(forKey: StorageMigration.configCompletedKey)

        try StorageMigration.runForCLI(environment)

        XCTAssertFalse(exists(target), "기존 버전의 전체 이전 완료 표시만 있어도 삭제한 키는 복원하지 않음")
    }

    func testCLIConfigCompletionPreventsLaterAppAndCLIFromRestoringDeletedKeys() throws {
        _ = try makeLegacyFolder()
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage.dev")
        try StorageMigration.runForCLI(environment)
        let target = root.appendingPathComponent("config/egasu.dev/openrouter.json")
        try FileManager.default.removeItem(at: target)

        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        try StorageMigration.runForCLI(environment)

        XCTAssertFalse(exists(target))
        XCTAssertTrue(exists(root.appendingPathComponent("config/openusage/openrouter.json")))
    }

    func testCLIFirstRunKeepsClaudeCooldownAndLastGoodUsageForProductionAndDevelopment() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let usage = ClaudeMappedUsage(
            plan: "Pro", lines: [.text(label: "Note", value: "Saved usage")], quotaObservedAt: now
        )
        var record = ClaudeUsageStateStore.Record()
        record.succeeded(usage, at: now)
        record.rateLimited(now: now, retryAfterSeconds: 3600)
        for bundleID in ["com.kimchanhyung98.openusage", "com.kimchanhyung98.openusage.dev"] {
            var environment = makeEnvironment(namespace: bundleID)
            environment.applicationSupportRoot = root.appendingPathComponent(environment.namespace.name)
            let legacy = environment.applicationSupportRoot.appendingPathComponent("OpenUsage/claude-usage-state")
            let target = environment.applicationSupportRoot
                .appendingPathComponent("\(environment.namespace.name)/claude-usage-state")
            try await saveClaudeState(record, account: "account-a|org-a", directory: legacy)

            try StorageMigration.runForCLI(environment)

            let restored = try await loadClaudeState(account: "account-a|org-a", directory: target)
            XCTAssertEqual(restored.retryAfter, record.retryAfter)
            XCTAssertEqual(restored.consecutiveRateLimits, record.consecutiveRateLimits)
            XCTAssertEqual(restored.lastGood, usage)
            XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
            let legacyFiles = try FileManager.default.contentsOfDirectory(atPath: legacy.path)
            XCTAssertEqual(legacyFiles.contains { $0.hasSuffix(".json") }, !environment.namespace.isProduction)
        }
    }

    func testCLIFirstMigrationPreservesNewClaudeStateAndCarriesOtherAccountsBeforeAppStarts() async throws {
        try await assertClaudeStateMerge(cliFirst: true)
    }

    func testAppFirstMigrationPreservesNewClaudeStateAndCarriesOtherAccounts() async throws {
        try await assertClaudeStateMerge(cliFirst: false)
    }

    func testClaudeStateMigrationFailureStopsCLIAndKeepsAppMigrationRetryable() async throws {
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage")
        let legacy = environment.applicationSupportRoot.appendingPathComponent("OpenUsage/claude-usage-state")
        let target = environment.applicationSupportRoot.appendingPathComponent("egasu/claude-usage-state")
        var record = ClaudeUsageStateStore.Record()
        record.rateLimited(now: Date(timeIntervalSince1970: 1_800_000_000), retryAfterSeconds: 3600)
        try await saveClaudeState(record, account: "account", directory: legacy)
        try write("not a directory", to: target)

        XCTAssertThrowsError(try StorageMigration.runForCLI(environment))
        XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
        XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "not a directory")
        let unchanged = try await loadClaudeState(account: "account", directory: legacy)
        XCTAssertEqual(unchanged.retryAfter, record.retryAfter)

        try FileManager.default.removeItem(at: target)
        try StorageMigration.runForCLI(environment)
        let restored = try await loadClaudeState(account: "account", directory: target)
        XCTAssertEqual(restored.retryAfter, record.retryAfter)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertTrue(defaults.bool(forKey: StorageMigration.completedKey))
    }

    func testReadableSignInsMoveAndOnlyThoseNeedingApprovalWait() throws {
        try saveRegistry(["ready", "locked", "absent"])
        let keychain = MigrationKeychain()
        keychain.values[AccountCredentialVault.legacyService(family: "codex", profileID: "ready")] = entry(
            "ready-token")
        keychain.values[AccountCredentialVault.legacyService(family: "codex", profileID: "locked")] = entry(
            "locked-token")
        keychain.locked = [AccountCredentialVault.legacyService(family: "codex", profileID: "locked")]
        let pending = PendingKeychainMigration(defaults: defaults)
        let namespace = StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage.dev")

        try StorageMigration.runIfNeeded(
            makeEnvironment(namespace: "com.kimchanhyung98.openusage.dev", keychain: keychain, pending: pending))

        XCTAssertEqual(
            keychain.values[AccountCredentialVault.service(family: "codex", profileID: "ready", namespace: namespace)]
                .map(credential), "ready-token")
        XCTAssertNotNil(
            keychain.values[AccountCredentialVault.legacyService(family: "codex", profileID: "ready")], "옛 항목은 지우지 않음")
        XCTAssertFalse(pending.contains(family: "codex", profileID: "ready"))
        XCTAssertFalse(pending.contains(family: "codex", profileID: "absent"), "옮길 것이 없으면 대기 아님")
        XCTAssertTrue(pending.contains(family: "codex", profileID: "locked"), "승인이 필요한 항목만 대기")
        XCTAssertNil(
            keychain.values[AccountCredentialVault.service(family: "codex", profileID: "locked", namespace: namespace)])
    }

    func testAnApprovedReadFinishesAWaitingSignIn() throws {
        let keychain = MigrationKeychain()
        let legacy = AccountCredentialVault.legacyService(family: "codex", profileID: "locked")
        keychain.values[legacy] = entry("locked-token")
        keychain.locked = [legacy]
        let pending = PendingKeychainMigration(defaults: defaults)
        pending.record(family: "codex", profileID: "locked")
        let vault = AccountCredentialVault(keychain: keychain, pendingMigration: pending)

        XCTAssertThrowsError(try vault.load(family: "codex", profileID: "locked"), "자동 새로 고침은 승인 창 없이 실패")
        XCTAssertTrue(pending.contains(family: "codex", profileID: "locked"))

        XCTAssertEqual(
            try vault.load(family: "codex", profileID: "locked", allowInteraction: true)?.credential, "locked-token")
        XCTAssertFalse(pending.contains(family: "codex", profileID: "locked"))
        XCTAssertEqual(
            keychain.values[AccountCredentialVault.service(family: "codex", profileID: "locked")].map(credential),
            "locked-token")
    }

    func testAccountsThatAreNotWaitingNeverReadTheOldName() throws {
        let keychain = MigrationKeychain()
        keychain.values[AccountCredentialVault.legacyService(family: "claude", profileID: "p1")] = entry("old-token")
        let vault = AccountCredentialVault(
            keychain: keychain, pendingMigration: PendingKeychainMigration(defaults: defaults))

        XCTAssertNil(try vault.load(family: "claude", profileID: "p1"), "옮긴 뒤 지운 계정이 옛 토큰으로 되살아나지 않음")
    }

    // MARK: - Helpers

    private func assertClaudeStateMerge(cliFirst: Bool) async throws {
        let environment = makeEnvironment(namespace: "com.kimchanhyung98.openusage")
        let legacy = environment.applicationSupportRoot.appendingPathComponent("OpenUsage/claude-usage-state")
        let target = environment.applicationSupportRoot.appendingPathComponent("egasu/claude-usage-state")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var previous = ClaudeUsageStateStore.Record()
        previous.succeeded(ClaudeMappedUsage(plan: "Pro", lines: [], quotaObservedAt: now), at: now)
        previous.rateLimited(now: now, retryAfterSeconds: 1800)
        try await saveClaudeState(previous, account: "existing", directory: legacy)
        try await saveClaudeState(previous, account: "other-account", directory: legacy)
        var current = ClaudeUsageStateStore.Record()
        current.succeeded(
            ClaudeMappedUsage(plan: "Ultra", lines: [], quotaObservedAt: now.addingTimeInterval(60)),
            at: now.addingTimeInterval(60)
        )
        try await saveClaudeState(current, account: "existing", directory: target)

        if cliFirst {
            try StorageMigration.runForCLI(environment)
            XCTAssertFalse(defaults.bool(forKey: StorageMigration.completedKey))
        } else {
            XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        }

        let retained = try await loadClaudeState(account: "existing", directory: target)
        let carried = try await loadClaudeState(account: "other-account", directory: target)
        XCTAssertEqual(retained.lastGood, current.lastGood)
        XCTAssertNil(retained.retryAfter)
        XCTAssertEqual(carried.lastGood, previous.lastGood)
        XCTAssertEqual(carried.retryAfter, previous.retryAfter)
        if cliFirst {
            XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
            let afterApp = try await loadClaudeState(account: "existing", directory: target)
            XCTAssertEqual(afterApp.lastGood, current.lastGood)
            XCTAssertNil(afterApp.retryAfter)
        }
    }

    private func saveClaudeState(
        _ record: ClaudeUsageStateStore.Record, account: String, directory: URL
    ) async throws {
        let store = ClaudeUsageStateStore(directory: directory)
        let lease = try await store.acquire(
            accountKey: account, usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        )
        try lease.save(record)
    }

    private func loadClaudeState(account: String, directory: URL) async throws -> ClaudeUsageStateStore.Record {
        let store = ClaudeUsageStateStore(directory: directory)
        let lease = try await store.acquire(
            accountKey: account, usageURL: URL(string: "https://api.anthropic.com/api/oauth/usage")!
        )
        return try lease.read()
    }

    private func makeEnvironment(
        namespace bundleIdentifier: String, keychain: KeychainAccessing = MigrationKeychain(),
        pending: PendingKeychainMigration? = nil
    ) -> StorageMigration.Environment {
        StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: bundleIdentifier),
            applicationSupportRoot: root.appendingPathComponent("Application Support"),
            configRoot: root.appendingPathComponent("config"),
            defaults: defaults,
            keychain: keychain,
            pending: pending ?? PendingKeychainMigration(defaults: defaults)
        )
    }

    private func makeLegacyFolder() throws -> URL {
        let legacy = root.appendingPathComponent("Application Support/OpenUsage")
        try write("{}", to: legacy.appendingPathComponent("AccountSignIn/claude/p1/.claude.json"))
        try write("{}", to: legacy.appendingPathComponent("log-scan-cache/index.json"))
        try write("[]", to: legacy.appendingPathComponent("codex-weekly-timer-attempts.json"))
        try write("", to: legacy.appendingPathComponent("com.robinebers.openusage.lock"))
        try write(#"{"apiKey":"sk-or-test"}"#, to: root.appendingPathComponent("config/openusage/openrouter.json"))
        return legacy
    }

    private func saveRegistry(_ ids: [String]) throws {
        let profiles = ids.map {
            AccountProfile(id: $0, family: "codex", label: $0, identityKey: $0, createdAt: Date())
        }
        let data = try JSONEncoder().encode(AccountProfilesStore.Blob(profiles: profiles, preferredByFamily: [:]))
        defaults.set(data, forKey: AccountProfilesStore.storageKey)
    }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    private func entry(_ token: String) -> String {
        String(
            decoding: try! JSONEncoder().encode(
                AccountCredentialVault.Entry(credential: token, claudeOAuthAccount: nil)), as: UTF8.self)
    }

    private func credential(_ stored: String) -> String {
        (try? JSONDecoder().decode(AccountCredentialVault.Entry.self, from: Data(stored.utf8)))?.credential ?? ""
    }
}

/// 서비스 이름별 값 — `locked`는 승인 창 없는 읽기에서 실패(Keychain 승인 대기 재현).
private final class MigrationKeychain: KeychainAccessing, @unchecked Sendable {
    var values: [String: String] = [:]
    var locked: Set<String> = []
    var readCount = 0

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        readCount += 1
        if locked.contains(service), !allowInteraction {
            throw KeychainError.readFailed("Couldn't read the saved account from Keychain (status -25293).")
        }
        return values[service]
    }

    func readGenericPassword(service: String) throws -> String? { values[service] }
    func writeGenericPassword(service: String, value: String) throws { values[service] = value }
    func deleteGenericPassword(service: String) throws { values.removeValue(forKey: service) }
}
