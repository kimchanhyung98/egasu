import CryptoKit
import Darwin
import Foundation
import os

struct ProviderSnapshotCache {
    private struct Payload: Codable {
        var snapshots: [String: ProviderSnapshot]
        /// Card id → 저장된 snapshot을 생산한 account identity key. `ProviderSnapshot`이 local HTTP API
        /// (`LocalUsageAPI`)로 그대로 직렬화되므로 필드가 아닌 sidecar map — stamp는 cache bookkeeping,
        /// wire 데이터 아님. 계정 식별을 확인하지 못한 프로바이더에는 부재.
        var producedByIdentityKeys: [String: String]
        /// ISO 8601 캐시 날짜의 초 단위 정밀도를 보완. 같은 초의 인증 무효화와 다음 실측을 구분.
        var liveQuotaTimestamps: [String: Double]?
        /// 같은 초에 끝난 두 프로세스의 저장 순서를 비교하는 원래 갱신 시각.
        var refreshTimestamps: [String: Double]?
    }

    private struct Session {
        var payload: Payload?
        var freshIDs: Set<String> = []
        /// 사전 저장 실패로 디스크에 없는 실측은 다른 카드 쓰기 후에도 메모리에 보존.
        var unpublishedIDs: Set<String> = []
    }

    private let session = OSAllocatedUnfairLock(initialState: Session())
    private let localQuotaInvalidations = OSAllocatedUnfairLock<[String: Date]>(initialState: [:])

    private let userDefaults: UserDefaults
    private let storageKey: String
    private let persistenceLockURL: URL
    /// 세션 내에 쓴 snapshot의 fresh 유지 기간(1 refresh interval) — 이전 세션의 snapshot은 `refreshedAt`과
    /// 무관하게 non-fresh. 테스트는 고정 TTL 주입.
    private let ttl: TimeInterval?
    /// timestamp-only freshness opt-in — 메뉴바 앱은 launch당 1회 refresh를 강제하지만 one-shot reader에는 세션 개념이 없음.
    private let allowsPersistedFreshness: Bool
    /// 현재 키의 계정을 확인할 수 없는 프로바이더는 이전 실행의 캐시를 사용하지 않음.
    private let ignoresPersistedSnapshotsFor: Set<String>
    private let persistsWrites: Bool
    private let now: () -> Date
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        userDefaults: UserDefaults = .standard,
        storageDomainName: String = AppBundleLocator.current.bundleIdentifier,
        // storage key 버전 bump는 pre-upgrade 캐시를 폐기 — schema 확장 필드를 1회 refetch로 즉시 반영.
        // v10: 마지막 정상 한도 시각 도입 — 이전 캐시의 로컬 갱신 시각을 한도 조회 시각으로 재사용 금지.
        storageKey: String = "openusage.providerSnapshots.v10",
        ttl: TimeInterval? = nil,
        allowsPersistedFreshness: Bool = false,
        persistsWrites: Bool = true,
        ignoresPersistedSnapshotsFor: Set<String> = ["opencode"],
        now: @escaping () -> Date = Date.init
    ) {
        self.userDefaults = userDefaults
        self.storageKey = storageKey
        let lockKey = storageDomainName + "\u{0}" + storageKey
        let digest = SHA256.hash(data: Data(lockKey.utf8)).map { String(format: "%02x", $0) }.joined()
        let cacheDirectory =
            FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
                "Library/Caches", isDirectory: true)
        self.persistenceLockURL =
            cacheDirectory
            .appendingPathComponent("egasu-snapshot-cache-\(digest).lock")
        self.ttl = ttl
        self.allowsPersistedFreshness = allowsPersistedFreshness
        self.ignoresPersistedSnapshotsFor = ignoresPersistedSnapshotsFor
        self.persistsWrites = persistsWrites
        self.now = now
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// 대상 provider의 저장 snapshot 전부(만료 포함) — 표시용(stale-while-revalidate).
    /// refresh gating은 TTL 검사하는 `snapshot(providerID:)` 경유.
    func loadSnapshots(providerIDs: [String], identityKeys: [String: String] = [:]) -> [String: ProviderSnapshot] {
        let providerIDSet = Set(providerIDs)
        let state = loadSession()
        let loaded =
            state.payload?.snapshots.filter { providerID, _ in
                providerIDSet.contains(providerID)
                    && canReadSnapshot(providerID, identity: identityKeys[providerID], in: state)
            } ?? [:]
        AppLog.debug(.cache, "loaded \(loaded.count) snapshots from disk")
        return loaded
    }

    private func canReadSnapshot(_ providerID: String, identity: String?, in state: Session) -> Bool {
        if providerID == "openai-api" {
            guard let identity else { return false }
            return state.payload?.producedByIdentityKeys[providerID] == identity
        }
        return !ignoresPersistedSnapshotsFor.contains(providerID) || state.freshIDs.contains(providerID)
    }

    func snapshot(providerID: String, currentIdentityKey: String? = nil) -> ProviderSnapshot? {
        let state = loadSession()
        guard canReadSnapshot(providerID, identity: currentIdentityKey, in: state),
            let snapshot = state.payload?.snapshots[providerID]
        else {
            return nil
        }
        let writtenThisSession = state.freshIDs.contains(providerID)
        let age = now().timeIntervalSince(snapshot.freshnessDate)
        let ttl = ttl ?? RefreshSetting.interval(for: providerID)
        let trusted = allowsPersistedFreshness || writtenThisSession
        let fresh = trusted && age < ttl
            && !(snapshot.usageRetryAfter != nil && snapshot.quotaObservedAt == nil)
        let reason = !trusted ? "stale (not written this session)"
            : fresh ? "fresh" : "stale"
        AppLog.debug(
            .cache, "\(AppLog.providerFamily(providerID)) staleness \(Int(age))s vs ttl \(Int(ttl))s -> \(reason)")
        return fresh ? applyingQuotaInvalidation(snapshot) : nil
    }

    /// 다른 프로세스가 이전 캐시를 다시 저장해도 실패 전 한도를 실행 근거로 재사용하지 않도록 시각만 별도 보존.
    func invalidateLiveQuota(providerID: String, identity: String?) {
        if let identity, let stored = producedByIdentityKey(providerID: providerID), identity != stored { return }
        let invalidatedAt = now()
        if persistsWrites {
            userDefaults.set(invalidatedAt, forKey: "\(storageKey).quotaInvalidated.\(providerID)")
        } else {
            localQuotaInvalidations.withLock { $0[providerID] = invalidatedAt }
        }
    }

    func applyingQuotaInvalidation(_ snapshot: ProviderSnapshot) -> ProviderSnapshot {
        guard let observed = snapshot.liveQuotaObservedAt,
            isQuotaInvalidated(providerID: snapshot.providerID, observedAt: observed)
        else { return snapshot }
        var checked = snapshot
        checked.liveQuotaObservedAt = nil
        return checked
    }

    /// 새 실행 직전에도 CLI와 공유하는 무효화 시각을 확인.
    func isQuotaInvalidated(providerID: String, observedAt: Date) -> Bool {
        if !persistsWrites, let local = localQuotaInvalidations.withLock({ $0[providerID] }), observedAt <= local {
            return true
        }
        let invalidated = userDefaults.object(forKey: "\(storageKey).quotaInvalidated.\(providerID)") as? Date
        return invalidated.map { observedAt <= $0 } ?? false
    }

    /// `producedByIdentityKey`는 이 snapshot을 생산한 account identity(쓰기 시점의 카드 identity) —
    /// account identity 없는 provider·identity 미해석이면 nil.
    /// `markSessionFresh`가 false이면 기존 세션 freshness 자격 유지.
    func store(
        _ snapshot: ProviderSnapshot, producedByIdentityKey: String? = nil, markSessionFresh: Bool = true
    ) {
        guard !snapshot.lines.contains(where: \.isError) else {
            AppLog.debug(.cache, "skip write \(AppLog.providerFamily(snapshot.providerID)) (error snapshot)")
            return
        }
        AppLog.debug(.cache, "write \(AppLog.providerFamily(snapshot.providerID))")
        func updating(_ stored: Payload) {
            let observedNow = now()
            let current = stored.snapshots[snapshot.providerID]
            let older =
                current.map {
                    $0.refreshedAt > snapshot.refreshedAt && (!markSessionFresh || $0.refreshedAt <= observedNow)
                } ?? false
            let publishes =
                !older
                && (markSessionFresh
                    || (stored.producedByIdentityKeys[snapshot.providerID] == producedByIdentityKey
                        && Self.matchesQuota(current, snapshot, codecs: persistsWrites ? (encoder, decoder) : nil)))
            var didPublish = false
            if publishes {
                if persistsWrites {
                    var payload = stored
                    payload.snapshots[snapshot.providerID] = snapshot
                    payload.producedByIdentityKeys[snapshot.providerID] = producedByIdentityKey
                    didPublish = save(payload)
                } else {
                    didPublish = true
                }
            } else {
                AppLog.debug(
                    .cache, "skip shared write \(AppLog.providerFamily(snapshot.providerID)) (stored snapshot changed)")
            }
            mergeSession(
                stored, snapshot: snapshot, identity: producedByIdentityKey, at: observedNow,
                live: markSessionFresh, acceptsStoredWrite: publishes, failedToPublish: publishes && !didPublish)
        }
        guard persistsWrites else {
            updating(loadPayload())
            return
        }
        var merged = false
        do {
            try withPersistenceLock {
                guard userDefaults.synchronize() else { throw POSIXError(.EIO) }
                updating(decodeStoredPayload())
                merged = true
                guard userDefaults.synchronize() else { throw POSIXError(.EIO) }
            }
        } catch {
            AppLog.warn(.cache, "shared cache write failed: \(AppLog.errorDetails(error))")
            if !merged {
                _ = loadSession()
                mergeSession(
                    nil, snapshot: snapshot, identity: producedByIdentityKey, at: now(), live: markSessionFresh)
            }
        }
    }

    /// entry 저장 시 stamp된 account identity — entry 부재·무stamp면 nil. launch 필터가 account-aware
    /// 카드의 현재 identity와 비교(`WidgetDataStore.init`).
    func producedByIdentityKey(providerID: String) -> String? {
        loadPayload().producedByIdentityKeys[providerID]
    }

    static func requiresCredentialIdentity(_ providerID: String) -> Bool {
        ["cursor", "openai-api"].contains(ProviderAccountID.family(of: providerID))
    }

    /// 저장 entry를 `currentIdentityKey`로 귀속할 수 없는지 — entry 존재 + 현재 identity known + stamp 누락/타 account.
    /// 모든 read 경로(launch paint 필터·refresh cache-hit gate·one-shot CLI의 persisted-freshness 읽기)가 이를
    /// 부재로 취급해야 같은 home에서의 swap이 이전 account 데이터를 서빙하지 않음.
    /// 현재 계정을 확인할 수 없는 Cursor 캐시는 표시·재사용 제외.
    func hasStaleAccountStamp(providerID: String, currentIdentityKey: String?) -> Bool {
        let payload = loadPayload()
        guard payload.snapshots[providerID] != nil else { return false }
        guard let currentIdentityKey else { return Self.requiresCredentialIdentity(providerID) }
        return payload.producedByIdentityKeys[providerID] != currentIdentityKey
    }

    private func loadSession() -> Session {
        let cached = session.withLock { $0 }
        if cached.payload != nil { return cached }
        let loaded = decodeStoredPayload()
        return session.withLock { state in
            if state.payload == nil { state.payload = loaded }
            return state
        }
    }

    private func loadPayload() -> Payload {
        loadSession().payload ?? Payload(snapshots: [:], producedByIdentityKeys: [:])
    }

    /// 가공된 이력 행을 제외한 한도와 조회 시각 대조. 디스크의 날짜는 v10 ISO 8601 정밀도로 비교.
    private static func matchesQuota(
        _ candidate: ProviderSnapshot?, _ edit: ProviderSnapshot, codecs: (JSONEncoder, JSONDecoder)? = nil
    ) -> Bool {
        guard let candidate, candidate.refreshedAt == edit.refreshedAt,
            candidate.plan == edit.plan, candidate.incompleteQuotaWindows == edit.incompleteQuotaWindows,
            candidate.metricPresentations == edit.metricPresentations
        else { return false }
        func matchesDate(_ lhs: Date?, _ rhs: Date?) -> Bool {
            if codecs == nil { return lhs == rhs }
            return lhs.map { floor($0.timeIntervalSince1970) } == rhs.map { floor($0.timeIntervalSince1970) }
        }
        guard matchesDate(candidate.quotaObservedAt, edit.quotaObservedAt),
            matchesDate(candidate.usageRetryAfter, edit.usageRetryAfter)
        else { return false }
        let hasHistory = candidate.usageHistory != nil || edit.usageHistory != nil
        let previous = hasHistory ? UsageHistorySnapshotRenderer.nonHistoryLines(candidate.lines) : candidate.lines
        let incoming = hasHistory ? UsageHistorySnapshotRenderer.nonHistoryLines(edit.lines) : edit.lines
        if previous == incoming { return true }
        guard let (encoder, decoder) = codecs, let data = try? encoder.encode(incoming),
            let decoded = try? decoder.decode([MetricLine].self, from: data)
        else { return false }
        return previous == decoded
    }

    /// 공유 저장본과 실제 세션 조회를 구분하고 표시값·귀속·freshness를 함께 갱신.
    private func mergeSession(
        _ stored: Payload?, snapshot: ProviderSnapshot, identity: String?, at now: Date,
        live: Bool, acceptsStoredWrite: Bool = false, failedToPublish: Bool = false
    ) {
        let id = snapshot.providerID
        session.withLock { state in
            var visible = stored ?? state.payload ?? Payload(snapshots: [:], producedByIdentityKeys: [:])
            if stored != nil {
                state.unpublishedIDs.subtract(visible.snapshots.keys)
                state.freshIDs.formIntersection(Set(visible.snapshots.keys).union(state.unpublishedIDs))
                for localID in state.freshIDs {
                    visible.snapshots[localID] = state.payload?.snapshots[localID]
                    visible.producedByIdentityKeys[localID] = state.payload?.producedByIdentityKeys[localID]
                }
            }
            let local = state.freshIDs.contains(id) ? visible.snapshots[id] : nil
            let newerLocal =
                local.map { $0.refreshedAt > snapshot.refreshedAt && (!live || $0.refreshedAt <= now) } ?? false
            let differentLocalAccount = !live && local != nil && visible.producedByIdentityKeys[id] != identity
            let acceptsHistory = !live && (local == nil ? acceptsStoredWrite : Self.matchesQuota(local, snapshot))
            if (live || acceptsHistory) && !newerLocal && !differentLocalAccount {
                visible.snapshots[id] = snapshot
                visible.producedByIdentityKeys[id] = identity
                if live {
                    state.freshIDs.insert(id)
                    if stored == nil || failedToPublish { state.unpublishedIDs.insert(id) }
                }
            }
            if acceptsStoredWrite && !failedToPublish { state.unpublishedIDs.remove(id) }
            state.payload = visible
        }
    }

    private func decodeStoredPayload() -> Payload {
        // 저장 데이터 없음은 정상 first-launch·cleared-cache — 조용히 empty 복구. 데이터가 있는데 decode 실패는
        // 실제 문제(schema drift, half-write) — 크게 log 후 empty 복구(조용한 drop은 전 provider 캐시 소실 + refresh storm).
        guard let data = userDefaults.data(forKey: storageKey) else {
            return Payload(snapshots: [:], producedByIdentityKeys: [:])
        }
        do {
            var payload = try decoder.decode(Payload.self, from: data)
            payload.snapshots["openai-api"]?.producedByIdentityKey = payload.producedByIdentityKeys["openai-api"]
            for (id, timestamp) in payload.refreshTimestamps ?? [:] where payload.snapshots[id] != nil {
                payload.snapshots[id]?.refreshedAt = Date(timeIntervalSinceReferenceDate: timestamp)
            }
            for id in payload.snapshots.keys where payload.snapshots[id]?.liveQuotaObservedAt != nil {
                // 이전 캐시는 부분 한도 누락을 구분하지 않아 다음 실측까지 표시용으로만 복원.
                payload.snapshots[id]?.liveQuotaObservedAt = payload.liveQuotaTimestamps?[id].map {
                    Date(timeIntervalSinceReferenceDate: $0)
                }
            }
            for id in payload.snapshots.keys where ProviderAccountID.family(of: id) == "cursor" {
                if payload.snapshots[id]?.usageHistory?.estimatedCost == nil {
                    payload.snapshots[id]?.usageHistory?.estimatedCost = true
                }
            }
            return payload
        } catch {
            AppLog.warn(.cache, "cache decode failed, dropping stored snapshots: \(AppLog.errorDetails(error))")
            return Payload(snapshots: [:], producedByIdentityKeys: [:])
        }
    }

    private func save(_ payload: Payload) -> Bool {
        // encode 실패는 크게 log — 조용히 삼키면 snapshot이 persisted cache에서 소리 없이 빠짐.
        do {
            var persisted = payload
            persisted.liveQuotaTimestamps = payload.snapshots.compactMapValues {
                $0.liveQuotaObservedAt?.timeIntervalSinceReferenceDate
            }
            persisted.refreshTimestamps = payload.snapshots.mapValues { $0.refreshedAt.timeIntervalSinceReferenceDate }
            let data = try encoder.encode(persisted)
            userDefaults.set(data, forKey: storageKey)
            return true
        } catch {
            AppLog.warn(.cache, "encode failed, snapshot not persisted: \(AppLog.errorDetails(error))")
            return false
        }
    }

    private func withPersistenceLock(_ body: () throws -> Void) throws {
        try FileManager.default.createDirectory(
            at: persistenceLockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = Darwin.open(persistenceLockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let deadline = ContinuousClock.now + .milliseconds(100)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            guard error == EINTR || error == EWOULDBLOCK else {
                throw POSIXError(POSIXErrorCode(rawValue: error) ?? .EIO)
            }
            guard ContinuousClock.now < deadline else { throw POSIXError(.ETIMEDOUT) }
            if error == EWOULDBLOCK { Thread.sleep(forTimeInterval: 0.005) }
        }
        defer { flock(descriptor, LOCK_UN) }
        try body()
    }
}
