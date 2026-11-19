import Foundation

public struct UsageReadResult: Sendable {
    public let data: Data
    public let warnings: [String]
}

public enum SoftLimitCheckStatus: String, Encodable, Sendable {
    case disabled, belowLimit, reached, unknown
}

public enum UsageReaderError: LocalizedError, Sendable {
    case unknownProvider(String)
    case refreshFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unknownProvider(let providerID):
            "Unknown provider: \(providerID)"
        case .refreshFailed(let message):
            "Refresh failed: \(message)"
        }
    }
}

/// 메뉴바 앱과 동일한 provider cache·refresh 엔진의 one-shot 접근 — timer·로컬 서버·status item·updater 등 장수명 서비스 미보유.
@MainActor
public struct UsageReader {
    private let defaults: UserDefaults
    private let providersOverride: [ProviderRuntime]?
    private let identityKeysOverride: (() -> [String: String])?

    public init(userDefaults: UserDefaults) {
        self.defaults = userDefaults
        self.providersOverride = nil
        self.identityKeysOverride = nil
    }

    init(
        userDefaults: UserDefaults, providers: [ProviderRuntime],
        identityKeys: @escaping () -> [String: String] = { [:] }
    ) {
        self.defaults = userDefaults
        self.providersOverride = providers
        self.identityKeysOverride = identityKeys
    }

    public func read(providerID requestedProviderID: String? = nil, force: Bool = false) async throws -> UsageReadResult {
        let context = try await makeContext()
        let requestedToken = requestedProviderID?.lowercased()
        let matchedIDs: Set<String>? = requestedToken.map { token in
            context.knownIDs.filter { $0 == token || ProviderAccountID.family(of: $0) == token }
        }
        if let requestedToken, let matchedIDs, matchedIDs.isEmpty {
            throw UsageReaderError.unknownProvider(requestedToken)
        }
        let loaded = await load(context: context, matchedIDs: matchedIDs, force: force)
        // 신뢰된 로컬 CLI 출력에만 저장된 계정 이름을 포함.
        let titles = ProviderAccountsStore(defaults: defaults).resolvedDisplayNamesByCardID
        let state = loaded.state.resolvingDisplayNames(titles)
        let path = requestedToken.map { "/v1/limits/\($0)" } ?? "/v1/limits"
        let response = LocalUsageAPI.respond(method: "GET", path: path, state: state)
        guard let data = response.body else {
            // 사실상 unreachable — token은 위에서 검증, limits 라우트는 known token에 항상 body 생성. 무출력 대신 loud 실패.
            throw UsageReaderError.refreshFailed(loaded.warnings.first ?? "local read produced no data")
        }
        return UsageReadResult(data: data, warnings: loaded.warnings)
    }

    /// 선택한 카드의 새 요청을 시작하기 전, 앱과 같은 기간과 사용률로 소프트 한도 판정.
    public func checkSoftLimit(cardID: String) async throws -> SoftLimitCheckStatus {
        let id = cardID.lowercased()
        guard !ProviderAccountID.isAccountCard(id) else { throw UsageReaderError.unknownProvider(id) }
        let isManagedFamily = ProviderAccountID.families.contains(id)
        let settings = activeSoftLimitSettings()
        let enabled = ProviderEnablementStore(defaults: defaults).isEnabled(id)
        let context = try await makeContext(prepare: settings != nil && enabled, resolveAccounts: isManagedFamily)
        guard context.knownIDs.contains(id) else { throw UsageReaderError.unknownProvider(id) }
        // 로컬 진단에는 프로바이더 종류와 고정 사유만 기록. 계정 ID와 사용량은 제외.
        func unknown(_ reason: StaticString) -> SoftLimitCheckStatus {
            let family = TelemetryPrivacy.providerFamily(id) ?? "other"
            AppLog.info(.refresh, "Soft Limit preflight: provider=\(family) status=unknown reason=\(reason)")
            return .unknown
        }
        guard let settings else { return .disabled }
        guard enabled else { return unknown("provider_disabled") }
        if isManagedFamily, context.identityKeys[id] == nil { return unknown("identity_unresolved") }

        let descriptors = context.registry.descriptors(for: id)
        let window = settings.window
        guard descriptors.contains(where: { $0.softLimitWindows.contains(where: window.includes) }) else {
            return unknown("unsupported_window")
        }
        let loaded = await load(context: context, matchedIDs: [id], force: false, preflightCardID: id)
        let verified: Bool
        // 조회 중 로그인 전환 가능. 캐시의 계정 식별자가 없으면 이번 호출에서 직접 조회한 카드만 허용.
        if let stamped = loaded.verifiedIdentity {
            verified = await currentIdentity(for: id, context: context) == stamped
        } else {
            verified = !isManagedFamily && id != "cursor" && loaded.didRefreshPreflight
        }
        guard let current = activeSoftLimitSettings() else { return .disabled }
        let now = Date()
        guard ProviderEnablementStore(defaults: defaults).isEnabled(id) else { return unknown("provider_disabled") }
        guard loaded.state.errors[id] == nil else { return unknown("refresh_failed") }
        guard let snapshot = loaded.state.snapshots[id] else { return unknown("no_snapshot") }
        // 조회 대기 중에는 신선한 실측값과 현재 계정을 새로 확인할 수 없음.
        if let retryAfter = snapshot.usageRetryAfter, retryAfter > now { return unknown("rate_limited") }
        guard verified else { return unknown("identity_unverified") }
        guard
            let observation = SoftLimitObservation.project(
                snapshot: loaded.cache.applyingQuotaInvalidation(snapshot),
                descriptors: descriptors, window: current.window, now: now)
        else { return unknown("no_current_measurement") }
        switch observation.quotaState(thresholdPercent: current.thresholdPercent, at: now) {
        case .reached: return .reached
        case .belowLimit: return .belowLimit
        case .unknown: return unknown("incomplete_quota")
        }
    }

    private func activeSoftLimitSettings() -> SoftLimitSettingsStore? {
        guard defaults.bool(forKey: UpdaterController.betaChannelDefaultsKey) else { return nil }
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        return settings.isActive ? settings : nil
    }

    private func currentIdentity(for id: String, context: ReadContext) async -> String? {
        if let identityKeysOverride { return identityKeysOverride()[id] }
        if id == "cursor", let cursor = context.providers.first(where: { $0.provider.id == id }) as? CursorProvider {
            return await cursor.currentIdentityKey()
        }
        let observer = context.accountObserver
        let outcome = await loadOffMainActor { id == "claude" ? observer.observeClaude() : observer.observeCodex() }
        guard case let .resolved(key, _, _) = outcome else { return nil }
        return key
    }

    private struct ReadContext {
        let providers: [ProviderRuntime]
        let registry: WidgetRegistry
        let identityKeys: [String: String]
        let accountObserver: DefaultAccountObserver
        var knownIDs: Set<String> { Set(registry.providers.map(\.id)) }
    }

    private func makeContext(prepare: Bool = true, resolveAccounts: Bool = true) async throws -> ReadContext {
        // 계정 확인과 사용량 조회가 같은 CLI 홈을 읽도록 로그인 셸 환경을 먼저 준비.
        if providersOverride == nil && prepare {
            try StorageMigration.runForCLI(.init(defaults: defaults))
            await Task.detached(priority: .userInitiated) {
                _ = LoginShellEnvironment.shared.ensureCaptured()
            }.value
        }
        let accountAssembly =
            providersOverride == nil && prepare && resolveAccounts
            ? ProviderAccountAssembly.make(defaults: defaults, waitsForLoginShell: false)
            : ProviderAccountAssembly(identityKeysByCard: identityKeysOverride?() ?? [:])
        // 비활성 계정의 Keychain 복사본은 앱 전용이므로 CLI 카탈로그에서 제외.
        let providers = providersOverride ?? ProviderCatalog.make(
            defaults: defaults,
            hasUnregisteredClaudeLogins: accountAssembly.hasUnregisteredClaudeLogins,
            defaultClaudeExtraLogRoots: accountAssembly.defaultClaudeExtraLogRoots,
            codexSharedAuthHome: accountAssembly.codexSharedAuthHome,
            codexAccountBinding: accountAssembly.codexDefaultAccountBinding,
            claudeManagedSwitchActive: accountAssembly.claudeManagedSwitchActive
        )
        let observer = DefaultAccountObserver(
            pinsClaudeSharedHome: accountAssembly.claudeManagedSwitchActive,
            pinsCodexSharedHome: accountAssembly.codexSharedAuthHome != nil
        )
        return ReadContext(
            providers: providers, registry: .from(providers), identityKeys: accountAssembly.identityKeysByCard,
            accountObserver: observer)
    }

    private func load(
        context: ReadContext, matchedIDs: Set<String>?, force: Bool, preflightCardID: String? = nil
    ) async -> (
        state: LocalUsageAPI.State, warnings: [String], cache: ProviderSnapshotCache,
        verifiedIdentity: String?, didRefreshPreflight: Bool
    ) {
        let providers = context.providers
        let registry = context.registry
        let enablement = ProviderEnablementStore(defaults: defaults)
        let includesProvider: @MainActor (String) -> Bool = { id in
            matchedIDs?.contains(id) ?? enablement.isEnabled(id)
        }
        var identityKeys = context.identityKeys
        if includesProvider("cursor"),
            let cursor = providers.first(where: { $0.provider.id == "cursor" }) as? CursorProvider
        {
            identityKeys["cursor"] = await cursor.currentIdentityKey()
        }
        // 귀속 정보가 없는 디스크 캐시는 이전 로그인일 수 있어 사전 검사 때만 직접 조회.
        let trustsPersistedFreshness = preflightCardID.map { identityKeys[$0] != nil } ?? true
        let cache = ProviderSnapshotCache(userDefaults: defaults, allowsPersistedFreshness: trustsPersistedFreshness)
        let allProviderIDs = registry.providers.map(\.id)
        // 앱과 동일한 계정 guard — 타 계정 캐시와 신원 미확인 Claude 캐시는 TTL 안에서도 재조회.
        let staleAccountStampIDs = Set(
            allProviderIDs.filter {
                (ProviderAccountID.family(of: $0) == "claude" && identityKeys[$0] == nil)
                    || cache.hasStaleAccountStamp(providerID: $0, currentIdentityKey: identityKeys[$0])
            })
        let cachedSnapshots = cache.loadSnapshots(providerIDs: allProviderIDs)
            .filter { providerID, _ in !staleAccountStampIDs.contains(providerID) }
        let savedOrder = LayoutPersistence(
            defaults: defaults,
            storageKey: "openusage.layout.v1"
        ).loadProviderOrder() ?? []
        let orderedIDs = registry.orderedProviderIDs(savedOrder: savedOrder)
        let enabledOrderedIDs = orderedIDs.filter(includesProvider)
        let needsRefresh = force || enabledOrderedIDs.contains {
            cache.snapshot(providerID: $0) == nil || staleAccountStampIDs.contains($0)
        }
        var snapshots = cachedSnapshots
        var warnings: [String] = []
        var errors: [String: String] = [:]
        var didRefreshPreflight = false

        if needsRefresh {
            LoginShellEnvironment.shared.prewarm()
            let dataStore = WidgetDataStore(
                registry: registry,
                providers: providers,
                cache: cache,
                defaults: defaults,
                isProviderEnabled: includesProvider,
                // CLI는 앱의 snapshot cache 공유 — 쓰기에 동일한 계정 stamp 필수, 미stamp claude/codex entry는 앱의 다음 launch에 폐기.
                providerIdentityKeys: identityKeys,
                workQueue: .shared
            )
            if let matchedIDs {
                for providerID in orderedIDs.filter(matchedIDs.contains) {
                    if providerID == preflightCardID,
                        let retryAfter = cachedSnapshots[providerID]?.usageRetryAfter, retryAfter > Date()
                    {
                        continue
                    }
                    let outcome = await dataStore.refresh(providerID: providerID, force: force, trigger: .cli)
                    if providerID == preflightCardID { didRefreshPreflight = outcome == .refreshed }
                }
            } else {
                await dataStore.refreshAll(force: force, trigger: .cli)
            }
            if providersOverride == nil {
                await PersistentJSONLScanCaches.flushPendingWrites()
            }
            snapshots = dataStore.snapshots
            errors = dataStore.providerErrors
            warnings = orderedIDs
                .compactMap { id in errors[id].map { "\(id): \($0)" } }
        }

        let state = LocalUsageAPI.State(
            enabledOrderedIDs: enabledOrderedIDs,
            knownIDs: context.knownIDs,
            snapshots: snapshots,
            limitDescriptors: registry.limitDescriptorsByProvider,
            errors: errors
        )
        let verifiedIdentity = preflightCardID.flatMap { id in
            identityKeys[id].flatMap { cache.producedByIdentityKey(providerID: id) == $0 ? $0 : nil }
        }
        return (state, warnings, cache, verifiedIdentity, didRefreshPreflight)
    }
}
