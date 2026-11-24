import os
import XCTest
@testable import Egasu

@MainActor
final class UsageTimerRouterRevalidationTests: XCTestCase {
    func testScheduledCheckValidityIsRecheckedAfterPreparingProviderWork() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = UsageTimerSetting(defaults: defaults)
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, usageTimerSetting: setting,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        let work = ProviderRefreshWork(queue: BackgroundWorkQueue(), timeout: 3)
        let lease = try XCTUnwrap(work.begin(provider))
        let isCurrent = router.scheduledCheckValidity()
        let result = await work.run(lease, provider: provider, trigger: .weeklyTimerCheck, isCurrent: isCurrent) {
            setting.isEnabled = false
            setting.isEnabled = true
            return true
        }
        work.finish(lease, wakeSchedule: false)

        XCTAssertEqual(provider.refreshCount, 0)
        guard case .cancelled? = result else {
            XCTFail("The revoked check should be cancelled before it calls the provider")
            return
        }
    }

    func testTurningAutomationOffAndOnInvalidatesTheScheduledCheckInFlight() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = UsageTimerSetting(defaults: defaults)
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let first = ProviderStub(observedAt: fixture.clock.current())
        let second = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        second.observation.accountKey = "second"
        let providers: [any ProviderRuntime] = [first, second]
        let router = UsageTimerRouter(
            providers: providers, isProviderEnabled: { _ in true }, usageTimerSetting: setting,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        let dataStore = WidgetDataStore(
            registry: .from(providers), providers: providers, cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { fixture.clock.current() })
        dataStore.onFreshSnapshot = { snapshot, _, trigger in router.receive(snapshot, trigger: trigger) }
        let firstStarted = expectation(description: "First scheduled timer check started")
        var releaseFirst: CheckedContinuation<Void, Never>?
        first.onRefresh = {
            await withCheckedContinuation { continuation in
                releaseFirst = continuation
                firstStarted.fulfill()
            }
        }
        let check = Task { await UsageTimerCheckSchedule.checkAccounts(router: router, dataStore: dataStore) }
        await fulfillment(of: [firstStarted], timeout: 3)
        let release = try XCTUnwrap(releaseFirst)
        first.onRefresh = nil
        setting.isEnabled = false
        setting.isEnabled = true
        release.resume()
        await check.value
        let ids: Set<String> = [first.provider.id, second.provider.id]
        await router.waitForPendingWork(providerIDs: ids)
        XCTAssertEqual(second.refreshCount, 0)
        XCTAssertNil(dataStore.snapshots[first.provider.id])
        XCTAssertEqual([first.sendCount, second.sendCount], [0, 0])

        fixture.clock.advance(.seconds(1))
        first.observation.observedAt = fixture.clock.current()
        let manual = await dataStore.refresh(providerID: first.provider.id, force: true, trigger: .manual)
        XCTAssertEqual(manual, .refreshed)
        await router.waitForPendingWork(providerIDs: ids)
        XCTAssertEqual(first.sendCount, 1)
        await router.shutdown()
    }

    func testGlobalSettingDefaultsOnAndAppliesToExistingAndNewAccountsAfterRestart() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let original = UsageTimerSetting(defaults: defaults)
        XCTAssertTrue(original.isEnabled)
        original.isEnabled = false
        let restored = UsageTimerSetting(defaults: defaults)
        XCTAssertFalse(restored.isEnabled)

        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let first = ProviderStub(observedAt: fixture.clock.current())
        let second = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        second.observation.accountKey = "second"
        let router = UsageTimerRouter(
            providers: [first], isProviderEnabled: { _ in true }, usageTimerSetting: restored,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        router.reconfigure(providers: [first, second])
        let ids: Set<String> = [first.provider.id, second.provider.id]
        XCTAssertTrue(router.requestScheduledCheck().isEmpty)
        let providers: [any ProviderRuntime] = [first, second]
        let dataStore = WidgetDataStore(
            registry: .from(providers), providers: providers, cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { fixture.clock.current() })
        dataStore.onFreshSnapshot = { snapshot, _, trigger in router.receive(snapshot, trigger: trigger) }
        let manual = await dataStore.refresh(providerID: first.provider.id, force: true, trigger: .manual)
        let scheduled = await dataStore.refresh(providerID: second.provider.id, force: true, trigger: .scheduled)
        XCTAssertEqual(manual, .refreshed)
        XCTAssertEqual(scheduled, .refreshed)
        XCTAssertEqual(Set(dataStore.snapshots.keys), ids)
        await router.waitForPendingWork(providerIDs: ids)
        XCTAssertEqual([first.sendCount, second.sendCount], [0, 0])

        restored.isEnabled = true
        XCTAssertTrue(UsageTimerSetting(defaults: defaults).isEnabled)
        XCTAssertEqual(Set(router.requestScheduledCheck()), ids)
        fixture.clock.advance(.seconds(1))
        for provider in [first, second] {
            provider.observation.observedAt = fixture.clock.current()
            router.receive(await provider.refresh(), trigger: .manual)
        }
        await router.waitForPendingWork(providerIDs: ids)
        XCTAssertEqual([first.sendCount, second.sendCount], [1, 1])
        await router.shutdown()
    }

    func testTurningGlobalSettingOffAndOnDropsPreparingAndQueuedMessages() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = UsageTimerSetting(defaults: defaults)
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let first = ProviderStub(observedAt: fixture.clock.current())
        let second = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        second.observation.accountKey = "second"
        let preparing = expectation(description: "First account is preparing a message")
        var releasePreparation: CheckedContinuation<Void, Never>?
        first.onPrepare = {
            await withCheckedContinuation { continuation in
                releasePreparation = continuation
                preparing.fulfill()
            }
        }
        let router = UsageTimerRouter(
            providers: [first, second], isProviderEnabled: { _ in true }, usageTimerSetting: setting,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        router.receive(await first.refresh(), trigger: .manual)
        await fulfillment(of: [preparing], timeout: 3)
        router.receive(await second.refresh(), trigger: .scheduled)
        setting.isEnabled = false
        setting.isEnabled = true
        try XCTUnwrap(releasePreparation).resume()
        await router.waitForPendingWork(providerIDs: [first.provider.id, second.provider.id])

        XCTAssertEqual([first.sendCount, second.sendCount], [0, 0])
        await router.shutdown()
    }

    func testTurningGlobalSettingOffAndOnAfterFinalLaunchCheckPreventsChildProcess() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = UsageTimerSetting(defaults: defaults)
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let marker = fixture.root.appendingPathComponent("child-started")
        let request = StreamingProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path],
            environment: [:], timeout: 3, outputLimit: 256)
        let launchCount = OSAllocatedUnfairLock(initialState: 0)
        let checked = expectation(description: "Last launch check passed")
        var releaseSpawn: CheckedContinuation<Void, Never>?
        provider.sendAfterCheck = {
            await withCheckedContinuation { continuation in
                releaseSpawn = continuation
                checked.fulfill()
            }
            do {
                _ = try await StreamingProcessRunner().run(
                    request, onLaunch: { launchCount.withLock { $0 += 1 } }, onOutput: { _ in })
                XCTFail("A revoked timer reached the native process launch")
            } catch {
                XCTAssertTrue(error is CancellationError, "Unexpected process error: \(error)")
            }
            return .init(launched: false, completed: false)
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, usageTimerSetting: setting,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [checked], timeout: 3)
        setting.isEnabled = false
        setting.isEnabled = true
        try XCTUnwrap(releaseSpawn).resume()
        await router.waitForPendingWork(providerIDs: [provider.provider.id])

        XCTAssertEqual(launchCount.withLock { $0 }, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        await router.shutdown()
    }

    func testTurningGlobalSettingOffAfterChildLaunchRetainsCompletedAttempt() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = UsageTimerSetting(defaults: defaults)
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let ready = fixture.root.appendingPathComponent("ready")
        let release = fixture.root.appendingPathComponent("release")
        provider.sendAfterCheck = {
            let request = StreamingProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: [
                    "-c", #"echo $$ > "$1"; while [ ! -e "$2" ]; do /bin/sleep 0.02; done"#,
                    "timer-child", ready.path, release.path
                ],
                environment: [:], timeout: 8, outputLimit: 256)
            do {
                let result = try await StreamingProcessRunner().run(request)
                XCTAssertEqual(result.exitCode, 0)
                return .init(launched: true, completed: result.exitCode == 0)
            } catch {
                XCTFail("Unexpected process error: \(error)")
                return .init(launched: false, completed: false)
            }
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, usageTimerSetting: setting,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        router.receive(await provider.refresh(), trigger: .manual)
        let deadline = ContinuousClock.now + .seconds(4)
        var pid: pid_t?
        while pid == nil, ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: ready, encoding: .utf8)).flatMap {
                pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            if pid == nil { try await Task.sleep(for: .milliseconds(10)) }
        }
        let child = try XCTUnwrap(pid)
        setting.isEnabled = false
        setting.isEnabled = true
        XCTAssertEqual(kill(child, 0), 0)
        try Data().write(to: release)
        await router.waitForPendingWork(providerIDs: [provider.provider.id])

        let restored = UsageTimerAttemptStore(fileURL: fixture.store.fileURL)
        let attempt = try XCTUnwrap(restored.attempt(for: provider.observation.storageKey))
        XCTAssertEqual(attempt.messageLaunched, true)
        XCTAssertEqual(attempt.execution, .completed)
        XCTAssertEqual(provider.sendCount, 1)
        await router.shutdown()
    }

    func testDisablingAutomationKeepsAnActiveTaskRelatedToTheSameAccount() async throws {
        let suite = "UsageTimerSettingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let setting = UsageTimerSetting(defaults: defaults)
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let primary = ProviderStub(observedAt: fixture.clock.current())
        primary.observation.usedPercent = 10
        let siblingID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "sibling")
        let sibling = ProviderStub(observedAt: fixture.clock.current(), providerID: siblingID)
        let executing = expectation(description: "The sibling account is executing")
        var finishSend: CheckedContinuation<Void, Never>?
        sibling.sendAfterCheck = {
            await withCheckedContinuation { continuation in
                finishSend = continuation
                executing.fulfill()
            }
            return .init(launched: true, completed: true)
        }
        let router = UsageTimerRouter(
            providers: [primary, sibling], isProviderEnabled: { _ in true }, usageTimerSetting: setting,
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() })
        router.receive(await primary.refresh(), trigger: .manual)
        fixture.clock.advance(.seconds(1))
        sibling.observation.observedAt = fixture.clock.current()
        router.receive(await sibling.refresh(), trigger: .manual)
        await fulfillment(of: [executing], timeout: 3)
        let release = try XCTUnwrap(finishSend)

        let switchingIDs: Set<String> = [primary.provider.id]
        XCTAssertTrue(router.hasPendingWork(providerIDs: switchingIDs))
        XCTAssertTrue(router.isRunning(providerID: primary.provider.id))
        setting.isEnabled = false
        XCTAssertTrue(router.hasPendingWork(providerIDs: switchingIDs))
        XCTAssertTrue(router.isRunning(providerID: primary.provider.id))
        setting.isEnabled = true
        XCTAssertTrue(router.hasPendingWork(providerIDs: switchingIDs))
        XCTAssertTrue(router.isRunning(providerID: primary.provider.id))

        release.resume()
        await router.waitForPendingWork(providerIDs: switchingIDs)
        XCTAssertFalse(router.hasPendingWork(providerIDs: switchingIDs))
        XCTAssertFalse(router.isRunning(providerID: primary.provider.id))
        XCTAssertEqual(sibling.sendCount, 1)
        await router.shutdown()
    }

    func testInvalidatedBindingNeverEntersSessionSendAfterWaitingForExecutionQueue() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let queue = BackgroundWorkQueue()
        let previousSend = fixture.clock.current().addingTimeInterval(-600)
        let observation = provider.observation
        XCTAssertNotNil(
            try fixture.store.begin(accountKey: observation.storageKey, resetBefore: nil, now: previousSend))
        let blocked = expectation(description: "Execution queue blocked after preparation")
        var ticket: BackgroundWorkQueue.Ticket?
        provider.onPrepare = {
            Task {
                ticket = await queue.acquire("unrelated-work")
                blocked.fulfill()
            }
            while queue.pendingCount == 0 { await Task.yield() }
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true },
            executor: fixture.executor(), store: fixture.store,
            report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() }, workQueue: queue
        )
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [blocked], timeout: 3)
        while queue.pendingCount == 0 { await Task.yield() }

        router.reconfigure(providers: [])
        queue.finish(try XCTUnwrap(ticket))
        await router.waitForPendingWork(providerIDs: [provider.provider.id])

        XCTAssertEqual(provider.sendCount, 0)
        let restarted = UsageTimerAttemptStore(fileURL: fixture.store.fileURL)
        XCTAssertEqual(
            try restarted.sendLimitResetsAt(
                accountKey: observation.storageKey, now: fixture.clock.current(),
                budgetWindow: observation.budgetWindow),
            previousSend.addingTimeInterval(observation.budgetWindow))
        XCTAssertFalse(router.hasPendingWork)
        await router.shutdown()
    }

    func testUnrelatedAccountCatalogRebuildKeepsPendingNonAccountTimerBinding() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        let replacement = ProviderStub(observedAt: fixture.clock.current(), providerID: "zai")
        let queue = BackgroundWorkQueue()
        let blocked = expectation(description: "Prepared timer is queued")
        var ticket: BackgroundWorkQueue.Ticket?
        provider.onPrepare = {
            Task { ticket = await queue.acquire("unrelated-work"); blocked.fulfill() }
            while queue.pendingCount == 0 { await Task.yield() }
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, executor: fixture.executor(), store: fixture.store,
            report: { _, _ in }, refresh: { _, _ in }, now: { fixture.clock.current() }, workQueue: queue)
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [blocked], timeout: 3)
        while queue.pendingCount == 0 { await Task.yield() }

        router.reconfigure(providers: [replacement])
        queue.finish(try XCTUnwrap(ticket))
        await router.waitForPendingWork(providerIDs: ["zai"])

        XCTAssertEqual(provider.sendCount, 1)
        XCTAssertEqual(replacement.sendCount, 0)
        await router.shutdown()
    }

    func testTimerAcceptsTheVerifiedTimestampFromTheSnapshot() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let time = fixture.clock.current()
        let provider = ProviderStub(observedAt: time, providerID: "antigravity")
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true }, executor: fixture.executor(),
            store: fixture.store, report: { _, _ in }, refresh: { _, _ in }, now: { fixture.clock.current() })
        var snapshot = await provider.refresh()
        snapshot.liveQuotaObservedAt = time.addingTimeInterval(-60)
        snapshot.usageTimerObservedAt = time.addingTimeInterval(-30)

        router.receive(snapshot, trigger: .manual)
        await router.waitForPendingWork(providerIDs: [provider.provider.id])
        XCTAssertEqual(provider.sendCount, 0)

        snapshot.usageTimerObservedAt = time
        router.receive(snapshot, trigger: .manual)
        await router.waitForPendingWork(providerIDs: [provider.provider.id])
        XCTAssertEqual(provider.sendCount, 1)
        await router.shutdown()
    }

    func testStateReadFailurePreservesExistingTimerWarningAndRecoveryClearsOnlyStateWarning() async throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let finished = expectation(description: "Timer failure reported")
        var warnings: [String]?
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true },
            executor: fixture.executor(), store: fixture.store,
            report: { _, messages in warnings = messages }, refresh: { _, _ in finished.fulfill() },
            now: { fixture.clock.current() }
        )
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [finished], timeout: 3)
        XCTAssertEqual(warnings, [ProviderStub.sendFailure])
        let saved = try Data(contentsOf: fixture.store.fileURL)

        try Data("invalid-state".utf8).write(to: fixture.store.fileURL)
        fixture.clock.advance(.seconds(1))
        provider.observation.observedAt = fixture.clock.current()
        router.receive(await provider.refresh(), trigger: .manual)
        XCTAssertEqual(
            Set(warnings ?? []),
            [
                ProviderStub.sendFailure,
                "Usage timer automation could not read its saved state. No message was sent."
            ])

        try saved.write(to: fixture.store.fileURL)
        fixture.clock.advance(.seconds(1))
        provider.observation.observedAt = fixture.clock.current()
        router.receive(await provider.refresh(), trigger: .manual)
        XCTAssertEqual(warnings, [ProviderStub.sendFailure])
        XCTAssertEqual(provider.sendCount, 1)
        await router.shutdown()
    }

    func testCodexStartupWarningUsesProviderTypeAfterBindingInvalidation() throws {
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let account = try fixture.account("first", cardID: "custom-codex-card")
        let executor = fixture.executor()
        executor.startupFailureDescription = "Temporary credentials could not be removed."
        var warning: [String]?
        let router = UsageTimerRouter(
            providers: [account.provider], isProviderEnabled: { _ in true },
            executor: executor, store: fixture.store,
            report: { _, messages in warning = messages }, refresh: { _, _ in }
        )

        router.invalidate(providerIDs: [account.provider.provider.id])

        XCTAssertEqual(warning, [try XCTUnwrap(executor.startupFailureDescription)])
        XCTAssertTrue(executor.auths.isEmpty)
    }

    final class ProviderStub: UsageTimerProviding {
        static let sendFailure = "Usage timer message could not be prepared. Refresh to try again."
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor] = []
        var observation: UsageTimerObservation
        var onRefresh: (() async -> Void)?
        var onPrepare: (() async -> Void)?
        var sendAfterCheck: (() async -> UsageTimerExecutionResult)?
        private(set) var sendCount = 0
        private(set) var verifyCount = 0
        private(set) var prepareCount = 0
        private(set) var refreshCount = 0
        var usageTimerObservations: [UsageTimerObservation] { [observation] }

        init(observedAt: Date, providerID: String = "codex") {
            provider = CodexProvider.makeProvider(id: providerID)
            observation = .init(
                accountKey: "account", usedPercent: 0, resetsAt: nil, observedAt: observedAt,
                timerID: "test.session", duration: 18_000, startRule: .missingReset
            )
        }

        func refresh() async -> ProviderSnapshot {
            refreshCount += 1
            await onRefresh?()
            return .init(
                providerID: provider.id, displayName: provider.displayName, lines: [],
                liveQuotaObservedAt: observation.observedAt)
        }

        func hasLocalCredentials() async -> Bool { false }

        func prepareUsageTimer(
            _ observation: UsageTimerObservation, executors: UsageTimerExecutors
        ) async throws -> UsageTimerSession? {
            prepareCount += 1
            await onPrepare?()
            return UsageTimerSession(
                observation: observation,
                send: { [self] canLaunch in
                    sendCount += 1
                    if let sendAfterCheck {
                        guard await canLaunch() else { return .init(launched: false, completed: false) }
                        return await sendAfterCheck()
                    }
                    return .init(launched: false, completed: false, failureDescription: Self.sendFailure)
                },
                verify: { [self] in
                    verifyCount += 1
                    return nil
                }
            )
        }
    }
}
