import Foundation
import Observation

/// 조회·인증 세대·결과 반영 조정. UI는 검증된 결과와 진행 상태만 소비.
@MainActor
@Observable
final class ProviderRefreshCoordinator {
    enum RefreshOutcome: Sendable { case refreshed, failed, cacheHit, skipped, backedOff }
    enum ClaimBinding: Equatable {
        case account(String)
        case unresolvedCatalog(Int)
    }

    private var registry: WidgetRegistry
    private var providersByID: [String: ProviderRuntime]
    private let snapshotStore: ProviderSnapshotStore
    private let refreshWork: ProviderRefreshWork
    private let refreshSchedule: ProviderRefreshSchedule
    private let isProviderEnabled: @MainActor (String) -> Bool
    private let now: () -> Date
    private let monotonicNow: () -> TimeInterval
    private let slowProviderRefreshThreshold: TimeInterval
    private var catalogGeneration = 0
    private var authenticationGenerations: [String: Int] = [:]
    private var invalidatedAuthentication: Set<String> = []
    @ObservationIgnored private var credentialGenerations: [String: Int] = [:]
    @ObservationIgnored private var providersNeedingCredentialRefresh: Set<String> = []
    private var queuedRefreshBatches: [UUID: (providerIDs: Set<String>, force: Bool, trigger: RefreshTrigger)] = [:]

    var localSnapshots: [String: ProviderSnapshot] { snapshotStore.localSnapshots }
    var refreshingProviderIDs: Set<String> { refreshWork.refreshingProviderIDs }
    var scheduledRefreshDates: [String: Date] { refreshSchedule.dates }
    private(set) var refreshResults: [String: ProviderRefreshResult] = [:]
    private(set) var accountReconciliationFailures: [String: ProviderRefreshFailure] = [:]
    var claudeReconciliationFailure: ProviderRefreshFailure? { accountReconciliationFailures["claude"] }
    private(set) var automationWarnings: [String: [String]] = [:]
    var lastRefreshAt: Date?
    nonisolated static let refreshScheduleDidChange = ProviderRefreshSchedule.didChange

    @ObservationIgnored var onRefreshOutcome: (@MainActor (String, RefreshOutcome, ErrorCategory?, RefreshTrigger, Bool) -> Void)?
    @ObservationIgnored var onFreshSnapshot: (@MainActor (ProviderSnapshot, [WidgetDescriptor], RefreshTrigger) -> Void)?
    @ObservationIgnored var isRefreshSuspended: (@MainActor (String) -> Bool)?
    @ObservationIgnored var onQuotaInvalidated: (@MainActor (Set<String>?) -> Void)?
    @ObservationIgnored var onLocalHistoryChanged: (@MainActor () -> Void)?
    @ObservationIgnored var onSnapshotsChanged: (@MainActor (ProviderSnapshotStore.Rendered) -> Void)?
    @ObservationIgnored var onCatalogInvalidated: (@MainActor (Set<String>) -> Void)?

    init(
        registry: WidgetRegistry, providers: [ProviderRuntime], cache: ProviderSnapshotCache,
        isProviderEnabled: @escaping @MainActor (String) -> Bool, now: @escaping () -> Date,
        monotonicNow: @escaping () -> TimeInterval, slowProviderRefreshThreshold: TimeInterval,
        providerRefreshTimeout: TimeInterval, providerIdentityKeys: [String: String],
        familyTotalHistoryCardIDs: Set<String>, workQueue: BackgroundWorkQueue
    ) {
        self.registry = registry
        providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        self.isProviderEnabled = isProviderEnabled
        self.now = now
        self.monotonicNow = monotonicNow
        self.slowProviderRefreshThreshold = slowProviderRefreshThreshold
        snapshotStore = ProviderSnapshotStore(
            registry: registry, cache: cache, identityKeys: providerIdentityKeys,
            familyTotalHistoryCardIDs: familyTotalHistoryCardIDs, isProviderEnabled: isProviderEnabled, now: now
        )
        refreshWork = ProviderRefreshWork(queue: workQueue, timeout: providerRefreshTimeout)
        refreshSchedule = ProviderRefreshSchedule(now: now, monotonicNow: monotonicNow)
    }

    func canRetry(_ providerID: String, credentialGeneration: Int?) -> Bool {
        isProviderEnabled(providerID) && providersByID[providerID] != nil
            && (credentialGeneration == nil || credentialGenerations[providerID] == credentialGeneration)
    }

    var providerNames: [String: String] { providersByID.mapValues { $0.provider.displayName } }

    func refreshAll(
        force: Bool = false, trigger: RefreshTrigger = .scheduled,
        cadence: RefreshSetting.Cadence? = nil
    ) async {
        guard !Task.isCancelled else { return }
        let providerIDs = registry.providers.map(\.id).filter { id in
            guard isProviderEnabled(id) else { return false }
            guard let cadence else { return true }
            return RefreshSetting.cadence(for: id) == cadence && (scheduledRefreshDate(for: id) ?? now()) <= now()
        }
        guard !providerIDs.isEmpty else { return }
        let batchID = UUID()
        queuedRefreshBatches[batchID] = (Set(providerIDs), force, trigger)
        defer { queuedRefreshBatches.removeValue(forKey: batchID) }
        let previousHistories = providerIDs.map { localSnapshots[$0]?.usageHistory }
        let start = monotonicNow()
        AppLog.info(.refresh, "batch start (\(providerIDs.count) providers, force=\(force))")
        var outcomes: [RefreshOutcome] = []
        for providerID in providerIDs {
            guard !Task.isCancelled else { break }
            outcomes.append(await refresh(providerID: providerID, force: force, trigger: trigger, notifyHistoryChange: false))
            queuedRefreshBatches[batchID]?.providerIDs.remove(providerID)
        }
        guard !Task.isCancelled else {
            let historyRemoved = zip(providerIDs, previousHistories).contains { providerID, history in
                history != nil && localSnapshots[providerID]?.usageHistory == nil
            }
            if historyRemoved { onLocalHistoryChanged?() }
            return
        }
        let historyChanged = zip(providerIDs, previousHistories).contains { providerID, history in
            localSnapshots[providerID]?.usageHistory != history
        }
        // 각 갱신 그룹의 완료 기록 — 대상별 다음 일정은 별도 보존.
        lastRefreshAt = now()
        let durationMs = durationMilliseconds(since: start)
        // 이번 일괄 조회의 실제 결과만 집계 — 캐시 사용과 과거 실패를 현재 실패로 중복 집계하지 않음.
        let refreshed = outcomes.count { $0 == .refreshed }
        let failed = outcomes.count { $0 == .failed }
        let cached = outcomes.count { $0 == .cacheHit }
        let backedOff = outcomes.count { $0 == .backedOff }
        if refreshed > 0 || historyChanged {
            onLocalHistoryChanged?()
        }
        AppLog.info(
            .refresh,
            "batch end (\(durationMs)ms, \(refreshed) refreshed / \(failed) failed / \(cached) cached / \(backedOff) backed off)"
        )
    }

    func isRefreshQueued(for providerID: String) -> Bool {
        guard isProviderEnabled(providerID), isRefreshSuspended?(providerID) != true,
              let provider = providersByID[providerID] else { return false }
        if refreshingProviderIDs.contains(providerID) {
            return refreshWork.isWaiting(providerID)
        }
        guard !refreshWork.isPending(provider) else { return false }
        // 대기 배지는 마지막으로 확인한 계정으로 예상. 실제 캐시 사용 전에는 현재 로그인을 다시 읽음.
        let lastKnownIdentity =
            snapshotStore.identityKeys[providerID] ?? localSnapshots[providerID]?.producedByIdentityKey
        return queuedRefreshBatches.values.contains { batch in
            batch.providerIDs.contains(providerID)
                && refreshCacheHit(
                    providerID: providerID, force: batch.force, trigger: batch.trigger,
                    currentIdentityKey: lastKnownIdentity) == nil
                && !refreshSchedule.isBackedOff(providerID, force: batch.force)
        }
    }

    func scheduledRefreshDate(for providerID: String) -> Date? {
        refreshSchedule.date(for: providerID, usageRetryAfter: localSnapshots[providerID]?.usageRetryAfter)
    }

    func nextScheduledRefresh(for cadence: RefreshSetting.Cadence, at date: Date) -> Date? {
        registry.providers.map(\.id).filter {
            isProviderEnabled($0) && RefreshSetting.cadence(for: $0) == cadence
                && isRefreshSuspended?($0) != true && !refreshingProviderIDs.contains($0)
                && providersByID[$0].map { !refreshWork.isPending($0) } == true
        }.map { scheduledRefreshDate(for: $0) ?? date }.min()
    }

    func rebaseRefreshSchedule(for cadence: RefreshSetting.Cadence, at date: Date, clockChangedAt: TimeInterval) {
        refreshSchedule.rebase(
            providerIDs: registry.providers.map(\.id).filter { RefreshSetting.cadence(for: $0) == cadence },
            at: date, clockChangedAt: clockChangedAt
        )
    }

    func waitForAccountRefreshes(providerIDs: Set<String>) async {
        await refreshWork.waitUntilIdle(providerIDs: providerIDs)
    }

    @discardableResult
    func credentialsDidChange(for providerID: String) -> Int {
        let generation = credentialGenerations[providerID, default: 0] + 1
        credentialGenerations[providerID] = generation
        if providersByID[providerID] is DeepSeekProvider || providersByID[providerID] is OpenAICostsProvider,
            snapshotStore.discardMismatchedReading(for: providerID, currentIdentityKey: nil)
        {
            rebuildRenderedSnapshots()
        }
        snapshotStore.invalidateLiveQuota(for: providerID)
        onQuotaInvalidated?([providerID])
        providersNeedingCredentialRefresh.insert(providerID)
        refreshResults[providerID] = nil
        clearFailureBackoff(for: providerID)
        return generation
    }

    func claimRefreshBinding(providerID: String) -> ClaimBinding? {
        guard providersByID[providerID] != nil else { return nil }
        if let identityKey = snapshotStore.identityKeys[providerID] { return .account(identityKey) }
        return .unresolvedCatalog(catalogGeneration)
    }

    func replaceProviderCatalog(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        identityKeys: [String: String],
        familyTotalHistoryCardIDs: Set<String> = []
    ) {
        let liveIDs = Set(registry.providers.map(\.id))
        // 관리 계정 전환은 claude·codex 기본 카드 ID를 유지하고 인증 연결만 교체.
        // 인증 연결이 달라지면 이전 조회 결과·오류·실패 대기 제거.
        // 새 계정에 이전 계정의 상태가 이어지지 않도록 처리.
        let previousIdentityKeys = snapshotStore.identityKeys
        func keepsState(_ cardID: String) -> Bool {
            guard liveIDs.contains(cardID) else { return false }
            return previousIdentityKeys[cardID] == identityKeys[cardID]
        }
        // 계정 식별 정보가 없으면 동일 계정을 확인할 수 없으므로 카탈로그 교체 시 알림도 무효화.
        let invalidatedAccounts = Set(
            providersByID.keys.filter { cardID in
                !keepsState(cardID)
                    || (identityKeys[cardID] == nil
                        && ProviderAccountID.families.contains(ProviderAccountID.family(of: cardID)))
            })
        onCatalogInvalidated?(invalidatedAccounts)
        catalogGeneration += 1
        onQuotaInvalidated?(invalidatedAccounts)
        self.registry = registry
        self.providersByID = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, $0) })
        let discardedSnapshotIDs = snapshotStore.replaceCatalog(
            registry: registry, identityKeys: identityKeys, familyTotalHistoryCardIDs: familyTotalHistoryCardIDs
        )
        refreshResults = refreshResults.filter { keepsState($0.key) }
        accountReconciliationFailures = accountReconciliationFailures.filter { keepsState($0.key) }
        automationWarnings = automationWarnings.filter { keepsState($0.key) }
        authenticationGenerations = authenticationGenerations.filter { liveIDs.contains($0.key) }
        invalidatedAuthentication.formIntersection(liveIDs)
        refreshSchedule.retain(liveIDs: liveIDs, discardedSnapshotIDs: discardedSnapshotIDs, keepsState: keepsState)
        rebuildRenderedSnapshots()
        NotificationCenter.default.post(name: Self.refreshScheduleDidChange, object: nil)
    }

    func setExternalProviderError(
        _ message: String, for providerID: String, presentation: LocalizedMessage? = nil
    ) {
        guard providersByID[providerID] != nil else {
            AppLog.error(.refresh, "external provider error targeted an unknown provider")
            return
        }
        snapshotStore.invalidateLiveQuota(for: providerID)
        onQuotaInvalidated?([providerID])
        refreshResults[providerID] = .failed(ProviderRefreshFailure(message: message, presentation: presentation))
    }

    /// Claude 로그인 반영은 사용량 조회와 독립적으로 성공하거나 실패.
    func setClaudeReconciliationFailure(_ failure: ProviderRefreshFailure?) {
        setAccountReconciliationFailure(failure, for: "claude")
    }

    func setAccountReconciliationFailure(_ failure: ProviderRefreshFailure?, for family: String) {
        guard accountReconciliationFailures[family] != failure else { return }
        accountReconciliationFailures[family] = failure
        if failure != nil {
            snapshotStore.invalidateLiveQuota(for: family)
            onQuotaInvalidated?([family])
        }
    }

    private func refreshCacheHit(
        providerID: String, force: Bool, trigger: RefreshTrigger, currentIdentityKey: String?
    ) -> ProviderSnapshot? {
        guard !force, !refreshSchedule.requiresScheduledRefresh(providerID, trigger: trigger),
              !invalidatedAuthentication.contains(providerID),
            !providersNeedingCredentialRefresh.contains(providerID)
        else { return nil }
        return snapshotStore.cachedSnapshot(for: providerID, currentIdentityKey: currentIdentityKey)
    }

    @discardableResult
    func refresh(
        providerID: String,
        force: Bool = false,
        trigger: RefreshTrigger = .scheduled,
        notifyHistoryChange: Bool = true,
        codexBinding: CodexResetClaimBinding? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> RefreshOutcome {
        guard !Task.isCancelled, isCurrent(), isProviderEnabled(providerID) else { return .skipped }
        guard isRefreshSuspended?(providerID) != true else { return .skipped }
        let family = AppLog.providerFamily(providerID)
        var cacheIdentity = snapshotStore.identityKeys[providerID]
        if !force || providerID == "openai-api",
            let runtime = providersByID[providerID] as? any CredentialBoundSnapshotProvider,
            let snapshot = snapshotStore.localSnapshots[providerID]
        {
            let generation = catalogGeneration
            let credentialGeneration = credentialGenerations[providerID, default: 0]
            cacheIdentity = await runtime.currentIdentityKey(allowKeychainInteraction: true)
            guard !Task.isCancelled, isCurrent(), generation == catalogGeneration, isProviderEnabled(providerID),
                isRefreshSuspended?(providerID) != true,
                credentialGeneration == credentialGenerations[providerID, default: 0],
                snapshotStore.localSnapshots[providerID] == snapshot
            else { return .skipped }
            if snapshotStore.discardMismatchedReading(for: providerID, currentIdentityKey: cacheIdentity) {
                credentialsDidChange(for: providerID)
                rebuildRenderedSnapshots()
            }
        }
        if let cached = refreshCacheHit(
            providerID: providerID, force: force, trigger: trigger, currentIdentityKey: cacheIdentity)
        {
            // 값이 같으면 재할당 생략 — Observable의 불필요한 메뉴 막대 재렌더링 방지.
            AppLog.debug(.refresh, "cache hit \(family)")
            if snapshotStore.useCachedSnapshot(cached) { rebuildRenderedSnapshots() }
            refreshSchedule.reusedCache(cached, trigger: trigger)
            return .cacheHit
        }
        if !force { AppLog.debug(.refresh, "cache miss \(family)") }

        // 현재 실패는 이력 캐시와 무관하게 대기 만료 후 재조회 — 수동 강제 갱신은 대기 무시.
        if refreshSchedule.isBackedOff(providerID, force: force) {
            AppLog.debug(
                .refresh,
                "backoff skip \(family) (failed <\(Int(ProviderRefreshSchedule.failureRetryBackoff))s ago)")
            return .backedOff
        }

        guard let provider = providersByID[providerID] else { return .skipped }
        guard let lease = refreshWork.begin(provider) else {
            AppLog.debug(.refresh, "skipped \(family) (previous provider work has not finished)")
            return .skipped
        }
        var needsScheduleWake = trigger != .scheduled && RefreshSetting.cadence(for: providerID) == .claude
        defer { refreshWork.finish(lease, wakeSchedule: needsScheduleWake) }
        var boundGeneration = catalogGeneration
        var authenticationGeneration = authenticationGenerations[providerID, default: 0]
        var boundCredentialGeneration = credentialGenerations[providerID, default: 0]
        var start: TimeInterval = 0
        guard
            let result = await refreshWork.run(
                lease, provider: provider, trigger: trigger, isCurrent: isCurrent,
                prepare: {
                    guard self.isProviderEnabled(providerID), self.isRefreshSuspended?(providerID) != true,
                        self.providersByID[providerID] === provider
                    else { return false }
                    boundGeneration = self.catalogGeneration
                    authenticationGeneration = self.authenticationGenerations[providerID, default: 0]
                    boundCredentialGeneration = self.credentialGenerations[providerID, default: 0]
                    start = self.monotonicNow()
                    return true
                })
        else { return .skipped }
        var snapshot: ProviderSnapshot
        switch result {
        case .snapshot(let value):
            snapshot = value
        case .timedOut:
            let timeout = ProviderSnapshot.error(
                provider: provider.provider,
                message: "Refresh timed out. Retrying is available after the previous request finishes.",
                category: .network,
                presentation: .init("Refresh timed out. Retrying is available after the previous request finishes.")
            )
            snapshot = timeout
            if let runtime = provider as? any CredentialBoundSnapshotProvider {
                // 제한 시간 뒤에는 현재 로그인만 짧게 확인. 확인한 계정의 캐시만 표시.
                let verification = await ProviderRefreshDeadline.run(timeout: .seconds(1)) {
                    var verified = timeout
                    verified.producedByIdentityKey = await runtime.currentIdentityKey(allowKeychainInteraction: false)
                    return verified
                }
                if case .snapshot(let verified) = verification { snapshot = verified }
            }
        case .cancelled:
            needsScheduleWake = true
            return .skipped
        }
        // 취소 후 반환된 조회 결과는 반영하지 않고 마지막 정상 결과 유지.
        guard !Task.isCancelled else {
            needsScheduleWake = true
            AppLog.debug(.refresh, "cancelled \(family) refresh; keeping last-good snapshot")
            return .skipped
        }
        guard isCurrent() else {
            needsScheduleWake = true
            return .skipped
        }
        // 조회 중 카탈로그가 바뀌면 결과 폐기 — 같은 카드 ID가 다른 계정을 가리킬 수 있음.
        // 이전 계정 결과를 새 인증에 귀속하지 않으며 전환 경로에서 선택 카드를 강제 재조회.
        guard isProviderEnabled(providerID), catalogGeneration == boundGeneration,
              authenticationGenerations[providerID, default: 0] == authenticationGeneration else {
            needsScheduleWake = true
            AppLog.info(
                .refresh, "\(family) discarding result: the provider catalog or authentication changed mid-fetch")
            AppDiagnostics.record(.accountBinding, result: .bindingChanged, providerID: providerID)
            return .skipped
        }
        guard credentialGenerations[providerID, default: 0] == boundCredentialGeneration else {
            needsScheduleWake = true
            AppLog.info(.refresh, "\(family) discarding result: credentials changed mid-fetch")
            return .skipped
        }
        if let codexBinding, snapshot.refreshFailure == nil,
           snapshot.codexResetClaimBinding != codexBinding {
            snapshot = .error(
                provider: provider.provider,
                message: "The refreshed account no longer matches the reset confirmation. Refresh usage before trying again.",
                category: .authInvalid,
                presentation: .init("The refreshed account no longer matches the reset confirmation. Refresh usage before trying again.")
            )
        }
        refreshSchedule.attempted(providerID, trigger: trigger)
        let durationMs = durationMilliseconds(since: start)
        if TimeInterval(durationMs) >= slowProviderRefreshThreshold * 1000 {
            AppLog.warn(
                .refresh,
                "\(family) slow refresh (\(durationMs)ms, threshold=\(Int(slowProviderRefreshThreshold * 1000))ms)"
            )
        }
        let context = "provider=\(family) trigger=\(trigger.rawValue) duration_ms=\(durationMs)"
        switch snapshotStore.accept(snapshot, from: provider) {
        case .failed(let failure, let render, let historyChanged):
            refreshResults[providerID] = .failed(failure)
            refreshSchedule.failed(providerID)
            if snapshot.invalidatesQuotaIdentity { onQuotaInvalidated?([providerID]) }
            if render { rebuildRenderedSnapshots() }
            if historyChanged, notifyHistoryChange { onLocalHistoryChanged?() }
            var diagnostic = "result=failure \(context) category=\(failure.category.rawValue)"
            if case .timedOut = result { diagnostic += " reason=timeout" }
            if failure.category == .notLoggedIn || failure.category == .notAvailable {
                AppLog.info(.refresh, diagnostic)
            } else {
                AppLog.error(.refresh, diagnostic)
            }
            onRefreshOutcome?(providerID, .failed, failure.category, trigger, false)
            return .failed
        case .succeeded(let accepted, let degraded):
            let hasReconciliationFailure = accountReconciliationFailures[providerID] != nil
            if hasReconciliationFailure { snapshotStore.invalidateLiveQuota(for: providerID) }
            refreshResults[providerID] = .succeeded
            invalidatedAuthentication.remove(providerID)
            providersNeedingCredentialRefresh.remove(providerID)
            refreshSchedule.succeeded(
                accepted, trigger: trigger, unresolvedIdentity: snapshotStore.isUnresolvedClaude(providerID))
            rebuildRenderedSnapshots()
            if notifyHistoryChange { onLocalHistoryChanged?() }
            let category = accepted.partialRefreshErrorCategory
            if degraded {
                AppLog.warn(.refresh, "result=degraded \(context) category=\(category?.rawValue ?? "none")")
            } else {
                AppLog.info(.refresh, "result=success \(context)")
            }
            onRefreshOutcome?(providerID, .refreshed, category, trigger, degraded)
            if !hasReconciliationFailure { onFreshSnapshot?(accepted, provider.widgetDescriptors, trigger) }
            return .refreshed
        }
    }

    private func durationMilliseconds(since start: TimeInterval) -> Int {
        max(0, Int((monotonicNow() - start) * 1000))
    }

    func clearFailureBackoff(for providerID: String) {
        refreshSchedule.clear(providerID)
    }

    func providerEnablementDidChange() {
        for id in registry.providers.map(\.id) where !isProviderEnabled(id) {
            authenticationGenerations[id, default: 0] += 1
        }
        onQuotaInvalidated?(nil)
        rebuildRenderedSnapshots()
    }

    func setPeerHistoryDocuments(_ documents: [UsageHistoryDocument], ownDeviceID: String) {
        snapshotStore.setPeerHistoryDocuments(documents, ownDeviceID: ownDeviceID)
        rebuildRenderedSnapshots()
    }

    func clearPeerHistoryDocuments() {
        if snapshotStore.clearPeerHistoryDocuments() { rebuildRenderedSnapshots() }
    }

    func localHistoryDocument(
        deviceID: String, deviceName: String, updatedAt: Date = Date(),
        preserving previous: UsageHistoryDocument? = nil
    ) -> UsageHistoryDocument {
        snapshotStore.localHistoryDocument(
            deviceID: deviceID, deviceName: deviceName, updatedAt: updatedAt, preserving: previous)
    }

    private func rebuildRenderedSnapshots() {
        onSnapshotsChanged?(snapshotStore.rendered(refreshResults: refreshResults))
    }

    func invalidateAuthentication(for providerID: String) {
        refreshSchedule.clear(providerID)
        guard providersByID[providerID] != nil else { return }
        authenticationGenerations[providerID, default: 0] &+= 1
        snapshotStore.invalidateLiveQuota(for: providerID)
        onQuotaInvalidated?([providerID])
        invalidatedAuthentication.insert(providerID)
        refreshResults[providerID] = nil
        accountReconciliationFailures[providerID] = nil
        if snapshotStore.invalidateAuthentication(for: providerID) { rebuildRenderedSnapshots() }
    }

    func setAutomationWarning(_ message: [String]?, for providerID: String) {
        guard providersByID[providerID] != nil else { return }
        automationWarnings[providerID] = message
    }

}
