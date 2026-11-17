import XCTest
import UserNotifications
@testable import Egasu

@MainActor
final class QuotaNotificationCancellationTests: XCTestCase {
    private static let base = Date(timeIntervalSince1970: 1_700_000_000)
    private static let week: TimeInterval = 7 * 24 * 60 * 60

    private enum WaitStage { case authorization, submission }
    private enum SettingChange { case alertOff, providerOff, unrelatedAlertOff, unrelatedProviderOff }

    private final class MutableRuntime: ProviderRuntime {
        let provider: Provider
        let widgetDescriptors: [WidgetDescriptor]
        var used = 80.0

        init(id: String = "test") {
            provider = Provider(id: id, displayName: id, icon: .providerMark("codex"))
            widgetDescriptors = [
                WidgetDescriptor(
                    id: "\(id).session", providerID: id, metricLabel: "Session",
                    sample: WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 80, limit: 100)
                )
            ]
        }

        func refresh() async -> ProviderSnapshot {
            ProviderSnapshot(
                providerID: provider.id, displayName: provider.displayName,
                lines: [
                    .progress(
                        label: "Session", used: used, limit: 100, format: .percent,
                        resetsAt: QuotaNotificationCancellationTests.base.addingTimeInterval(
                            QuotaNotificationCancellationTests.week * 0.10),
                        periodDurationMs: Int(QuotaNotificationCancellationTests.week * 1000))
                ])
        }
    }

    private actor DeliveryGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var opened = false

        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { continuation = $0 }
        }

        func open() {
            opened = true
            continuation?.resume()
            continuation = nil
        }
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "QuotaNotificationCancellationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    func testAlertOffDuringAuthorizationCancelsAndCanRetry() async {
        await verifyDelivery(waitAt: .authorization, change: .alertOff)
    }

    func testProviderOffDuringAuthorizationCancelsAndCanRetry() async {
        await verifyDelivery(waitAt: .authorization, change: .providerOff)
    }

    func testAlertOffDuringSubmissionRemovesOnlyThatRequestAndCanRetry() async {
        await verifyDelivery(waitAt: .submission, change: .alertOff)
    }

    func testProviderOffDuringSubmissionRemovesOnlyThatRequestAndCanRetry() async {
        await verifyDelivery(waitAt: .submission, change: .providerOff)
    }

    func testUnrelatedAlertOffKeepsThePendingDelivery() async {
        for stage in [WaitStage.authorization, .submission] {
            await verifyDelivery(waitAt: stage, change: .unrelatedAlertOff)
        }
    }

    func testUnrelatedProviderOffKeepsThePendingDelivery() async {
        for stage in [WaitStage.authorization, .submission] {
            await verifyDelivery(waitAt: stage, change: .unrelatedProviderOff)
        }
    }

    private func verifyDelivery(waitAt stage: WaitStage, change: SettingChange) async {
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.critical = true
        settings.warning = true
        var enabledProviders: Set<String> = ["test", "other"]
        let runtime = MutableRuntime()
        let otherRuntime = MutableRuntime(id: "other")
        let gate = DeliveryGate()
        let waiting = expectation(description: "delivery waiting at \(stage)")
        var attempts: [String] = []
        var submitted: [String] = []
        var removed: [String] = []
        var delivered: [String] = []
        var liveRequests: Set<String> = ["previously-delivered"]
        let store = WidgetDataStore(
            registry: WidgetRegistry.from([runtime, otherRuntime]), providers: [runtime, otherRuntime],
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults, isProviderEnabled: { enabledProviders.contains($0) },
            notificationSettings: { settings },
            postNotification: { id, _, _, _, isCurrent in
                let firstAttempt = attempts.isEmpty
                let request = UNNotificationRequest(
                    identifier: "\(id)-\(attempts.count)", content: UNMutableNotificationContent(), trigger: nil
                )
                attempts.append(request.identifier)
                do {
                    let didDeliver = try await AppNotifications.deliver(
                        request, isCurrent: isCurrent,
                        authorize: {
                            if firstAttempt, stage == .authorization {
                                waiting.fulfill()
                                await gate.wait()
                            }
                            return true
                        },
                        add: {
                            submitted.append($0.identifier)
                            liveRequests.insert($0.identifier)
                            if firstAttempt, stage == .submission {
                                waiting.fulfill()
                                await gate.wait()
                            }
                        },
                        remove: {
                            removed.append($0)
                            liveRequests.remove($0)
                        }
                    )
                    if didDeliver { delivered.append(request.identifier) }
                    return didDeliver
                } catch {
                    XCTFail("unexpected delivery failure: \(error)")
                    return false
                }
            }
        )
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: Self.base)
        XCTAssertTrue(attempts.isEmpty)
        runtime.used = 95
        await store.refreshAll(force: true)
        let evaluation = Task { await store.evaluateNotifications(now: Self.base) }
        await fulfillment(of: [waiting], timeout: 2)

        switch change {
        case .alertOff: settings.critical = false
        case .providerOff: enabledProviders.remove("test")
        case .unrelatedAlertOff: settings.warning = false
        case .unrelatedProviderOff: enabledProviders.remove("other")
        }
        await gate.open()
        await evaluation.value

        let shouldCancel = change == .alertOff || change == .providerOff
        let firstID = "test.underTenPercent-0"
        XCTAssertEqual(attempts, [firstID])
        XCTAssertEqual(submitted, shouldCancel && stage == .authorization ? [] : [firstID])
        XCTAssertEqual(removed, shouldCancel && stage == .submission ? [firstID] : [])
        XCTAssertEqual(delivered, shouldCancel ? [] : [firstID])
        XCTAssertEqual(liveRequests, shouldCancel ? ["previously-delivered"] : ["previously-delivered", firstID])

        settings.critical = true
        enabledProviders.insert("test")
        await store.evaluateNotifications(now: Self.base)
        let successfulID = shouldCancel ? "test.underTenPercent-1" : firstID
        XCTAssertEqual(delivered, [successfulID], "취소한 요청은 다시 시도하고 전달한 요청은 중복 억제")
        await store.evaluateNotifications(now: Self.base)
        XCTAssertEqual(delivered, [successfulID])
        XCTAssertEqual(attempts.count, shouldCancel ? 2 : 1)
    }

    func testProviderDisabledDuringAnotherDeliveryDoesNotStartLaterDelivery() async {
        let defaults = makeDefaults()
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.critical = true
        let runtimes = [MutableRuntime(id: "first"), MutableRuntime(id: "second")]
        var enabledProviders: Set<String> = ["first", "second"]
        var attempts: [String] = []
        let store = WidgetDataStore(
            registry: WidgetRegistry.from(runtimes), providers: runtimes,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageKey: "snapshots"),
            defaults: defaults, isProviderEnabled: { enabledProviders.contains($0) },
            orderedDescriptors: { runtimes.flatMap(\.widgetDescriptors) },
            notificationSettings: { settings },
            postNotification: { id, _, _, _, isCurrent in
                attempts.append(id)
                enabledProviders.remove("second")
                return isCurrent()
            }
        )
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: Self.base)
        for runtime in runtimes { runtime.used = 95 }
        await store.refreshAll(force: true)
        await store.evaluateNotifications(now: Self.base)
        XCTAssertEqual(attempts, ["first.underTenPercent"])
    }
}
