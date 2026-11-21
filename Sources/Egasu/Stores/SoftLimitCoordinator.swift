import Foundation
import Observation

@MainActor
@Observable
final class SoftLimitCoordinator {
    private struct ObservationBoundary {
        let revision = UUID()
        let notBefore: Date
    }

    private(set) var statuses: [String: SoftLimitProviderStatus] = [:]
    @ObservationIgnored private let settings: SoftLimitSettingsStore
    @ObservationIgnored private let adapters: [String: any SoftLimitCancelling]
    @ObservationIgnored private let isProviderEnabled: (String) -> Bool
    @ObservationIgnored private let isCancellationScopeVerified: (String) -> Bool
    @ObservationIgnored private let isQuotaInvalidated: (String, Date) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let pollingSleep: @MainActor () async throws -> Void
    @ObservationIgnored private let workQueue: BackgroundWorkQueue
    private var observations: [String: SoftLimitObservation] = [:]
    @ObservationIgnored private var inFlight: Set<String> = []
    @ObservationIgnored private var finished: Set<SoftLimitTask> = []
    @ObservationIgnored private var retries: [SoftLimitTask: Int] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var settingsBoundary = ObservationBoundary(notBefore: .distantPast)
    @ObservationIgnored private var accountBoundaries: [String: ObservationBoundary] = [:]
    @ObservationIgnored private var pollingTask: Task<Void, Never>?
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var pollingGeneration = 0

    init(
        settings: SoftLimitSettingsStore,
        adapters: [any SoftLimitCancelling],
        isProviderEnabled: @escaping (String) -> Bool,
        isCancellationScopeVerified: @escaping (String) -> Bool = { _ in false },
        isQuotaInvalidated: @escaping (String, Date) -> Bool = { _, _ in false },
        now: @escaping () -> Date = Date.init,
        pollingSleep: @escaping @MainActor () async throws -> Void = { try await Task.sleep(for: .seconds(2)) },
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) {
        self.settings = settings
        self.adapters = Dictionary(uniqueKeysWithValues: adapters.map { ($0.providerID, $0) })
        self.isProviderEnabled = isProviderEnabled
        self.isCancellationScopeVerified = isCancellationScopeVerified
        self.isQuotaInvalidated = isQuotaInvalidated
        self.now = now
        self.pollingSleep = pollingSleep
        self.workQueue = workQueue
    }

    func start() {
        isStarted = true
        updatePolling()
    }

    private var needsPolling: Bool {
        guard isStarted, settings.isActive else { return false }
        return observations.contains { providerID, observation in
            isProviderEnabled(providerID) && canControl(providerID)
                && !isQuotaInvalidated(providerID, observation.observedAt)
                && observation.quotaState(thresholdPercent: settings.thresholdPercent, at: now()) == .reached
        }
    }

    private func updatePolling() {
        guard needsPolling else {
            pollingTask?.cancel()
            pollingTask = nil
            return
        }
        guard pollingTask == nil else { return }
        pollingGeneration += 1
        let generation = pollingGeneration
        let pollingSleep = pollingSleep
        pollingTask = Task { [weak self] in
            defer {
                if self?.pollingGeneration == generation { self?.pollingTask = nil }
            }
            while !Task.isCancelled {
                do { try await pollingSleep() } catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.check()
                guard self.needsPolling else { return }
            }
        }
    }

    isolated deinit {
        pollingTask?.cancel()
        for adapter in adapters.values { adapter.disconnect() }
    }

    func stop() {
        isStarted = false
        settingsDidChange()
    }

    func settingsDidChange() {
        settingsBoundary = ObservationBoundary(notBefore: now())
        accountBoundaries.removeAll()
        observations.removeAll()
        finished.removeAll()
        retries.removeAll()
        retryAfter.removeAll()
        statuses.removeAll()
        for adapter in adapters.values { adapter.disconnect() }
        updatePolling()
    }

    /// ID 집합은 인증·카탈로그 변경, nil은 프로바이더 활성화 설정 변경.
    func accountsDidChange(_ changedIDs: Set<String>?) {
        let providerIDs =
            changedIDs
            ?? Set(statuses.keys).union(observations.keys).union(adapters.keys)
            .filter { !isProviderEnabled($0) }
        guard !providerIDs.isEmpty else { return }
        let boundary = ObservationBoundary(notBefore: now())
        for id in providerIDs {
            accountBoundaries[id] = boundary
            observations[id] = nil
            statuses[id] = nil
            retryAfter[id] = nil
            adapters[id]?.disconnect()
        }
        finished = finished.filter { !providerIDs.contains($0.providerID) }
        retries = retries.filter { !providerIDs.contains($0.key.providerID) }
        updatePolling()
    }

    private func boundary(for providerID: String) -> ObservationBoundary {
        accountBoundaries[providerID] ?? settingsBoundary
    }

    func receive(_ snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor]) {
        defer { updatePolling() }
        let providerID = snapshot.providerID
        guard settings.isActive, isProviderEnabled(providerID) else { return }
        if let observedAt = snapshot.liveQuotaObservedAt, observedAt < boundary(for: providerID).notBefore { return }
        let receivedAt = now()
        guard let observation = SoftLimitObservation.project(
                snapshot: snapshot, descriptors: descriptors, window: settings.window, now: receivedAt
            )
        else {
            observations[providerID] = nil
            statuses[providerID] = .init(phase: .waiting, message: L10n.errors("Waiting for fresh, supported quota data."))
            return
        }
        observations[providerID] = observation
        switch observation.quotaState(thresholdPercent: settings.thresholdPercent, at: receivedAt) {
        case .belowLimit:
            finished = finished.filter { $0.providerID != providerID }
            retries = retries.filter { $0.key.providerID != providerID }
            retryAfter[providerID] = nil
            statuses[providerID] = .init(phase: .belowLimit, message: L10n.errors("Below the soft limit. No tasks cancelled."))
        case .unknown:
            statuses[providerID] = .init(
                phase: .waiting, message: L10n.errors("Waiting for fresh, supported quota data."))
        case .reached:
            if adapters[providerID] == nil {
                statuses[providerID] = .init(
                    phase: .unsupported,
                    message: L10n.errors(
                        "Limit reached. Automatic cancellation is not supported for this provider yet."))
            }
        }
    }

    func invalidate(providerID: String) {
        guard settings.isActive else { return }
        accountBoundaries[providerID] = ObservationBoundary(notBefore: now())
        observations[providerID] = nil
        statuses[providerID] = .init(phase: .waiting, message: L10n.errors("Refresh failed. Waiting for fresh quota data before cancelling more tasks."))
        updatePolling()
    }

    private func currentObservation(for providerID: String) -> SoftLimitObservation? {
        guard settings.isActive, isProviderEnabled(providerID),
            let observation = observations[providerID], !isQuotaInvalidated(providerID, observation.observedAt)
        else { return nil }
        return observation
    }

    func quotaReading(for providerID: String) -> (state: SoftLimitQuotaState, usedFraction: Double?, nextExpiry: Date?)
    {
        guard let observation = currentObservation(for: providerID) else { return (.unknown, nil, nil) }
        let instant = now()
        let state = observation.quotaState(thresholdPercent: settings.thresholdPercent, at: instant)
        return (state, observation.maximumUsedFraction(at: instant), observation.nextExpiry(after: instant))
    }

    func quotaState(for providerID: String) -> SoftLimitQuotaState {
        currentObservation(for: providerID)?.quotaState(thresholdPercent: settings.thresholdPercent, at: now())
            ?? .unknown
    }

    func status(for providerID: String) -> SoftLimitProviderStatus {
        guard adapters[providerID] != nil else {
            return .init(phase: .unsupported, message: L10n.errors("Automatic cancellation is not supported yet."))
        }
        guard canControl(providerID) else {
            return .init(phase: .unsupported, message: L10n.errors("Account scope is not verified. Automatic cancellation is unavailable."))
        }
        if observations[providerID] != nil {
            switch quotaState(for: providerID) {
            case .unknown:
                return .init(phase: .waiting, message: L10n.errors("Waiting for fresh, supported quota data."))
            case .belowLimit:
                return .init(phase: .belowLimit, message: L10n.errors("Below the soft limit. No tasks cancelled."))
            case .reached: break
            }
        }
        return statuses[providerID] ?? .init(phase: .waiting, message: L10n.errors("Waiting for the next successful quota refresh."))
    }

    /// 주기마다 저장된 한도 관측을 평가. 새 정상 관측은 해당 프로바이더만 즉시 검사.
    func check() async {
        for providerID in observations.keys.sorted() {
            await check(providerID: providerID)
        }
    }

    func check(providerID: String) async {
        guard canControl(providerID), quotaState(for: providerID) == .reached else { return }
        guard let adapter = adapters[providerID], !inFlight.contains(providerID),
              retryAfter[providerID].map({ now() >= $0 }) ?? true
        else { return }
        inFlight.insert(providerID)
        defer { inFlight.remove(providerID) }
        let boundRevision = boundary(for: providerID).revision
        guard let ticket = await workQueue.acquire("soft-limit:\(ProviderAccountID.family(of: providerID))") else { return }
        defer { workQueue.finish(ticket) }
        guard canCancel(providerID, revision: boundRevision) else { return }
        do {
            let tasks = try await adapter.runningTasks()
            guard canCancel(providerID, revision: boundRevision) else { return }
            guard tasks.allSatisfy({ $0.providerID == providerID }) else { throw SoftLimitControlError.wrongProvider }
            let pending = Set(tasks).subtracting(finished)
            if pending.isEmpty {
                if statuses[providerID]?.phase != .cancelled {
                    statuses[providerID] = .init(phase: .noRunningTasks, message: L10n.errors("No running tasks on the connected client. %@", L10n.errors(adapter.coverageNotice)))
                }
                return
            }
            var cancelledCount = statuses[providerID]?.cancelledCount ?? 0
            var failures = 0
            defer {
                if boundary(for: providerID).revision == boundRevision, statuses[providerID]?.phase == .cancelling {
                    statuses[providerID] = .init(
                        phase: .waiting,
                        cancelledCount: cancelledCount,
                        message: L10n.errors("Cancellation stopped before all tasks were confirmed. Waiting for another check.")
                    )
                }
            }
            statuses[providerID] = .init(phase: .cancelling, cancelledCount: cancelledCount, message: L10n.errors("Cancelling connected tasks…"))
            for task in pending.sorted(by: { ($0.sessionID, $0.operationID) < ($1.sessionID, $1.operationID) }) {
                guard canCancel(providerID, revision: boundRevision) else { return }
                guard retries[task, default: 0] < 3 else { failures += 1; continue }
                do {
                    let outcome = try await adapter.cancel(task) { [weak self] in
                        self?.canCancel(providerID, revision: boundRevision) == true
                    }
                    guard canCancel(providerID, revision: boundRevision) else { return }
                    finished.insert(task)
                    if case .cancelled = outcome { cancelledCount += 1 }
                } catch is CancellationError {
                    return
                } catch {
                    guard canCancel(providerID, revision: boundRevision) else { return }
                    failures += 1
                    retries[task, default: 0] += 1
                    AppLog.error(LogTag.plugin(providerID), "Soft Limit task cancellation failed")
                }
            }
            statuses[providerID] = .init(
                phase: failures == 0 ? .cancelled : .failed,
                cancelledCount: cancelledCount,
                failedCount: failures,
                message: L10n.errors("%@ connected task(s) cancelled. %@%@", String(cancelledCount),
                    failures > 0 ? L10n.errors("%@ cancellation(s) not confirmed. ", String(failures)) : "",
                    L10n.errors(adapter.coverageNotice))
            )
            if failures > 0 { retryAfter[providerID] = now().addingTimeInterval(10) }
            AppLog.info(LogTag.plugin(providerID), "Soft Limit result: cancelled=\(cancelledCount), failed=\(failures)")
        } catch is CancellationError {
            return
        } catch {
            guard canCancel(providerID, revision: boundRevision) else { return }
            adapter.disconnect()
            let message = (error as? SoftLimitControlError).map { UserFacingErrors.message($0) }
                ?? L10n.errors("The local cancellation connection failed. Tasks may still be running.")
            statuses[providerID] = .init(phase: .failed, message: message)
            retryAfter[providerID] = now().addingTimeInterval(10)
            AppLog.error(LogTag.plugin(providerID), "Soft Limit control connection failed")
        }
    }

    private func canControl(_ providerID: String) -> Bool {
        !providerID.contains("@") && adapters[providerID] != nil && isCancellationScopeVerified(providerID)
    }

    private func canCancel(_ providerID: String, revision expected: UUID) -> Bool {
        !Task.isCancelled && boundary(for: providerID).revision == expected && canControl(providerID)
            && quotaState(for: providerID) == .reached
    }
}
