import Foundation

/// 0% 사용량과 이동하는 절대 리셋 시각을 확인하고 계정별 전송·검증을 직렬화.
@MainActor
final class UsageTimerCoordinator<Session: UsageTimerPreparedSession> {
    private struct Candidate {
        var providerID: String
        var bindingID: UUID
        var observation: UsageTimerObservation
        var observationEpoch: UUID
    }

    private struct PendingVerification {
        var lastObservation: UsageTimerObservation?
    }

    private struct PendingWorkWaiter {
        let providerIDs: Set<String>
        let accountKeys: Set<String>
        let continuation: CheckedContinuation<Void, Never>
    }

    typealias CandidateValidity = @MainActor @Sendable () -> Bool

    private let store: UsageTimerAttemptStore
    private let isCurrent: @MainActor (String, UUID, String) -> Bool
    private let prepare:
        @MainActor (String, UsageTimerObservation, @escaping CandidateValidity) async throws -> Session?
    private let execute: @MainActor (String, UUID, Session, @escaping @MainActor () -> Bool) async -> UsageTimerExecutionResult
    private let verify: @MainActor (String, Session, @escaping CandidateValidity) async throws -> UsageTimerObservation?
    private let report: @MainActor (String, UUID, String, String?) -> Void
    private let finished: @MainActor (String, UUID) -> Void
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private var pending: [Candidate] = []
    private var awaitingReset: [String: PendingVerification] = [:]
    private var preparationRetries: Set<String> = []
    private var reportedSendLimits: [String: [String: Date]] = [:]
    private var accountByProvider: [String: (accountKey: String, bindingID: UUID)] = [:]
    private var active: Candidate?
    private var executing: Candidate?
    private var task: Task<Void, Never>?
    private var pendingWorkWaiters: [PendingWorkWaiter] = []
    private var observationEpoch = UUID()
    private var stopped = false

    init(
        store: UsageTimerAttemptStore = UsageTimerAttemptStore(),
        isCurrent: @escaping @MainActor (String, UUID, String) -> Bool,
        prepare:
            @escaping @MainActor (String, UsageTimerObservation, @escaping CandidateValidity) async throws -> Session?,
        execute: @escaping @MainActor (String, UUID, Session, @escaping @MainActor () -> Bool) async -> UsageTimerExecutionResult,
        verify:
            @escaping @MainActor (String, Session, @escaping CandidateValidity) async throws -> UsageTimerObservation?,
        report: @escaping @MainActor (String, UUID, String, String?) -> Void,
        finished: @escaping @MainActor (String, UUID) -> Void = { _, _ in },
        now: @escaping @MainActor () -> Date = Date.init,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.store = store
        self.isCurrent = isCurrent
        self.prepare = prepare
        self.execute = execute
        self.verify = verify
        self.report = report
        self.finished = finished
        self.now = now
        self.wait = wait
    }

    deinit { task?.cancel() }

    var hasPendingWork: Bool {
        task != nil || active != nil || !pending.isEmpty
    }

    func hasPendingWork(providerIDs: Set<String>) -> Bool {
        hasPendingWork(providerIDs: providerIDs, accountKeys: Set(providerIDs.compactMap { accountByProvider[$0]?.accountKey }))
    }

    func waitForPendingWork(providerIDs: Set<String>) async {
        let accountKeys = Set(providerIDs.compactMap { accountByProvider[$0]?.accountKey })
        guard hasPendingWork(providerIDs: providerIDs, accountKeys: accountKeys) else { return }
        await withCheckedContinuation { continuation in
            pendingWorkWaiters.append(.init(providerIDs: providerIDs, accountKeys: accountKeys, continuation: continuation))
        }
    }

    private func hasPendingWork(providerIDs: Set<String>, accountKeys: Set<String>) -> Bool {
        let matches: (Candidate) -> Bool = {
            providerIDs.contains($0.providerID) || accountKeys.contains($0.observation.accountKey)
        }
        return active.map(matches) == true || pending.contains(where: matches)
    }

    private func resumePendingWorkWaiters() {
        pendingWorkWaiters.removeAll { waiter in
            guard !hasPendingWork(providerIDs: waiter.providerIDs, accountKeys: waiter.accountKeys) else { return false }
            waiter.continuation.resume()
            return true
        }
    }

    func isRunning(providerID: String) -> Bool {
        guard let active = executing else { return false }
        return active.providerID == providerID
            || accountByProvider[providerID]?.accountKey == active.observation.accountKey
    }

    func receive(
        providerID: String, bindingID: UUID, observation: UsageTimerObservation,
        checkUnconfirmedReset: Bool = false
    ) {
        guard !stopped, isCurrent(providerID, bindingID, observation.accountKey) else { return }
        defer { resumePendingWorkWaiters() }
        accountByProvider[providerID] = (observation.accountKey, bindingID)
        let candidate = Candidate(providerID: providerID, bindingID: bindingID, observation: observation,
                                  observationEpoch: observationEpoch)
        do {
            let change = try store.observe(
                accountKey: observation.storageKey, rawResetAt: observation.rawResetAt,
                observedAt: observation.observedAt, usedPercent: observation.usedPercent,
                confirmsReset: observation.startRule == .missingReset
            )
            guard change != .stale else { return }
            if change != .incomparable || observation.rawResetAt == nil || observation.usedPercent != 0 {
                pending.removeAll { $0.observation.storageKey == observation.storageKey }
            }
            recoverVerification(candidate, change: change)
            if change == .unchanged || observation.usedPercent > 0,
               preparationRetries.remove(observation.storageKey) != nil {
                report(candidate.providerID, candidate.bindingID, candidate.observation.timerID, nil)
            }
            guard change != .unchanged,
                  change == .changed || checkUnconfirmedReset || observation.startRule == .missingReset
                    || preparationRetries.contains(observation.storageKey),
                  observation.canStart(at: now()),
                  try canPrepare(candidate, reportLimit: change == .changed)
            else { return }
        } catch {
            fail(candidate, "Usage timer automation could not read its saved state. No message was sent.")
            return
        }
        pending.append(candidate)
        guard task == nil else { return }
        task = Task { [weak self] in await self?.drain() }
    }

    func invalidate(providerID: String) {
        defer { resumePendingWorkWaiters() }
        pending.removeAll { $0.providerID == providerID }
        if let binding = accountByProvider.removeValue(forKey: providerID),
           !accountByProvider.values.contains(where: { $0.accountKey == binding.accountKey }) {
            clearReportedSendLimit(for: binding.accountKey)
        }
    }

    /// 전송 상한은 보존하고, 사라진 보류 안내의 중복 보고 기록만 초기화.
    func clearReportedSendLimit(for accountKey: String) {
        reportedSendLimits[accountKey] = nil
    }

    func invalidateObservations() {
        observationEpoch = UUID()
        pending.removeAll()
        awaitingReset = awaitingReset.mapValues { _ in PendingVerification(lastObservation: nil) }
        resumePendingWorkWaiters()
    }

    func stop() {
        stopped = true
        pending.removeAll()
        task?.cancel()
        resumePendingWorkWaiters()
    }

    func shutdown() async {
        let runningTask = task
        stop()
        await runningTask?.value
    }

    private func drain() async {
        while !pending.isEmpty, !Task.isCancelled, !stopped {
            defer { resumePendingWorkWaiters() }
            let candidate = pending.removeFirst()
            guard current(candidate) else { continue }
            active = candidate
            await process(candidate)
            active = nil
            if !stopped { finished(candidate.providerID, candidate.bindingID) }
        }
        task = nil
        resumePendingWorkWaiters()
    }

    private func process(_ candidate: Candidate) async {
        let accountKey = candidate.observation.storageKey
        do {
            guard try isLatest(candidate) else { return }
            guard try canPrepare(candidate) else { return }
        } catch {
            fail(candidate, "Usage timer automation could not read its saved state. No message was sent.")
            return
        }

        let isCurrent = validity(for: candidate)
        var session: Session
        do {
            guard let prepared = try await prepare(candidate.providerID, candidate.observation, isCurrent),
                current(candidate),
                  prepared.observation.storageKey == accountKey
            else { return }
            session = prepared
            if preparationRetries.remove(accountKey) != nil {
                report(candidate.providerID, candidate.bindingID, candidate.observation.timerID, nil)
            }
        } catch is CancellationError {
            return
        } catch {
            AppDiagnostics.failure(.weeklyTimer, error: error, providerID: candidate.providerID)
            fail(candidate, (error as? UsageTimerError)?.errorDescription
                ?? "Usage timer message could not be prepared. Refresh to try again.")
            preparationRetries.insert(accountKey)
            return
        }

        var attempt: UsageTimerAttempt
        if session.observation.startRule == .missingReset {
            do {
                guard current(candidate), try isLatest(candidate),
                      session.observation.canStart(at: now()) else { return }
                _ = try store.observe(accountKey: accountKey, rawResetAt: session.observation.rawResetAt,
                                      observedAt: session.observation.observedAt,
                                      usedPercent: session.observation.usedPercent,
                                      confirmsReset: session.observation.startRule == .missingReset)
                guard let reserved = try store.begin(
                    accountKey: accountKey, resetBefore: session.observation.rawResetAt, now: now(),
                    expectedObservedAt: session.observation.observedAt,
                    budgetWindow: session.observation.budgetWindow
                ) else { return }
                attempt = reserved
            } catch {
                fail(candidate, "Usage timer automation could not save its state. No message was sent.")
                return
            }
        } else {
            let firstObservation = session.observation
            let preparationObservedAt: Date
            let revalidationState: UsageTimerAttemptStore.RevalidationState
            do {
                guard try isLatest(candidate) else { return }
                let change = try store.observe(
                    accountKey: accountKey, rawResetAt: session.observation.rawResetAt,
                    observedAt: session.observation.observedAt, usedPercent: session.observation.usedPercent
                )
                guard change != .stale, session.observation.usedPercent == 0,
                      let reset = session.observation.rawResetAt, reset > now(),
                      change != .unchanged,
                      let observedAt = try store.latestObservationAt(accountKey: accountKey),
                      let state = try store.revalidationState(accountKey: accountKey, now: now(), budgetWindow: candidate.observation.budgetWindow),
                      !UsageTimerObservation.resetTimesMatch(reset, state.confirmedReset)
                else { return }
                preparationObservedAt = observedAt
                revalidationState = state
            } catch {
                fail(candidate, "Usage timer automation could not save its state. No message was sent.")
                return
            }

            do {
                // 다른 클라이언트가 이미 시작한 타이머와 단발성 시각 변화를 전송 전에 구분.
                try await wait(.seconds(UsageTimerObservation.verificationInterval))
                guard current(candidate),
                      try store.latestObservationAt(accountKey: accountKey) == preparationObservedAt,
                    let prepared = try await prepare(candidate.providerID, candidate.observation, isCurrent),
                    current(candidate),
                      prepared.observation.storageKey == accountKey else { return }
                session = prepared
            } catch is CancellationError {
                return
            } catch {
                AppDiagnostics.failure(.weeklyTimer, error: error, providerID: candidate.providerID)
                fail(candidate, (error as? UsageTimerError)?.errorDescription
                    ?? "Usage timer message could not be prepared. Refresh to try again.")
                preparationRetries.insert(accountKey)
                return
            }

            do {
                guard try store.latestObservationAt(accountKey: accountKey) == preparationObservedAt else { return }
                guard current(candidate) else { return }
                guard let reserved = try store.beginAfterRevalidation(
                    first: firstObservation, second: session.observation, expectedState: revalidationState, now: now()
                ) else {
                    _ = try store.observe(accountKey: accountKey, rawResetAt: session.observation.rawResetAt,
                                          observedAt: session.observation.observedAt,
                                          usedPercent: session.observation.usedPercent,
                                          confirmsReset: session.observation.startRule == .missingReset)
                    return
                }
                attempt = reserved
                awaitingReset[accountKey] = nil
            } catch {
                fail(candidate, "Usage timer automation could not save its state. No message was sent.")
                return
            }

        }

        // 실행 준비 중 비교 기준이 바뀌면 시작 직전에 차단하고 전송 예약 유지.
        let launchObservation = session.observation
        var launchObservationIsCurrent: Bool? = true
        executing = candidate
        let result = await execute(candidate.providerID, candidate.bindingID, session) { [weak self] in
            guard let self, self.current(candidate) else {
                launchObservationIsCurrent = false
                return false
            }
            do {
                let isLatest = try self.store.isLatest(launchObservation)
                launchObservationIsCurrent = isLatest
                return isLatest
            } catch {
                launchObservationIsCurrent = nil
                self.fail(candidate, "Usage timer automation could not read its saved state. No message was sent.")
                return false
            }
        }
        executing = nil
        attempt.execution = result.completed ? .completed : .failed
        let observationChanged = launchObservationIsCurrent == false || result.launchObservationInvalidated
        if result.launched || !observationChanged { attempt.messageLaunched = result.launched }
        var stateSaveFailed = false
        do { try store.update(accountKey: accountKey, attempt: attempt) }
        catch {
            stateSaveFailed = true
            fail(candidate, "Usage timer automation could not update its saved state.")
        }
        guard current(candidate), launchObservationIsCurrent != nil else { return }
        if (observationChanged || result.loginNoLongerEligible) && result.verificationCanClearFailure { return }
        guard result.launched else {
            fail(candidate, result.failureDescription ?? "Usage timer message could not be started. Refresh after five minutes to try again.")
            return
        }
        var lastPostObservation: UsageTimerObservation?
        let verified = await verifyTimer(
            candidate, session: session, attempt: &attempt, lastObservation: &lastPostObservation
        )
        guard current(candidate) else { return }
        if let failure = result.failureDescription { AppLog.error(LogTag.plugin(candidate.providerID), failure) }
        if stateSaveFailed {
            fail(candidate, "Usage timer automation could not update its saved state.")
        } else if !result.verificationCanClearFailure {
            fail(candidate, result.failureDescription ?? "Usage timer credentials could not be updated.")
        } else if !verified {
            fail(candidate, result.failureDescription ?? (result.completed
                ? "Usage timer message completed, but the server reset time could not be confirmed."
                : "Usage timer message completion could not be confirmed. Retries wait at least five minutes and are limited to 2 attempts per usage window."))
            awaitingReset[accountKey] = PendingVerification(lastObservation: lastPostObservation)
        } else {
            report(candidate.providerID, candidate.bindingID, candidate.observation.timerID, nil)
        }
    }

    private func verifyTimer(
        _ candidate: Candidate, session: Session, attempt: inout UsageTimerAttempt,
        lastObservation: inout UsageTimerObservation?
    ) async -> Bool {
        let endedAt = now()
        var previousReset: Date?
        var previousObservedAt: Date?
        let interval = UsageTimerObservation.verificationInterval
        for delay: TimeInterval in [0, interval, interval * 2] {
            guard current(candidate) else { return false }
            let remaining = endedAt.addingTimeInterval(delay).timeIntervalSince(now())
            if remaining > 0 {
                do { try await wait(.seconds(remaining)) } catch { return false }
                guard current(candidate) else { return false }
            }
            do {
                guard let observation = try await verify(candidate.providerID, session, validity(for: candidate)),
                    current(candidate),
                      observation.storageKey == candidate.observation.storageKey,
                      observation.observedAt >= endedAt
                else { previousReset = nil; continue }
                let change = try store.observe(
                    accountKey: observation.storageKey, rawResetAt: observation.rawResetAt,
                    observedAt: observation.observedAt, usedPercent: observation.usedPercent,
                    confirmsReset: observation.startRule == .missingReset
                )
                guard change != .stale else { previousReset = nil; continue }
                attempt.lastVerifiedAt = observation.observedAt
                attempt.resetAfter = observation.rawResetAt
                try store.update(accountKey: observation.storageKey, attempt: attempt)
                guard let reset = observation.rawResetAt, reset > now() else {
                    previousReset = nil
                    lastObservation = nil
                    continue
                }
                lastObservation = observation
                if observation.startRule == .missingReset { return true }
                if UsageTimerObservation.resetTimesMatch(previousReset, reset), change == .unchanged,
                   let previousObservedAt,
                   observation.observedAt.timeIntervalSince(previousObservedAt) >= UsageTimerObservation.verificationInterval {
                    return true
                }
                if !UsageTimerObservation.resetTimesMatch(previousReset, reset) {
                    previousReset = reset
                    previousObservedAt = observation.observedAt
                }
            } catch is CancellationError {
                return false
            } catch {
                previousReset = nil
                AppLog.error(LogTag.plugin(candidate.providerID), "Usage timer reset verification failed")
            }
        }
        return false
    }

    private func recoverVerification(
        _ candidate: Candidate, change: UsageTimerObservationChange
    ) {
        let observation = candidate.observation
        guard var waiting = awaitingReset[observation.storageKey] else { return }
        guard let reset = observation.rawResetAt, reset > now() else {
            waiting.lastObservation = nil
            awaitingReset[observation.storageKey] = waiting
            return
        }
        if change == .unchanged,
           let previous = waiting.lastObservation,
           UsageTimerObservation.resetTimesMatch(previous.rawResetAt, reset),
           observation.observedAt.timeIntervalSince(previous.observedAt) >= UsageTimerObservation.verificationInterval {
            awaitingReset[observation.storageKey] = nil
            reportedSendLimits[observation.accountKey]?[observation.timerID] = nil
            if current(candidate) { report(candidate.providerID, candidate.bindingID, candidate.observation.timerID, nil) }
        } else if !UsageTimerObservation.resetTimesMatch(waiting.lastObservation?.rawResetAt, reset) {
            waiting.lastObservation = observation
            awaitingReset[observation.storageKey] = waiting
        }
    }

    private func validity(for candidate: Candidate) -> CandidateValidity {
        { [weak self] in self?.current(candidate) == true }
    }

    private func current(_ candidate: Candidate) -> Bool {
        !stopped && !Task.isCancelled
            && candidate.observationEpoch == observationEpoch
            && isCurrent(candidate.providerID, candidate.bindingID, candidate.observation.accountKey)
    }

    private func canPrepare(_ candidate: Candidate, reportLimit: Bool = true) throws -> Bool {
        let observation = candidate.observation
        let accountKey = candidate.observation.storageKey
        if let until = try store.sendLimitResetsAt(accountKey: accountKey, now: now(), budgetWindow: candidate.observation.budgetWindow) {
            if reportLimit, reportedSendLimits[observation.accountKey]?[observation.timerID] != until {
                fail(candidate, "Usage timer messages paused: this quota reached the limit of 2 attempts in its usage window. Usage checks will continue.")
                reportedSendLimits[observation.accountKey, default: [:]][observation.timerID] = until
                awaitingReset[accountKey] = PendingVerification(lastObservation: candidate.observation)
            }
            return false
        }
        if reportedSendLimits[observation.accountKey]?.removeValue(forKey: observation.timerID) != nil {
            awaitingReset[accountKey] = nil
            report(candidate.providerID, candidate.bindingID, candidate.observation.timerID, nil)
        }
        guard let state = try store.revalidationState(accountKey: accountKey, now: now(), budgetWindow: candidate.observation.budgetWindow) else { return false }
        return !UsageTimerObservation.resetTimesMatch(candidate.observation.rawResetAt, state.confirmedReset)
    }

    private func isLatest(_ candidate: Candidate) throws -> Bool {
        try store.isLatest(candidate.observation) || store.isLatestReceived(candidate.observation)
    }

    private func fail(_ candidate: Candidate, _ message: String) {
        awaitingReset[candidate.observation.storageKey] = nil
        reportedSendLimits[candidate.observation.accountKey]?[candidate.observation.timerID] = nil
        AppLog.error(LogTag.plugin(candidate.providerID), message)
        guard current(candidate) else { return }
        report(candidate.providerID, candidate.bindingID, candidate.observation.timerID, message)
    }
}
