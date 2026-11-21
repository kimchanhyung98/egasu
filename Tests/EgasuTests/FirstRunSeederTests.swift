import XCTest
@testable import Egasu

@MainActor
final class FirstRunSeederTests: XCTestCase {
    func testFreshInstallSeedsFallbackSynchronouslyThenDetectedSet() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("detect"))
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("kimi", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement
        )

        // probe 완료 전: fallback set 동기 반영 — 전체 provider 노출 방지
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
        // 현재 출시 provider 전부 "seen" baseline 처리 — `NewProviderSeeder`는 이후 릴리스 추가분만 probe
        XCTAssertEqual(enablement.knownIDs, ["claude", "codex", "cursor", "grok", "kimi"])

        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testFailedStorageMigrationRetriesBeforeFreshInstallDetection() async throws {
        let domain = "EgasuTests.FirstRunStorage.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let legacy = root.appendingPathComponent("support/OpenUsage")
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data("state".utf8).write(to: legacy.appendingPathComponent("codex-weekly-timer-attempts.json"))
        let target = root.appendingPathComponent("support/egasu")
        try Data("blocked".utf8).write(to: target)
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage"),
            applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: root.appendingPathComponent("config"), defaults: defaults,
            pending: PendingKeychainMigration(defaults: defaults))
        XCTAssertTrue(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain))
        XCTAssertThrowsError(try StorageMigration.runIfNeeded(environment))
        XCTAssertTrue(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain))
        XCTAssertNil(defaults.object(forKey: StorageMigration.configCompletedKey))
        XCTAssertNil(defaults.object(forKey: SettingsMigrator.schemaVersionKey))

        try FileManager.default.removeItem(at: target)
        let captured = SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertFalse(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain))
        SettingsMigrator.migrate(defaults: defaults, domainName: domain, capturedFreshInstall: captured)
        let enablement = ProviderEnablementStore(defaults: defaults)
        XCTAssertNil(enablement.enabledIDs)
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: captured,
            providers: [stub("claude", hasCredentials: false), stub("grok", hasCredentials: true)],
            enablement: enablement)
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
    }

    func testCLIFirstMigrationStillDetectsFreshInstallWithoutRestoringDeletedKey() async throws {
        let domain = "EgasuTests.FirstRunCLI.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(domain)
        defer {
            defaults.removePersistentDomain(forName: domain)
            try? FileManager.default.removeItem(at: root)
        }
        let config = root.appendingPathComponent("config")
        let legacy = config.appendingPathComponent("openusage/openrouter.json")
        try FileManager.default.createDirectory(
            at: legacy.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("key".utf8).write(to: legacy)
        let environment = StorageMigration.Environment(
            namespace: StorageNamespace(bundleIdentifier: "com.kimchanhyung98.openusage"),
            applicationSupportRoot: root.appendingPathComponent("support"),
            configRoot: config, defaults: defaults, pending: PendingKeychainMigration(defaults: defaults))
        try StorageMigration.runForCLI(environment)
        let target = config.appendingPathComponent("egasu/openrouter.json")
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "key")
        XCTAssertTrue(defaults.bool(forKey: StorageMigration.configCompletedKey))
        let provider = stub("grok", hasCredentials: true)
        _ = try await UsageReader(userDefaults: defaults, providers: [provider]).read(providerID: "grok", force: true)
        XCTAssertNotNil(ProviderSnapshotCache(userDefaults: defaults).loadSnapshots(providerIDs: ["grok"])["grok"])
        ProviderAccountsStore(defaults: defaults).reconcile(with: [
            .init(family: "claude", identityKey: "fixture-account", label: nil, sources: [])
        ])
        defaults.set("fixture-org", forKey: CopilotProvider.billingOrgDefaultsKey)
        defaults.set(Data(), forKey: "openusage.providerSnapshots.v9")
        XCTAssertTrue(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain))
        defaults.set("existing", forKey: "openusage.layout.v1")
        XCTAssertFalse(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain))
        defaults.removeObject(forKey: "openusage.layout.v1")
        try FileManager.default.removeItem(at: target)
        try StorageMigration.runForCLI(environment)
        let captured = SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain)
        XCTAssertTrue(try StorageMigration.runIfNeeded(environment))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        SettingsMigrator.migrate(defaults: defaults, domainName: domain, capturedFreshInstall: captured)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: captured,
            providers: [stub("claude", hasCredentials: false), stub("grok", hasCredentials: true)],
            enablement: enablement)
        XCTAssertNotNil(task)
        await task?.value
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
        XCTAssertFalse(SettingsMigrator.isFreshInstall(defaults: defaults, domainName: domain))
    }

    func testNothingDetectedKeepsClaudeAndCodexFallback() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("none"))
        let providers = ["claude", "codex", "kimi", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement
        )
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
    }

    func testExistingInstallIsNeverSeeded() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("existing"))

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: false, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertNil(enablement.enabledIDs, "an existing install keeps legacy all-on semantics")
        XCTAssertTrue(enablement.isEnabled("grok"))
    }

    func testAlreadySeededStoreIsNotReseeded() {
        // unbundled `swift run`은 매 launch fresh 판정 — enabled-list guard로 재seed 방지
        let defaults = makeDefaults("idempotent")
        let enablement = ProviderEnablementStore(defaults: defaults)
        enablement.seedEnabledProviders(["grok"])

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: [stub("claude", hasCredentials: true)],
            enablement: enablement
        )

        XCTAssertNil(task)
        XCTAssertEqual(enablement.enabledIDs, ["grok"])
    }

    func testUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("toggle-wins"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("kimi", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers,
            enablement: enablement
        )
        // probe 진행 중 사용자 toggle — 사용자 선택 우선
        enablement.setEnabled(false, for: "codex")
        await task?.value

        XCTAssertEqual(enablement.enabledIDs, ["claude"])
    }

    // MARK: - Reset All reseed

    func testReseedOverwritesCurrentChoicesWithDetectedSet() async {
        // Reset All은 재검지 후 설치된 set으로 교체 — credential 없는 기존 활성 provider도 off
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed"))
        enablement.seedEnabledProviders(["codex", "grok"])
        let providers = [
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: false),
            stub("cursor", hasCredentials: false),
            stub("kimi", hasCredentials: false),
            stub("grok", hasCredentials: true)
        ]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)

        // fallback으로 동기 전환 — dashboard에 reset 즉시 반영
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])

        await task.value
        XCTAssertEqual(enablement.enabledIDs, ["claude", "grok"])
    }

    func testReseedKeepsClaudeAndCodexFallbackWhenNothingDetected() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-none"))
        enablement.seedEnabledProviders(["grok"])
        let providers = ["claude", "codex", "kimi", "grok"].map { stub($0, hasCredentials: false) }

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
    }

    func testReseedUserToggleDuringDetectionWins() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("reseed-toggle"))
        let providers = [stub("claude", hasCredentials: true), stub("codex", hasCredentials: false),
                         stub("kimi", hasCredentials: false), stub("devin", hasCredentials: true)]

        let task = FirstRunSeeder.reseed(providers: providers, enablement: enablement)
        // probe 진행 중 사용자 toggle — 사용자 선택 우선
        enablement.setEnabled(false, for: "codex")
        await task.value

        XCTAssertEqual(enablement.enabledIDs, ["claude"])
    }

    // MARK: - Sequential detection

    func testCancelledDetectionKeepsFallbackInsteadOfPartialResult() async {
        let enablement = ProviderEnablementStore(defaults: makeDefaults("cancelled"))
        let first = expectation(description: "First probe started")
        let gate = ProbeGate(onFirst: { first.fulfill() })
        let providers: [ProviderRuntime] = [
            GatedCredentialProvider(id: "cursor", gate: gate),
            stub("claude", hasCredentials: true),
            stub("codex", hasCredentials: true)
        ]
        let task = FirstRunSeeder.seedIfNeeded(
            isFreshInstall: true, providers: providers, enablement: enablement
        )
        await fulfillment(of: [first], timeout: 2)
        task?.cancel()
        gate.releaseFirst()
        await task?.value

        XCTAssertEqual(gate.arrivals, ["cursor"])
        XCTAssertEqual(enablement.enabledIDs, ["claude", "codex"])
        XCTAssertTrue(enablement.isInitialDetectionPending)
    }

    func testCancelledFirstDetectionRetriesAfterRelaunchWithoutRepeatingNewProviderDetection() async throws {
        for changedSelection in [false, true] {
            let defaults = makeDefaults("cancel-retry-\(changedSelection)")
            let enablement = ProviderEnablementStore(defaults: defaults)
            let queue = BackgroundWorkQueue()
            let acquired = await queue.acquire("test:block-first-detection")
            let ticket = try XCTUnwrap(acquired)
            let providers = [stub("claude", hasCredentials: false), stub("codex", hasCredentials: false),
                             stub("cursor", hasCredentials: true)]
            let first = try XCTUnwrap(FirstRunSeeder.seedIfNeeded(
                isFreshInstall: true, providers: providers, enablement: enablement,
                workQueue: queue
            ))
            XCTAssertTrue(enablement.isInitialDetectionPending)
            XCTAssertNil(NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: enablement))
            if changedSelection { enablement.setEnabled(false, for: "codex") }
            first.cancel()
            await first.value
            queue.finish(ticket)

            let restarted = ProviderEnablementStore(defaults: defaults)
            XCTAssertTrue(restarted.isInitialDetectionPending)
            let retry = try XCTUnwrap(FirstRunSeeder.seedIfNeeded(
                isFreshInstall: false, providers: providers, enablement: restarted,
                workQueue: queue
            ))
            let previousSelection: Set<String> = changedSelection ? ["claude"] : ["claude", "codex"]
            XCTAssertEqual(restarted.enabledIDs, previousSelection)
            XCTAssertNil(NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: restarted))
            await retry.value

            let completed = ProviderEnablementStore(defaults: defaults)
            let expected: Set<String> = changedSelection ? ["claude"] : ["cursor"]
            XCTAssertEqual(completed.enabledIDs, expected)
            XCTAssertFalse(completed.isInitialDetectionPending)
            XCTAssertNil(FirstRunSeeder.seedIfNeeded(
                isFreshInstall: false, providers: providers, enablement: completed,
            ))
            XCTAssertNil(NewProviderSeeder.reconcileIfNeeded(providers: providers, enablement: completed))
        }
    }

    func testDetectLocalProvidersProbesInOrder() async {
        let ids = ["claude", "codex", "cursor", "grok"]
        let first = expectation(description: "First probe started")
        let gate = ProbeGate(onFirst: { first.fulfill() })
        let providers = ids.map { GatedCredentialProvider(id: $0, gate: gate) }
        let task = Task { await FirstRunSeeder.detectLocalProviders(providers) }
        await fulfillment(of: [first], timeout: 2)
        XCTAssertEqual(gate.arrivals, ["claude"])
        gate.releaseFirst()
        let detected = await task.value
        XCTAssertEqual(detected, Set(ids))
        XCTAssertEqual(gate.arrivals, ids)
    }



    // MARK: - Helpers

    private func stub(_ id: String, hasCredentials: Bool) -> CredentialStubProvider {
        CredentialStubProvider(id: id, hasCredentials: hasCredentials)
    }

    private func makeDefaults(_ name: String) -> UserDefaults {
        let suiteName = "EgasuTests.FirstRunSeeder.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}

@MainActor
private final class CredentialStubProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let hasCredentials: Bool

    init(id: String, hasCredentials: Bool) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.hasCredentials = hasCredentials
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { hasCredentials }
}

/// 첫 probe를 보류해 뒤의 탐지가 먼저 시작하지 않는지 확인.
@MainActor
private final class GatedCredentialProvider: ProviderRuntime {
    let provider: Provider
    let widgetDescriptors: [WidgetDescriptor] = []
    private let gate: ProbeGate

    init(id: String, gate: ProbeGate) {
        self.provider = Provider(id: id, displayName: id.capitalized, icon: .providerMark(id))
        self.gate = gate
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot.make(provider: provider, plan: nil, lines: [], refreshedAt: Date())
    }

    func hasLocalCredentials() async -> Bool { await gate.arrive(provider.id) }
}

@MainActor
private final class ProbeGate {
    private(set) var arrivals: [String] = []
    private let onFirst: () -> Void
    private var continuation: CheckedContinuation<Bool, Never>?

    init(onFirst: @escaping () -> Void) { self.onFirst = onFirst }

    func arrive(_ id: String) async -> Bool {
        arrivals.append(id)
        guard arrivals.count == 1 else { return true }
        return await withCheckedContinuation {
            continuation = $0
            onFirst()
        }
    }

    func releaseFirst() {
        continuation?.resume(returning: true)
        continuation = nil
    }
}
