import Foundation
import Observation

/// 오래된 조회 결과 안내 — 짧은 Outdated 라벨과 경과 시간을 담은 툴팁.
struct StalenessHint: Equatable {
    let label: String
    let tooltip: String
}

@MainActor
@Observable
final class WidgetDataStore {
    private var registry: WidgetRegistry
    private let refreshCoordinator: ProviderRefreshCoordinator
    private let cache: ProviderSnapshotCache
    private let defaults: UserDefaults
    /// 프로바이더 활성화 여부 조회 — 테스트·미리보기의 기본값은 모두 활성.
    private let isProviderEnabled: @MainActor (String) -> Bool
    /// 대시보드의 사용자 지표 순서 — 할당량 알림 입력이며 기본값은 등록 순서.
    private let orderedDescriptors: @MainActor () -> [WidgetDescriptor]
    /// 표시 시각 판정에 쓰는 주입식 시계.
    private let now: () -> Date
    /// 할당량 알림 설정 — nil이면 알림 비활성.
    private let notificationSettings: (@MainActor () -> NotificationSettingsStore)?
    /// Soft Limit 표시 설정 — nil이면 안내선 없음.
    private let softLimitSettings: (@MainActor () -> SoftLimitSettingsStore)?
    /// 할당량 알림의 계정명 조회 — 결과가 nil이면 프로바이더 이름 사용.
    @ObservationIgnored var resolveDisplayName: (@MainActor (String) -> String?)?
    @ObservationIgnored var resolveCreditAccountName:
        (@MainActor (_ profileID: String, _ workspace: String) -> String?)?
    /// 조건별 알림 전달 — false이면 전송 완료로 기록하지 않고 다음 평가에서 재시도.
    private let postNotification: QuotaNotificationEvaluator.Post

    private static let meterStyleKey = "meterStyle"
    private static let resetDisplayModeKey = "resetDisplayMode"
    private static let showsAccountEmailsKey = "showsAccountEmails"
    private static let sharedCodexHome = URL(
        fileURLWithPath: AccountCredentialSwitcher().sharedHomePath(family: "codex"))
    static let defaultSlowProviderRefreshThreshold: TimeInterval = 10
    static let defaultProviderRefreshTimeout: TimeInterval = 120

    /// 화면·API용 조회 결과 — iCloud 동기화가 꺼져 있으면 로컬 원본, 켜져 있으면 다른 Mac의 이력 합산.
    var snapshots: [String: ProviderSnapshot] = [:] {
        didSet { latchBurningFast(at: now(), previousSnapshots: oldValue) }
    }
    let displaySettings: DisplaySettingsStore
    private(set) var burningFastWindows: [String: Date] = [:]
    var burningFast: BurningFast? {
        displaySettings.showsBurningFast ? BurningFast(latched: burningFastWindows) : nil
    }
    /// 현재 Mac의 마지막 정상 결과 — 캐시·iCloud에는 원본만 저장하여 다른 Mac의 이력 중복 전파 방지.
    var localSnapshots: [String: ProviderSnapshot] { refreshCoordinator.localSnapshots }
    /// 인증·사용량 조회와 독립된 공개 Reset Watch 값 — 모든 Codex 카드가 공유.
    private var codexResetWatch = CodexResetWatchResult()
    var refreshingProviderIDs: Set<String> { refreshCoordinator.refreshingProviderIDs }
    /// 마지막 사용량 배치 종료 시각. 첫 배치 전에는 nil.
    var lastRefreshAt: Date? {
        get { refreshCoordinator.lastRefreshAt }
        set { refreshCoordinator.lastRefreshAt = newValue }
    }
    var scheduledRefreshDates: [String: Date] { refreshCoordinator.scheduledRefreshDates }
    var nextGeneralRefreshAt: Date?
    nonisolated static let refreshScheduleDidChange = ProviderRefreshSchedule.didChange
    var accountReconciliationNotice: String?
    var claudeReconciliationFailure: ProviderRefreshFailure? { refreshCoordinator.claudeReconciliationFailure }
    func reconciliationFailure(for cardID: String) -> ProviderRefreshFailure? {
        refreshCoordinator.accountReconciliationFailures[cardID]
    }
    func clearCodexReconciliationFailure(for priorCardID: String?) {
        if let priorCardID {
            setAccountReconciliationFailure(nil, for: priorCardID)
        } else {
            let cardIDs = refreshCoordinator.accountReconciliationFailures.keys.filter {
                ProviderAccountID.family(of: $0) == "codex"
            }
            for cardID in cardIDs {
                setAccountReconciliationFailure(nil, for: cardID)
            }
        }
    }
    var codexReconciliationFailure: ProviderRefreshFailure? { reconciliationFailure(for: "codex") }
    var refreshResults: [String: ProviderRefreshResult] {
        var results = refreshCoordinator.refreshResults
        for (family, failure) in refreshCoordinator.accountReconciliationFailures { results[family] = .failed(failure) }
        return results
    }
    var providerErrors: [String: String] {
        refreshResults.compactMapValues { $0.failure?.message }
    }
    @ObservationIgnored private var creditExpiryReminders: CodexCreditExpiryReminders?
    /// 할당량 알림 평가기 — 저장소는 순회마다 활성 한도 지표를 수집하여 전달.
    @ObservationIgnored private let notificationEvaluator = QuotaNotificationEvaluator()
    @ObservationIgnored private var isEvaluatingNotifications = false
    @ObservationIgnored private var pendingNotificationEvaluationAt: Date?

    /// 실제 조회의 성공·실패마다 한 번 호출하는 통계 콜백 — 캐시 사용·생략·실패 대기는 제외.
    /// 테스트·미리보기에서는 nil로 전달 생략.
    var onRefreshOutcome: (@MainActor (String, RefreshOutcome, ErrorCategory?, RefreshTrigger, Bool) -> Void)?
    /// GUI의 한도 자동 제어 입력 — 캐시·실패·취소·카탈로그 변경으로 폐기된 결과 제외.
    var onFreshSnapshot: (@MainActor (ProviderSnapshot, [WidgetDescriptor], RefreshTrigger) -> Void)?
    var isRefreshSuspended: (@MainActor (String) -> Bool)? {
        get { refreshCoordinator.isRefreshSuspended }
        set { refreshCoordinator.isRefreshSuspended = newValue }
    }
    var onQuotaInvalidated: (@MainActor (Set<String>?) -> Void)?
    /// 로컬 이력 변경 콜백 — ICloudUsageSyncStore에서 연속 변경을 병합하여 파일 한 번 작성.
    var onLocalHistoryChanged: (@MainActor () -> Void)? {
        get { refreshCoordinator.onLocalHistoryChanged }
        set { refreshCoordinator.onLocalHistoryChanged = newValue }
    }
    /// 다른 Mac에서 동기화한 원격 전용 계정 — 현재 Mac에 카드가 없으면 Total Spend에만 표시.
    private(set) var remoteOnlySpend: [(provider: Provider, snapshot: ProviderSnapshot)] = []

    /// 전역 사용량·잔여량 표시 설정 — 저장하며 기본값은 used.
    var meterStyle: WidgetDisplayMode {
        didSet { defaults.set(meterStyle.rawValue, forKey: Self.meterStyleKey) }
    }

    /// 전역 초기화 시간 표시 설정 — 상대 시간·절대 시각 중 저장하며 기본값은 absolute.
    var resetDisplayMode: ResetDisplayMode {
        didSet { defaults.set(resetDisplayMode.rawValue, forKey: Self.resetDisplayModeKey) }
    }

    /// 기존 표시 설정의 진입점 — 공통 Pace Marks 저장값 사용.
    var alwaysShowPacing: Bool {
        get { displaySettings.showsPaceMarks }
        set { displaySettings.showsPaceMarks = newValue }
    }

    /// 계정명 대신 로그인 이메일 표시 — 저장하며 기본은 꺼짐, 계정명 클릭으로 전환.
    var showsAccountEmails: Bool {
        didSet { defaults.set(showsAccountEmails, forKey: Self.showsAccountEmailsKey) }
    }

    init(
        registry: WidgetRegistry,
        providers: [ProviderRuntime],
        cache: ProviderSnapshotCache = ProviderSnapshotCache(),
        defaults: UserDefaults = .standard,
        isProviderEnabled: @escaping @MainActor (String) -> Bool = { _ in true },
        orderedDescriptors: (@MainActor () -> [WidgetDescriptor])? = nil,
        now: @escaping () -> Date = Date.init,
        monotonicNow: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        slowProviderRefreshThreshold: TimeInterval = WidgetDataStore.defaultSlowProviderRefreshThreshold,
        providerRefreshTimeout: TimeInterval = WidgetDataStore.defaultProviderRefreshTimeout,
        notificationSettings: (@MainActor () -> NotificationSettingsStore)? = nil,
        softLimitSettings: (@MainActor () -> SoftLimitSettingsStore)? = nil,
        postNotification: QuotaNotificationEvaluator.Post? = nil,
        providerIdentityKeys: [String: String] = [:],
        familyTotalHistoryCardIDs: Set<String> = [],
        resolveDisplayName: (@MainActor (String) -> String?)? = nil,
        displaySettings: DisplaySettingsStore? = nil,
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) {
        precondition(slowProviderRefreshThreshold >= 0)
        precondition(providerRefreshTimeout.isFinite && providerRefreshTimeout > 0)
        self.registry = registry
        self.cache = cache
        self.defaults = defaults
        self.isProviderEnabled = isProviderEnabled
        self.orderedDescriptors = orderedDescriptors ?? { registry.descriptors }
        self.now = now
        self.notificationSettings = notificationSettings
        self.softLimitSettings = softLimitSettings
        self.postNotification = postNotification
            ?? { idPrefix, title, subtitle, body, isCurrent in
                await AppNotifications.shared.post(
                    idPrefix: idPrefix, title: title, subtitle: subtitle, body: body, isCurrent: isCurrent
                )
            }
        self.refreshCoordinator = ProviderRefreshCoordinator(
            registry: registry, providers: providers, cache: cache, isProviderEnabled: isProviderEnabled,
            now: now, monotonicNow: monotonicNow, slowProviderRefreshThreshold: slowProviderRefreshThreshold,
            providerRefreshTimeout: providerRefreshTimeout, providerIdentityKeys: providerIdentityKeys,
            familyTotalHistoryCardIDs: familyTotalHistoryCardIDs, workQueue: workQueue
        )
        self.resolveDisplayName = resolveDisplayName
        self.meterStyle = defaults.enumValue(forKey: Self.meterStyleKey, default: .used)
        self.resetDisplayMode = defaults.enumValue(forKey: Self.resetDisplayModeKey, default: .absolute)
        self.showsAccountEmails = defaults.bool(forKey: Self.showsAccountEmailsKey)
        self.displaySettings = displaySettings ?? DisplaySettingsStore(defaults: defaults)
        self.snapshots = refreshCoordinator.localSnapshots
        refreshCoordinator.onSnapshotsChanged = { [weak self] rendered in
            self?.remoteOnlySpend = rendered.remoteOnlySpend
            self?.snapshots = rendered.snapshots
            if self?.notificationSettings?().codexCreditExpiry == true { self?.updateCodexCreditReminders() }
        }
        refreshCoordinator.onRefreshOutcome = { [weak self] id, outcome, category, trigger, degraded in
            guard let self else { return }
            if outcome == .failed, category == .authExpired || category == .authInvalid || category == .notLoggedIn {
                self.invalidateCreditReminders([id])
            }
            self.onRefreshOutcome?(id, outcome, category, trigger, degraded)
        }
        refreshCoordinator.onQuotaInvalidated = { [weak self] ids in
            guard let self else { return }
            if let ids { self.invalidateCreditReminders(ids) }
            self.onQuotaInvalidated?(ids)
        }
        refreshCoordinator.onFreshSnapshot = { [weak self] snapshot, descriptors, trigger in
            guard let self else { return }
            if self.creditExpiryReminders?.accept(snapshot) == true,
                self.notificationSettings?().codexCreditExpiry == true
            {
                self.updateCodexCreditReminders()
            }
            self.onFreshSnapshot?(snapshot, descriptors, trigger)
        }
        refreshCoordinator.onCatalogInvalidated = { [weak self] ids in
            self?.notificationEvaluator.reset(providerIDs: ids)
        }
    }

    private func invalidateCreditReminders(_ ids: Set<String>) {
        guard let creditExpiryReminders else { return }
        creditExpiryReminders.invalidate(ids)
        if notificationSettings?().codexCreditExpiry == true { updateCodexCreditReminders() }
    }

    func configureCodexCreditReminders(scheduler: ScheduledReminders) {
        guard let settings = notificationSettings?() else { return }
        creditExpiryReminders = CodexCreditExpiryReminders(scheduler: scheduler, defaults: defaults)
        settings.onCodexCreditExpiryChange = { [weak self] in self?.updateCodexCreditReminders() }
        updateCodexCreditReminders()
    }

    func codexCreditsUnavailable(cardID: String, credits: CodexResetClaimService.UnavailableCredits) {
        guard let creditExpiryReminders, let snapshot = localSnapshots[cardID],
            let binding = snapshot.codexResetClaimBinding, let account = creditReminderAccount(snapshot)
        else { return }
        switch credits {
        case .credit(let credit) where credit.binding == binding:
            creditExpiryReminders.consumed(
                account: account, expiry: credit.expiry, creditID: credit.creditID,
                remaining: credit.remainingAtExpiry, at: now())
        case .expiry(let confirmedBinding, let date) where confirmedBinding == binding:
            creditExpiryReminders.noneAvailable(account: account, expiry: date, at: now())
        default: return
        }
        updateCodexCreditReminders()
    }

    private func creditReminderAccount(_ snapshot: ProviderSnapshot) -> String? {
        if case .account(let workspace) = claimRefreshBinding(providerID: snapshot.providerID),
            snapshot.codexSwitchIdentity != workspace
        {
            return nil
        }
        return snapshot.liveQuotaAccountKey
    }

    private func creditReminderName(_ snapshot: ProviderSnapshot) -> String? {
        guard case .accountSnapshot(let profileID) = snapshot.codexResetClaimBinding?.source,
            snapshot.providerID == AccountUsageCardPlanner.cardID(family: "codex", profileID: profileID),
            let workspace = snapshot.codexSwitchIdentity
        else { return nil }
        return resolveCreditAccountName?(profileID, workspace)
    }

    private func updateCodexCreditReminders() {
        guard let creditExpiryReminders else { return }
        creditExpiryReminders.retainCards(Set(knownProviderIDs))
        let enabled = notificationSettings?().codexCreditExpiry == true
        let accounts = localSnapshots.compactMap { id, snapshot -> (String, String, ProviderSnapshot)? in
            guard enabled, ProviderAccountID.family(of: id) == "codex", isProviderEnabled(id),
                !creditExpiryReminders.invalidatedCards.contains(id), reconciliationFailure(for: id) == nil,
                let account = creditReminderAccount(snapshot)
            else { return nil }
            let provider = ProviderAccountID.cardTitle(providerID: id, fallback: snapshot.displayName)
            let name = creditReminderName(snapshot) ?? provider
            return (account, name, snapshot)
        }
        creditExpiryReminders.reconcile(accounts: accounts, now: now())
    }

    /// 활성 프로바이더 순차 갱신 — force는 정상 캐시와 실패 대기 우회.
    func refreshAll(force: Bool = false, trigger: RefreshTrigger = .scheduled, cadence: RefreshSetting.Cadence? = nil) async {
        await refreshCoordinator.refreshAll(force: force, trigger: trigger, cadence: cadence)
        if trigger == .manual { await evaluateNotifications(now: now()) }
    }

    @discardableResult
    func refresh(
        providerID: String, force: Bool = false, trigger: RefreshTrigger = .scheduled,
        notifyHistoryChange: Bool = true, codexBinding: CodexResetClaimBinding? = nil,
        isCurrent: @escaping @MainActor () -> Bool = { true }
    ) async -> RefreshOutcome {
        let outcome = await refreshCoordinator.refresh(
            providerID: providerID, force: force, trigger: trigger,
            notifyHistoryChange: notifyHistoryChange, codexBinding: codexBinding, isCurrent: isCurrent)
        if trigger == .manual, outcome == .refreshed { await evaluateNotifications(now: now()) }
        return outcome
    }

    func isRefreshQueued(for providerID: String) -> Bool { refreshCoordinator.isRefreshQueued(for: providerID) }
    func scheduledRefreshDate(for providerID: String) -> Date? {
        refreshCoordinator.scheduledRefreshDate(for: providerID)
    }
    func nextScheduledRefresh(for cadence: RefreshSetting.Cadence, at date: Date) -> Date? {
        refreshCoordinator.nextScheduledRefresh(for: cadence, at: date)
    }

    func rebaseRefreshSchedule(for cadence: RefreshSetting.Cadence, at date: Date, clockChangedAt: TimeInterval) {
        refreshCoordinator.rebaseRefreshSchedule(for: cadence, at: date, clockChangedAt: clockChangedAt)
    }

    /// 호출자 취소 후에도 해당 계정의 실제 작업·결과 반영 종료까지 대기.
    func waitForAccountRefreshes(providerIDs: Set<String>) async {
        await refreshCoordinator.waitForAccountRefreshes(providerIDs: providerIDs)
    }

    /// 새 Task를 만들기 전에 이전 키로 시작한 조회를 무효화.
    @discardableResult
    func credentialsDidChange(for providerID: String) -> Int {
        refreshCoordinator.credentialsDidChange(for: providerID)
    }
    func claimRefreshBinding(providerID: String) -> ClaimRefreshBinding? {
        refreshCoordinator.claimRefreshBinding(providerID: providerID)
    }

    func replaceProviderCatalog(
        registry: WidgetRegistry, providers: [ProviderRuntime], identityKeys: [String: String],
        familyTotalHistoryCardIDs: Set<String> = []
    ) {
        self.registry = registry
        refreshCoordinator.replaceProviderCatalog(
            registry: registry, providers: providers,
            identityKeys: identityKeys, familyTotalHistoryCardIDs: familyTotalHistoryCardIDs)
    }

    func setExternalProviderError(_ message: String, for providerID: String, presentation: LocalizedMessage? = nil) {
        refreshCoordinator.setExternalProviderError(message, for: providerID, presentation: presentation)
    }

    func setClaudeReconciliationFailure(_ failure: ProviderRefreshFailure?) {
        refreshCoordinator.setClaudeReconciliationFailure(failure)
    }

    func setAccountReconciliationFailure(_ failure: ProviderRefreshFailure?, for family: String) {
        refreshCoordinator.setAccountReconciliationFailure(failure, for: family)
    }

    func clearFailureBackoff(for providerID: String) { refreshCoordinator.clearFailureBackoff(for: providerID) }
    func providerEnablementDidChange() { refreshCoordinator.providerEnablementDidChange() }
    func invalidateAuthentication(for providerID: String) {
        refreshCoordinator.invalidateAuthentication(for: providerID)
    }
    func setAutomationWarning(_ message: [String]?, for providerID: String) {
        refreshCoordinator.setAutomationWarning(message, for: providerID)
    }

    func setPeerHistoryDocuments(_ documents: [UsageHistoryDocument], ownDeviceID: String) {
        refreshCoordinator.setPeerHistoryDocuments(documents, ownDeviceID: ownDeviceID)
    }

    func clearPeerHistoryDocuments() { refreshCoordinator.clearPeerHistoryDocuments() }
    func localHistoryDocument(
        deviceID: String, deviceName: String, updatedAt: Date = Date(),
        preserving previous: UsageHistoryDocument? = nil
    ) -> UsageHistoryDocument {
        refreshCoordinator.localHistoryDocument(
            deviceID: deviceID, deviceName: deviceName, updatedAt: updatedAt, preserving: previous)
    }

    func refreshAfterAccountSelection(
        providerID: String,
        maxAttempts: Int = 45,
        retryDelay: Duration = .seconds(1)
    ) async {
        await refreshAfterSelection(providerID: providerID, trigger: .accountChange,
                                    maxAttempts: maxAttempts, retryDelay: retryDelay)
    }

    func refreshAfterWeeklyTimer(providerID: String, isCurrent: @escaping @MainActor () -> Bool) async {
        for _ in 0..<15 {
            guard !Task.isCancelled, isCurrent() else { return }
            let outcome = await refresh(
                providerID: providerID, force: true, trigger: .weeklyTimer, isCurrent: isCurrent)
            guard outcome == .skipped, isCurrent() else { return }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
        AppDiagnostics.record(.weeklyTimer, result: .failure, providerID: providerID,
                              localContext: "Post-timer refresh kept being skipped")
    }

    /// 키 변경 직후의 조회 — 더 새 키 변경이 발생하면 이전 재시도 종료.
    func refreshAfterCredentialChange(
        providerID: String,
        credentialGeneration: Int,
        maxAttempts: Int = 45,
        retryDelay: Duration = .seconds(1)
    ) async {
        await refreshAfterSelection(providerID: providerID, trigger: .credentialChange,
                                    credentialGeneration: credentialGeneration,
                                    maxAttempts: maxAttempts, retryDelay: retryDelay)
    }

    private func refreshAfterSelection(
        providerID: String,
        trigger: RefreshTrigger,
        credentialGeneration: Int? = nil,
        maxAttempts: Int,
        retryDelay: Duration
    ) async {
        precondition(maxAttempts > 0)
        for attempt in 0..<maxAttempts {
            guard !Task.isCancelled,
                refreshCoordinator.canRetry(providerID, credentialGeneration: credentialGeneration)
            else { return }
            switch await refresh(providerID: providerID, force: true, trigger: trigger) {
            case .refreshed, .cacheHit, .backedOff, .failed:
                return
            case .skipped:
                guard attempt < maxAttempts - 1 else { break }
                AppLog.info(.refresh, "\(trigger.rawValue) waiting out an in-flight refresh for \(providerID) (attempt \(attempt + 1))")
                do { try await Task.sleep(for: retryDelay) }
                catch { return }
            }
        }
        AppLog.error(.refresh, "\(trigger.rawValue) refresh kept being skipped for \(providerID); waiting for the next cycle")
    }

    var knownProviderIDs: [String] { registry.providers.map(\.id) }
    var limitDescriptorsByProvider: [String: [WidgetDescriptor]] { registry.limitDescriptorsByProvider }

    /// 표시 중인 활성 한도 지표의 알림 조건 평가와 전달.
    /// 주기 작업에서 조회 후 호출하여 시간 경과만으로 달라진 소진 속도도 평가.
    /// 평가 대상에서 빠진 지표는 기록 제거 — 다시 활성화·추가하면 새 기준으로 시작.
    func evaluateNotifications(now: Date = Date()) async {
        latchBurningFast(at: now)
        pendingNotificationEvaluationAt = now
        guard !isEvaluatingNotifications else { return }
        isEvaluatingNotifications = true
        defer { isEvaluatingNotifications = false }
        while let requestedAt = pendingNotificationEvaluationAt, !Task.isCancelled {
            pendingNotificationEvaluationAt = nil
            await evaluateNotificationPass(now: requestedAt)
        }
    }

    private func evaluateNotificationPass(now: Date) async {
        guard let settingsProvider = notificationSettings else { return }
        let settings = settingsProvider()
        // 한도 없는 행·차트는 제외하고 레이아웃 순서대로 평가 — 대상에서 빠진 지표의 기록 제거.
        // 첫 비동기 전달 전에 입력 확정 — 평가 도중 조회가 끝나도 나머지 지표의 입력 유지.
        let metrics = orderedDescriptors()
            .filter { isProviderEnabled($0.providerID) }
            .compactMap { descriptor -> QuotaNotificationEvaluator.Metric? in
                let data = data(for: descriptor)
                guard data.isQuotaMeter else { return nil }
                let reading = settings.quotaRecovered ? recoveryReading(for: descriptor, now: now) : nil
                return QuotaNotificationEvaluator.Metric(
                    key: "\(descriptor.providerID).\(descriptor.id)",
                    providerID: descriptor.providerID,
                    data: data, recoveryReading: reading,
                    isRecoveryCurrent: {
                        guard let reading else { return false }
                        return reading == self.recoveryReading(for: descriptor, now: self.now())
                    }
                )
            }
        await notificationEvaluator.evaluate(
            metrics: metrics,
            isOn: { settings.isOn($0) },
            isProviderEnabled: isProviderEnabled,
            now: now,
            providerName: { [providerNames = refreshCoordinator.providerNames, resolveDisplayName] id in
                resolveDisplayName?(id) ?? providerNames[id] ?? id
            },
            post: postNotification
        )
    }

    func recommendationQuota(for profile: AccountProfile, cardID: String, at now: Date) -> AccountSwitchQuota? {
        guard isProviderEnabled(cardID), claimRefreshBinding(providerID: cardID) == .account(profile.identityKey),
            let snapshot = freshLocalQuota(for: cardID, at: now), snapshot.authenticationIssue == nil
        else { return nil }
        switch profile.family {
        case "claude":
            var quota = AccountSwitchQuota.claude(lines: snapshot.lines)
            if !profile.identityKey.contains("|") {
                guard let verified = snapshot.legacyClaudeSwitchIdentity,
                    verified.identityKey.hasPrefix(profile.identityKey + "|")
                else { return nil }
                quota.legacyClaudeIdentity = verified
            }
            let identity = quota.legacyClaudeIdentity?.identityKey ?? profile.identityKey
            let accountKey = UsageTimerObservation.accountKey(family: "claude", identity: identity)
            guard snapshot.liveQuotaAccountKey == accountKey else { return nil }
            return quota
        case "codex":
            guard snapshot.codexSwitchIdentity == profile.identityKey,
                let binding = snapshot.codexResetClaimBinding,
                binding.verifiedAccountKey == snapshot.liveQuotaAccountKey
            else { return nil }
            if cardID == "codex" {
                guard case .file(let path) = binding.source else { return nil }
                let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                let home = file.deletingLastPathComponent().standardizedFileURL
                guard file.lastPathComponent == "auth.json",
                    home.path == Self.sharedCodexHome.path
                        || home.resolvingSymlinksInPath().path == Self.sharedCodexHome.resolvingSymlinksInPath().path
                else { return nil }
            }
            guard var quota = snapshot.codexSwitchQuota else { return nil }
            quota.codexAccountKey = binding.verifiedAccountKey
            return quota
        default:
            return nil
        }
    }

    private func freshLocalQuota(for id: String, at now: Date) -> ProviderSnapshot? {
        guard refreshResults[id] == .succeeded, let snapshot = localSnapshots[id],
            snapshot.liveQuotaAccountKey != nil, let observed = snapshot.liveQuotaObservedAt, observed <= now,
            now.timeIntervalSince(observed) < RefreshSetting.interval(for: id),
            !cache.isQuotaInvalidated(providerID: id, observedAt: observed)
        else { return nil }
        return snapshot
    }

    /// 캐시와 다른 Mac의 합산 자료를 제외하고 현재 계정의 실측 한도만 알림에 사용.
    private func recoveryReading(for descriptor: WidgetDescriptor, now: Date) -> QuotaNotificationEvaluator
        .RecoveryReading?
    {
        let id = descriptor.providerID
        // 회복 대상으로 선언한 행은 실측 consumption 한 종류만 사용. 혼합·추정 리소스는 비교하지 않음.
        guard descriptor.limitResources.count == 1, let resource = descriptor.limitResources.first,
            resource.kind == .consumption, !resource.estimated,
            let snapshot = freshLocalQuota(for: id, at: now), let account = snapshot.liveQuotaAccountKey,
            let line = snapshot.line(label: descriptor.metricLabel),
            resource.matches(line), case let .progress(_, used, limit, format, reset, _, _) = line,
            used.isFinite, used >= 0, limit.isFinite, limit > 0, reset.map({ $0 > now }) != false
        else { return nil }
        // Cursor 요청 수 대체값은 Requests 행에서만 관측해 Total Usage의 구독 기준선을 보존.
        if descriptor.id == "cursor.usage", format == .count(suffix: "requests") { return nil }
        let scope = snapshot.quotaRecoveryScopes[descriptor.metricLabel] ?? .account
        guard scope != .unverified else { return nil }
        return .init(account: account, isExhausted: used >= limit, scope: scope)
    }

    /// 프로바이더별 현재 조회 결과 — 일괄 조회 요약에 사용.
    /// backedOff는 실패 대기, skipped는 비활성·미등록·진행 중 등의 사유로 조회 생략.
    typealias RefreshOutcome = ProviderRefreshCoordinator.RefreshOutcome

    func usageRefreshFailed(for providerID: String) -> Bool {
        refreshCoordinator.refreshResults[providerID]?.failure != nil
    }

    func errorMessage(for providerID: String) -> String? {
        refreshResults[providerID]?.failure?.localizedMessage
    }

    /// Claude·Codex의 Keychain 접근 실패 — 사용자 수동 갱신으로만 승인 요청.
    func needsKeychainApproval(_ providerID: String) -> Bool {
        ProviderAccountID.families.contains(ProviderAccountID.family(of: providerID))
            && (refreshCoordinator.refreshResults[providerID]?.failure?.category == .credentialAccess
                || refreshCoordinator.accountReconciliationFailures[providerID]?.category == .credentialAccess)
    }

    /// 마지막 정상 결과의 경고 — 이후 조회가 실패해도 유지될 수 있음.
    /// 화면 표시는 현재 오류를 우선하는 headerNotice(for:) 사용.
    func warningMessage(for providerID: String) -> String? {
        snapshots[providerID]?.localizedWarning
    }

    /// 프로바이더 제목 옆 경고 — 현재 조회 오류, 자동 제어 경고, 마지막 정상 결과의 경고 순서.
    /// 이전 경고가 현재 실패를 가리지 않도록 우선순위 적용.
    func headerNotice(for providerID: String) -> String? {
        errorMessage(for: providerID) ?? refreshCoordinator.automationWarnings[providerID].map { $0.map { L10n.errors($0) }.joined(separator: " ") }
            ?? warningMessage(for: providerID)
    }

    func setCodexResetWatch(_ watch: CodexResetWatch?, refreshFailed: Bool = false, isAbsent: Bool = false) {
        let result = CodexResetWatchResult(watch: watch, refreshFailed: refreshFailed, isAbsent: isAbsent)
        guard codexResetWatch != result else { return }
        codexResetWatch = result
    }

    func data(for descriptor: WidgetDescriptor) -> WidgetData {
        let snapshot = snapshots[descriptor.providerID]
        let date = now()
        var result = WidgetDataResolver.resolve(
            descriptor, snapshot: snapshot, codexResetWatch: codexResetWatch
        )

        // 대시보드·공유 이미지·메뉴 막대의 공통 표시 설정 적용 지점.
        result.displayMode = meterStyle
        result.resetDisplayMode = resetDisplayMode
        result.alwaysShowPacing = displaySettings.showsPaceMarks
        result.priorityLimits = displaySettings.priorityLimits
        result.showsPaceMarks = displaySettings.showsPaceMarks
        if result.hasData, result.isQuotaMeter, result.valueTextOverride == nil,
            let limit = result.limit, limit.isFinite, limit > 0, result.used.isFinite, result.used >= 0,
            let settings = softLimitSettings?(),
            let fraction = settings.usedFraction(for: descriptor, periodDurationMs: result.periodDurationMs)
        {
            result.softLimitUsedFraction = fraction
            if refreshResults[descriptor.providerID] == .succeeded, let snapshot {
                result.softLimitReadingExpiresAt = SoftLimitObservation.project(
                    snapshot: snapshot, descriptors: [descriptor], window: settings.window, now: date
                )?.nextExpiry(after: date)
            }
        }
        // 행이 속한 카드 ID — 카드별 크레딧 사용 요청의 대상 키.
        result.providerID = descriptor.providerID
        return result.presented(at: date)
    }

    /// 현재 조회 결과의 플랜 이름 — 결과가 없거나 플랜을 제공하지 않으면 nil.
    func plan(for providerID: String) -> String? {
        snapshots[providerID]?.plan
    }

    /// 현재 조회 결과의 빠른 소진 상태 기록 — 같은 기간의 회복 기준까지 유지.
    private func latchBurningFast(at: Date, previousSnapshots: [String: ProviderSnapshot] = [:]) {
        let previous = BurningFast(latched: burningFastWindows)
        var burning: [String: Date] = [:]
        for descriptor in registry.descriptors {
            let data = data(for: descriptor)
            var wasBurning = previous.wasBurning(descriptor.id, data, now: at)
            if wasBurning, let snapshot = previousSnapshots[descriptor.providerID] {
                let previousData = WidgetDataResolver.resolve(
                    descriptor, snapshot: snapshot, codexResetWatch: codexResetWatch
                ).presented(at: at)
                wasBurning = BurningFast.isBurning(previousData, now: at, wasBurning: true)
            }
            guard let reset = data.resetsAt,
                  BurningFast.isBurning(data, now: at, wasBurning: wasBurning) else { continue }
            burning[descriptor.id] = reset
        }
        if burning != burningFastWindows { burningFastWindows = burning }
    }

    /// 일반 프로바이더 조회 주기의 두 배에 해당하는 경과 기준.
    /// 화면의 실제 오래됨 판정은 프로바이더별 조회 주기 적용.
    static let stalenessThreshold = RefreshSetting.interval * 2

    /// 프로바이더별 조회 주기의 두 배가 지나면 Outdated 안내 반환 — 그 전에는 nil.
    /// 반복 실패로 마지막 정상 한도·플랜이 계속 표시되는 상태를 드러내는 안내.
    /// 라벨은 짧게 유지하고 정확한 경과 시간은 툴팁에 표시 — 주입된 시계 사용.
    func stalenessHint(for providerID: String) -> StalenessHint? {
        guard let refreshedAt = snapshots[providerID]?.freshnessDate else { return nil }
        let age = now().timeIntervalSince(refreshedAt)
        guard age >= RefreshSetting.interval(for: providerID) * 2, let duration = Formatters.compactDuration(age) else {
            return nil
        }
        return StalenessHint(label: L10n.metrics("Outdated"), tooltip: L10n.metrics("Last updated %@ ago", duration))
    }

}
