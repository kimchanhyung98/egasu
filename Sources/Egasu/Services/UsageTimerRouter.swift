import Foundation

/// 활성 계정의 최신 조회만 자동 전송에 연결하고 계정 교체 뒤의 결과 게시 차단.
@MainActor
final class UsageTimerRouter {
    private static let stateReadWarning = "Usage timer automation could not read its saved state. No message was sent."

    private struct Binding {
        let id = UUID()
        var provider: any UsageTimerProviding
        var accountKey: String?
    }

    private var bindings: [String: Binding]
    private var identityKeys: [String: String]
    private var warningsByAccount: [String: [String: String]] = [:]
    private var scheduledCheckRequests: Set<String> = []
    private var followUpRefreshes: [UUID: (providerID: String, task: Task<Void, Never>)] = [:]
    let usageTimerSetting: UsageTimerSetting
    private var scheduledCheckGeneration = UUID()
    private var activeLaunch:
        (providerID: String, observation: UsageTimerObservation, permission: StreamingProcessLaunchPermission)?
    private let isProviderEnabled: (String) -> Bool
    private let executors: UsageTimerExecutors
    private let store: UsageTimerAttemptStore
    private var isShuttingDown = false
    private let publishWarning: (String, [String]?) -> Void
    private let refresh: @MainActor (String, @escaping @MainActor () -> Bool) async -> Void
    private let now: @MainActor () -> Date
    private let wait: @MainActor (Duration) async throws -> Void
    private let workQueue: BackgroundWorkQueue
    private nonisolated(unsafe) var clockObserver: NSObjectProtocol?
    private lazy var coordinator = UsageTimerCoordinator<UsageTimerSession>(
        store: store,
        isCurrent: { [weak self] in self?.isCurrent($0, bindingID: $1, accountKey: $2) == true },
        prepare: { [weak self] providerID, observation, isCurrent in
            guard let self, let ticket = await self.workQueue.acquire("weekly-timer:prepare") else { return nil }
            defer { self.workQueue.finish(ticket) }
            try Task.checkCancellation()
            guard isCurrent(), let provider = self.bindings[providerID]?.provider else { return nil }
            return try await UsageTimerReadContext.$isCurrent.withValue(isCurrent) {
                try await provider.prepareUsageTimer(observation, executors: self.executors)
            }
        },
        execute: { [weak self] providerID, _, session, canLaunch in
            guard let self, let ticket = await self.workQueue.acquire("weekly-timer:execute") else {
                return UsageTimerExecutionResult(launched: false, completed: false)
            }
            defer { self.workQueue.finish(ticket) }
            guard canLaunch() else {
                return UsageTimerExecutionResult(launched: false, completed: false)
            }
            let hadStartupFailure = self.executors.codex.startupFailureDescription != nil
            let permission = StreamingProcessLaunchPermission()
            self.activeLaunch = (providerID, session.observation, permission)
            defer { self.activeLaunch = nil }
            var result = await StreamingProcessLaunchPermission.$current.withValue(permission) {
                await session.send { canLaunch() }
            }
            if !result.launched, permission.isRevoked { result.launchObservationInvalidated = true }
            if !self.isShuttingDown, hadStartupFailure, self.executors.codex.startupFailureDescription == nil {
                for (id, binding) in self.bindings where binding.provider is CodexProvider && self.isProviderEnabled(id) {
                    self.report(id, binding.accountKey.flatMap { self.warning(for: $0) })
                }
            }
            return result
        },
        verify: { [weak self] _, session, isCurrent in
            guard let self, let ticket = await self.workQueue.acquire("weekly-timer:verify") else { return nil }
            defer { self.workQueue.finish(ticket) }
            try Task.checkCancellation()
            guard isCurrent() else { return nil }
            return try await UsageTimerReadContext.$isCurrent.withValue(isCurrent) { try await session.verify() }
        },
        report: { [weak self] providerID, bindingID, timerID, message in
            guard let self, let binding = self.bindings[providerID], binding.id == bindingID,
                  let accountKey = binding.accountKey else { return }
            self.warningsByAccount[accountKey, default: [:]][timerID] = message
            for (id, current) in self.bindings where current.accountKey == accountKey && self.isProviderEnabled(id) {
                self.report(id, self.warning(for: accountKey))
            }
            AppDiagnostics.record(.weeklyTimer, result: message == nil ? .success : .failure,
                                  providerID: providerID)
        },
        finished: { [weak self] providerID, bindingID in
            guard let self, !self.isShuttingDown, self.usageTimerSetting.isEnabled,
                self.bindings[providerID]?.id == bindingID
            else { return }
            let id = UUID()
            let task = Task { [weak self] in
                guard let self else { return }
                defer { self.followUpRefreshes[id] = nil }
                await self.refresh(providerID) { [weak self] in
                    self?.isShuttingDown == false && self?.bindings[providerID]?.id == bindingID
                        && self?.isProviderEnabled(providerID) == true
                }
            }
            self.followUpRefreshes[id] = (providerID, task)
        },
        now: now,
        wait: wait
    )

    init(
        providers: [any ProviderRuntime],
        identityKeys: [String: String] = [:],
        isProviderEnabled: @escaping (String) -> Bool,
        usageTimerSetting: UsageTimerSetting = UsageTimerSetting(),
        executor: any CodexWeeklyTimerExecuting = CodexWeeklyTimerExecutor(),
        cliExecutor: any UsageTimerCLIExecuting = UsageTimerCLIExecutor(),
        store: UsageTimerAttemptStore = UsageTimerAttemptStore(),
        report: @escaping (String, [String]?) -> Void,
        refresh: @escaping @MainActor (String, @escaping @MainActor () -> Bool) async -> Void,
        now: @escaping @MainActor () -> Date = Date.init,
        wait: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) {
        self.bindings = Dictionary(uniqueKeysWithValues: providers.compactMap { $0 as? any UsageTimerProviding }.map { ($0.provider.id, Binding(provider: $0)) })
        self.identityKeys = identityKeys
        self.isProviderEnabled = isProviderEnabled
        self.usageTimerSetting = usageTimerSetting
        self.executors = UsageTimerExecutors(codex: executor, cli: cliExecutor)
        self.store = store
        self.publishWarning = report
        self.refresh = refresh
        self.now = now
        self.wait = wait
        self.workQueue = workQueue
        clockObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.clockDidChange() }
        }
        usageTimerSetting.onDisable = { [weak self] in
            guard let self else { return }
            self.activeLaunch?.permission.revoke()
            self.scheduledCheckGeneration = UUID()
            let accountKeys = self.bindings.compactMapValues(\.accountKey)
            // 즉시 다시 켜도 대기 중이던 이전 전송이 살아나지 않도록 바인딩 교체.
            self.invalidate(providerIDs: Set(self.bindings.keys))
            // 이미 실행 중인 작업을 같은 계정의 다른 카드에서도 기다릴 수 있게 연결 보존.
            if self.hasPendingWork || !self.followUpRefreshes.isEmpty {
                for (providerID, accountKey) in accountKeys {
                    self.bindings[providerID]?.accountKey = accountKey
                }
            }
        }
        reportStartupFailure()
    }

    deinit {
        if let clockObserver { NotificationCenter.default.removeObserver(clockObserver) }
    }

    func receive(_ snapshot: ProviderSnapshot, trigger: RefreshTrigger) {
        guard !isShuttingDown, usageTimerSetting.isEnabled, trigger != .cli, trigger != .weeklyTimer,
              var binding = bindings[snapshot.providerID],
              let quotaObservedAt = snapshot.liveQuotaObservedAt else { return }
        let observedAt = snapshot.usageTimerObservedAt ?? quotaObservedAt
        guard observedAt <= now() else {
            AppLog.debug(.refresh, "Ignored quota observation from before a backward clock change")
            return
        }
        let observations = binding.provider.usageTimerObservations
        guard let observation = observations.first else {
            invalidate(providerIDs: [snapshot.providerID])
            return
        }
        guard observation.observedAt == observedAt else { return }
        let accountChanged = binding.accountKey != observation.accountKey
        if let accountKey = binding.accountKey, accountKey != observation.accountKey {
            if let launch = activeLaunch, launch.providerID == snapshot.providerID { launch.permission.revoke() }
            coordinator.invalidate(providerID: snapshot.providerID)
            binding = Binding(provider: binding.provider)
            report(snapshot.providerID, nil)
        }
        binding.accountKey = observation.accountKey
        bindings[snapshot.providerID] = binding
        if accountChanged { removeUnboundWarnings() }
        if accountChanged, isProviderEnabled(snapshot.providerID), let warning = warning(for: observation.accountKey) {
            report(snapshot.providerID, warning)
        }
        do {
            let discard = { try self.store.discardFutureObservations(now: self.now()) }
            if try activeLaunch?.permission.revokeIf(discard) ?? discard() { invalidateObservations() }
            if warningsByAccount[observation.accountKey]?["state"] != nil {
                warningsByAccount[observation.accountKey]?["state"] = nil
                for (id, current) in bindings where current.accountKey == observation.accountKey && isProviderEnabled(id) {
                    report(id, warning(for: observation.accountKey))
                }
            }
        } catch {
            reportStateReadFailure(error, providerID: snapshot.providerID, accountKey: observation.accountKey)
            return
        }
        let scheduledRequested = scheduledCheckRequests.remove(snapshot.providerID) != nil
        let checkTimer = scheduledRequested || trigger == .weeklyTimerCheck
        for observation in observations {
            let receiveObservation = {
                self.coordinator.receive(
                    providerID: snapshot.providerID, bindingID: binding.id, observation: observation,
                    checkUnconfirmedReset: checkTimer
                )
            }
            if let launch = activeLaunch, launch.observation.storageKey == observation.storageKey,
                !launch.permission.isRevoked
            {
                do {
                    try launch.permission.revokeIf {
                        guard receiveObservation() else { return true }
                        return try !store.isLatest(launch.observation)
                    }
                } catch {
                    reportStateReadFailure(error, providerID: launch.providerID, accountKey: observation.accountKey)
                }
            } else {
                _ = receiveObservation()
            }
        }
    }

    func scheduledCheckValidity() -> @MainActor () -> Bool {
        let generation = scheduledCheckGeneration
        return { [weak self] in
            guard let self else { return false }
            return !self.isShuttingDown && self.usageTimerSetting.isEnabled
                && self.scheduledCheckGeneration == generation
        }
    }

    /// 15분 경계 조회가 진행 중인 요청과 겹치면 다음 정상 응답에서 재검증.
    func requestScheduledCheck() -> [String] {
        guard !isShuttingDown, usageTimerSetting.isEnabled else { return [] }
        let providerIDs = bindings.keys.filter { isProviderEnabled($0) }.sorted()
        scheduledCheckRequests.formUnion(providerIDs)
        return providerIDs
    }

    func isRunning(providerID: String) -> Bool {
        relatedProviderIDs(to: [providerID]).contains { coordinator.isRunning(providerID: $0) }
    }

    var hasPendingWork: Bool { coordinator.hasPendingWork }

    func hasPendingWork(providerIDs: Set<String>) -> Bool {
        let affected = relatedProviderIDs(to: providerIDs)
        return coordinator.hasPendingWork(providerIDs: affected)
            || followUpRefreshes.values.contains { affected.contains($0.providerID) }
    }

    func waitForPendingWork(providerIDs: Set<String>) async {
        let affected = relatedProviderIDs(to: providerIDs)
        while true {
            await coordinator.waitForPendingWork(providerIDs: affected)
            let refreshes = followUpRefreshes.values.filter { affected.contains($0.providerID) }.map(\.task)
            guard !refreshes.isEmpty else { return }
            for refresh in refreshes { await refresh.value }
        }
    }

    private func relatedProviderIDs(to providerIDs: Set<String>) -> Set<String> {
        let accountKeys = Set(providerIDs.compactMap { bindings[$0]?.accountKey })
        return providerIDs.union(bindings.compactMap { id, binding in
            binding.accountKey.map { accountKeys.contains($0) } == true ? id : nil
        })
    }

    func shutdown() async {
        isShuttingDown = true
        activeLaunch?.permission.revoke()
        await coordinator.shutdown()
    }

    func invalidate(providerIDs: Set<String>? = nil) {
        let affected = providerIDs ?? Set(bindings.keys.filter { !isProviderEnabled($0) })
        if let launch = activeLaunch, affected.contains(launch.providerID) { launch.permission.revoke() }
        for providerID in affected {
            scheduledCheckRequests.remove(providerID)
            guard let binding = bindings[providerID] else { continue }
            coordinator.invalidate(providerID: providerID)
            bindings[providerID] = Binding(provider: binding.provider)
            report(providerID, nil)
        }
        removeUnboundWarnings()
        if providerIDs == nil { reportStartupFailure() }
    }

    func reconfigure(providers: [any ProviderRuntime], identityKeys: [String: String] = [:]) {
        let removed = Set(bindings.keys).subtracting(providers.map { $0.provider.id })
        invalidate(providerIDs: removed)
        for providerID in removed { bindings[providerID] = nil }
        for provider in providers.compactMap({ $0 as? any UsageTimerProviding }) {
            let providerID = provider.provider.id
            if var binding = bindings[providerID],
               binding.provider === provider
                || (identityKeys[providerID] != nil && self.identityKeys[providerID] == identityKeys[providerID])
                || !ProviderAccountID.families.contains(ProviderAccountID.family(of: providerID)) {
                binding.provider = provider
                bindings[providerID] = binding
            } else {
                invalidate(providerIDs: [providerID])
                bindings[providerID] = Binding(provider: provider)
            }
        }
        self.identityKeys = identityKeys
        reportStartupFailure()
    }

    private func reportStartupFailure() {
        guard !isShuttingDown, let warning = executors.codex.startupFailureDescription else { return }
        for (providerID, binding) in bindings where binding.provider is CodexProvider && isProviderEnabled(providerID) {
            report(providerID, [warning])
        }
    }

    private func report(_ providerID: String, _ message: [String]?) {
        let startupWarning = bindings[providerID]?.provider is CodexProvider
            ? executors.codex.startupFailureDescription.map { [$0] } : nil
        publishWarning(providerID, startupWarning ?? message)
    }

    /// 새 응답을 기다리지 않고 이전 시각 기준의 검증·실행 준비를 무효화.
    private func clockDidChange() {
        guard !isShuttingDown, usageTimerSetting.isEnabled else { return }
        activeLaunch?.permission.revoke()
        invalidateObservations()
    }

    private func invalidateObservations() {
        coordinator.invalidateObservations()
        scheduledCheckRequests.formUnion(bindings.keys.filter { isProviderEnabled($0) })
    }

    private func reportStateReadFailure(_ error: Error, providerID: String, accountKey: String) {
        AppDiagnostics.record(
            .weeklyTimer, result: .failure, providerID: providerID, error: error,
            localContext: "Could not check timer observation state")
        coordinator.clearReportedSendLimit(for: accountKey)
        let message =
            activeLaunch == nil
            ? Self.stateReadWarning
            : "Usage timer automation could not update its saved state."
        warningsByAccount[accountKey, default: [:]]["state"] = message
        for (id, binding) in bindings where binding.accountKey == accountKey && isProviderEnabled(id) {
            report(id, warning(for: accountKey))
        }
    }

    private func warning(for accountKey: String) -> [String]? {
        let messages = Set(warningsByAccount[accountKey]?.values.map { $0 } ?? []).sorted()
        return messages.isEmpty ? nil : messages
    }

    private func removeUnboundWarnings() {
        let accountKeys = Set(bindings.filter { isProviderEnabled($0.key) }.compactMap { $0.value.accountKey })
        warningsByAccount = warningsByAccount.filter { accountKeys.contains($0.key) }
    }

    private func isCurrent(_ providerID: String, bindingID: UUID, accountKey: String) -> Bool {
        guard !isShuttingDown, isProviderEnabled(providerID), let binding = bindings[providerID], binding.id == bindingID else { return false }
        return binding.accountKey == accountKey
    }
}
