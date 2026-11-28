import XCTest
@testable import Egasu

extension UsageTimerRouterRevalidationTests {
    func testDisablingProviderAfterFinalLaunchCheckPreventsChildProcess() async throws {
        try await checkLaunchInvalidation(.disableExecutingCard, expectsLaunch: false)
    }

    func testClockChangeAfterFinalLaunchCheckPreventsChildProcess() async throws {
        try await checkLaunchInvalidation(.changeClock, expectsLaunch: false)
    }

    func testDisablingUnrelatedCardAfterFinalLaunchCheckAllowsChildProcess() async throws {
        try await checkLaunchInvalidation(.disableOtherCard(sameAccount: false), expectsLaunch: true)
    }

    func testDisablingAliasAfterFinalLaunchCheckAllowsChildProcess() async throws {
        try await checkLaunchInvalidation(.disableOtherCard(sameAccount: true), expectsLaunch: true)
    }

    func testNewUsageAfterFinalLaunchCheckPreventsChildProcess() async throws {
        try await checkLaunchInvalidation(.receiveSameCard(stale: false), expectsLaunch: false)
    }

    func testUsageWriteFailureAfterFinalLaunchCheckPreventsChildProcess() async throws {
        try await checkLaunchInvalidation(.receiveSameCard(stale: false, writeFails: true), expectsLaunch: false)
    }

    func testNewAliasUsageAfterFinalLaunchCheckPreventsChildProcess() async throws {
        try await checkLaunchInvalidation(.receiveOtherCard(sameAccount: true, sameTimer: true), expectsLaunch: false)
    }

    func testUnrelatedOrStaleUsageAfterFinalLaunchCheckAllowsChildProcess() async throws {
        try await checkLaunchInvalidation(.receiveSameCard(stale: true), expectsLaunch: true)
        try await checkLaunchInvalidation(.receiveOtherCard(sameAccount: true, sameTimer: false), expectsLaunch: true)
        try await checkLaunchInvalidation(.receiveOtherCard(sameAccount: false, sameTimer: true), expectsLaunch: true)
    }

    func testNewUsageAfterChildLaunchStillVerifiesTheSentMessage() async throws {
        let suite = "UsageTimerLaunchVerificationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let release = fixture.root.appendingPathComponent("release")
        let launched = expectation(description: "Timer child started")
        provider.sendAfterCheck = {
            let request = StreamingProcessRequest(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", #"while [ ! -e "$1" ]; do /bin/sleep 0.02; done"#, "timer-child", release.path],
                environment: [:], timeout: 8, outputLimit: 256)
            do {
                let result = try await StreamingProcessRunner().run(
                    request, onLaunch: { launched.fulfill() }, onOutput: { _ in })
                return .init(launched: true, completed: result.exitCode == 0)
            } catch {
                XCTFail("Unexpected process error: \(error)")
                return .init(launched: false, completed: false)
            }
        }
        let router = UsageTimerRouter(
            providers: [provider], isProviderEnabled: { _ in true },
            usageTimerSetting: UsageTimerSetting(defaults: defaults),
            executor: fixture.executor(), store: fixture.store, report: { _, _ in }, refresh: { _, _ in },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) })
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [launched], timeout: 3)
        fixture.clock.advance(.seconds(1))
        provider.observation.observedAt = fixture.clock.current()
        provider.observation.usedPercent = 10
        router.receive(await provider.refresh(), trigger: .manual)
        try Data().write(to: release)
        await router.waitForPendingWork(providerIDs: [provider.provider.id])

        let attempt = try XCTUnwrap(fixture.store.attempt(for: provider.observation.storageKey))
        XCTAssertEqual(attempt.messageLaunched, true)
        XCTAssertEqual(attempt.execution, .completed)
        XCTAssertGreaterThan(provider.verifyCount, 0)
        await router.shutdown()
    }

    private enum LaunchChange {
        case disableExecutingCard
        case changeClock
        case disableOtherCard(sameAccount: Bool)
        case receiveSameCard(stale: Bool, writeFails: Bool = false)
        case receiveOtherCard(sameAccount: Bool, sameTimer: Bool)
    }

    private func checkLaunchInvalidation(_ change: LaunchChange, expectsLaunch: Bool) async throws {
        let suite = "UsageTimerLaunchInvalidationTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = try UsageTimerRouterTests.Fixture()
        defer { fixture.remove() }
        let provider = ProviderStub(observedAt: fixture.clock.current())
        let accountKey = provider.observation.storageKey
        let previousSend = fixture.clock.current().addingTimeInterval(-600)
        XCTAssertNotNil(try fixture.store.begin(accountKey: accountKey, resetBefore: nil, now: previousSend))
        var providers = [provider]
        switch change {
        case .disableOtherCard(let sameAccount), .receiveOtherCard(let sameAccount, _):
            let otherID = AccountUsageCardPlanner.cardID(family: "codex", profileID: "other")
            let other = ProviderStub(observedAt: fixture.clock.current(), providerID: otherID)
            other.observation.usedPercent = 10
            if !sameAccount { other.observation.accountKey = "another-account" }
            providers.append(other)
        case .disableExecutingCard, .changeClock, .receiveSameCard:
            break
        }

        let marker = fixture.root.appendingPathComponent("child-started")
        let request = StreamingProcessRequest(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"), arguments: [marker.path],
            environment: [:], timeout: 3, outputLimit: 256)
        let checked = expectation(description: "Last launch check passed")
        var releaseSpawn: CheckedContinuation<Void, Never>?
        provider.sendAfterCheck = {
            await withCheckedContinuation { continuation in
                releaseSpawn = continuation
                checked.fulfill()
            }
            do {
                _ = try await StreamingProcessRunner().run(request)
                return .init(launched: true, completed: true)
            } catch {
                XCTAssertTrue(error is CancellationError, "Unexpected process error: \(error)")
                return .init(launched: false, completed: false)
            }
        }

        var enabledIDs = Set(providers.map(\.provider.id))
        var warnings: [String] = []
        let router = UsageTimerRouter(
            providers: providers, isProviderEnabled: { enabledIDs.contains($0) },
            usageTimerSetting: UsageTimerSetting(defaults: defaults),
            executor: fixture.executor(), store: fixture.store,
            report: { _, messages in warnings.append(contentsOf: messages ?? []) }, refresh: { _, _ in },
            now: { fixture.clock.current() }, wait: { fixture.clock.advance($0) })
        if let other = providers.dropFirst().first {
            router.receive(await other.refresh(), trigger: .manual)
            fixture.clock.advance(.seconds(1))
            provider.observation.observedAt = fixture.clock.current()
        }
        let reservedAt = fixture.clock.current()
        let scheduledCheckIsCurrent = router.scheduledCheckValidity()
        router.receive(await provider.refresh(), trigger: .manual)
        await fulfillment(of: [checked], timeout: 3)

        switch change {
        case .disableExecutingCard:
            enabledIDs.remove(provider.provider.id)
            router.invalidate()
        case .changeClock:
            fixture.clock.advance(.seconds(-90))
            NotificationCenter.default.post(name: .NSSystemClockDidChange, object: nil)
        case .disableOtherCard:
            enabledIDs.remove(try XCTUnwrap(providers.dropFirst().first).provider.id)
            router.invalidate()
        case .receiveSameCard(let stale, let writeFails):
            fixture.clock.advance(.seconds(1))
            provider.observation.observedAt = stale ? reservedAt.addingTimeInterval(-1) : fixture.clock.current()
            provider.observation.usedPercent = 10
            let snapshot = await provider.refresh()
            if writeFails {
                let manager = FileManager.default
                let attributes = try manager.attributesOfItem(atPath: fixture.root.path)
                let mode = try XCTUnwrap(attributes[.posixPermissions])
                try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: fixture.root.path)
                defer {
                    XCTAssertNoThrow(
                        try manager.setAttributes([.posixPermissions: mode], ofItemAtPath: fixture.root.path))
                }
                router.receive(snapshot, trigger: .manual)
                XCTAssertEqual(try fixture.store.latestObservationAt(accountKey: accountKey), reservedAt)
                XCTAssertTrue(warnings.contains("Usage timer automation could not update its saved state."))
            } else {
                router.receive(snapshot, trigger: .manual)
            }
        case .receiveOtherCard(_, let sameTimer):
            let other = try XCTUnwrap(providers.dropFirst().first)
            fixture.clock.advance(.seconds(1))
            other.observation.observedAt = fixture.clock.current()
            if !sameTimer { other.observation.timerID = "other.session" }
            router.receive(await other.refresh(), trigger: .manual)
        }
        try XCTUnwrap(releaseSpawn).resume()
        await router.waitForPendingWork(providerIDs: [provider.provider.id])

        XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), expectsLaunch)
        XCTAssertTrue(scheduledCheckIsCurrent())
        let restored = UsageTimerAttemptStore(fileURL: fixture.store.fileURL)
        let attempt = try XCTUnwrap(restored.attempt(for: accountKey))
        XCTAssertEqual(attempt.execution, expectsLaunch ? .completed : .failed)
        XCTAssertEqual(attempt.messageLaunched, expectsLaunch ? true : nil)
        XCTAssertEqual(attempt.notBefore, reservedAt.addingTimeInterval(UsageTimerAttemptStore.retryCooldown))
        let budgetWindow = provider.observation.budgetWindow
        XCTAssertEqual(
            try restored.sendLimitResetsAt(accountKey: accountKey, now: reservedAt, budgetWindow: budgetWindow),
            previousSend.addingTimeInterval(budgetWindow))
        await router.shutdown()
    }
}
