import Foundation
import Observation

/// 이 Mac의 원본 값과 계정별 캐시 소유. 피어 합산은 표시용 결과로만 반환.
@MainActor
@Observable
final class ProviderSnapshotStore {
    enum Update {
        case succeeded(ProviderSnapshot, degraded: Bool)
        case failed(ProviderRefreshFailure, render: Bool, notifyHistoryChange: Bool)
    }

    struct Rendered {
        let snapshots: [String: ProviderSnapshot]
        var remoteOnlySpend: [(provider: Provider, snapshot: ProviderSnapshot)] = []
    }

    private let cache: ProviderSnapshotCache
    private var registry: WidgetRegistry
    private let isProviderEnabled: @MainActor (String) -> Bool
    private let now: () -> Date
    private(set) var identityKeys: [String: String]
    private var familyTotalHistoryCardIDs: Set<String>
    private var unresolvedIdentityCacheRejections: Set<String>
    private var peerHistoryDocuments: [UsageHistoryDocument] = []
    private(set) var localSnapshots: [String: ProviderSnapshot]

    init(
        registry: WidgetRegistry, cache: ProviderSnapshotCache,
        identityKeys: [String: String], familyTotalHistoryCardIDs: Set<String>,
        isProviderEnabled: @escaping @MainActor (String) -> Bool, now: @escaping () -> Date
    ) {
        self.registry = registry
        self.cache = cache
        self.identityKeys = identityKeys
        self.familyTotalHistoryCardIDs = familyTotalHistoryCardIDs
        self.isProviderEnabled = isProviderEnabled
        self.now = now
        unresolvedIdentityCacheRejections = Set(registry.providers.map(\.id).filter {
            ProviderAccountID.family(of: $0) == "claude" && identityKeys[$0] == nil
        })
        localSnapshots = [:]
        localSnapshots = loadMatchingCache(providerIDs: registry.providers.map(\.id))
    }

    func isUnresolvedClaude(_ providerID: String) -> Bool {
        ProviderAccountID.family(of: providerID) == "claude" && identityKeys[providerID] == nil
    }

    func discardMismatchedReading(for providerID: String, currentIdentityKey: String?) -> Bool {
        guard let local = localSnapshots[providerID] else { return false }
        let previousIdentity = local.producedByIdentityKey ?? cache.producedByIdentityKey(providerID: providerID)
        guard currentIdentityKey == nil || currentIdentityKey != previousIdentity else { return false }
        localSnapshots[providerID] = nil
        return true
    }

    func cachedSnapshot(for providerID: String, currentIdentityKey: String?) -> ProviderSnapshot? {
        guard !unresolvedIdentityCacheRejections.contains(providerID),
            !cache.hasStaleAccountStamp(providerID: providerID, currentIdentityKey: currentIdentityKey)
        else { return nil }
        return cache.snapshot(providerID: providerID)
    }

    func invalidateLiveQuota(for providerID: String, responseIdentity: String? = nil) {
        cache.invalidateLiveQuota(providerID: providerID, identity: responseIdentity ?? identityKeys[providerID])
    }

    @discardableResult
    func useCachedSnapshot(_ snapshot: ProviderSnapshot) -> Bool {
        guard localSnapshots[snapshot.providerID] != snapshot else { return false }
        localSnapshots[snapshot.providerID] = snapshot
        return true
    }

    /// 계정 연결을 교체하고 제거한 원본 카드 ID 반환. 영속 캐시는 삭제하지 않음.
    func replaceCatalog(
        registry: WidgetRegistry, identityKeys: [String: String], familyTotalHistoryCardIDs: Set<String>
    ) -> Set<String> {
        let liveIDs = Set(registry.providers.map(\.id))
        let previousIdentityKeys = self.identityKeys
        unresolvedIdentityCacheRejections.formUnion(previousIdentityKeys.keys.filter { identityKeys[$0] == nil })
        unresolvedIdentityCacheRejections.subtract(identityKeys.keys)
        unresolvedIdentityCacheRejections.formUnion(liveIDs.filter {
            ProviderAccountID.family(of: $0) == "claude" && identityKeys[$0] == nil
        })
        self.registry = registry
        self.identityKeys = identityKeys
        self.familyTotalHistoryCardIDs = familyTotalHistoryCardIDs
        let previousIDs = Set(localSnapshots.keys)
        localSnapshots = localSnapshots.filter { cardID, _ in
            liveIDs.contains(cardID) && previousIdentityKeys[cardID] == identityKeys[cardID]
                && !isUnresolvedClaude(cardID)
        }
        let discardedIDs = previousIDs.subtracting(localSnapshots.keys)
        for (cardID, snapshot) in loadMatchingCache(providerIDs: Array(liveIDs)) where localSnapshots[cardID] == nil {
            localSnapshots[cardID] = snapshot
        }
        return discardedIDs
    }

    func invalidateAuthentication(for providerID: String) -> Bool {
        guard var snapshot = localSnapshots[providerID], snapshot.authenticationIssue != nil else { return false }
        snapshot.authenticationIssue = nil
        snapshot.warning = nil
        snapshot.warningPresentation = nil
        localSnapshots[providerID] = snapshot
        return true
    }

    private func loadMatchingCache(providerIDs: [String]) -> [String: ProviderSnapshot] {
        cache.loadSnapshots(providerIDs: providerIDs).filter { cardID, _ in
            guard !unresolvedIdentityCacheRejections.contains(cardID) else { return false }
            guard !cache.hasStaleAccountStamp(providerID: cardID, currentIdentityKey: identityKeys[cardID]) else {
                AppLog.info(.cache, "stale account cache discarded for \(AppLog.providerFamily(cardID))")
                return false
            }
            return true
        }
    }

    private func previousSnapshot(for incoming: ProviderSnapshot) -> ProviderSnapshot? {
        let id = incoming.providerID
        let local = localSnapshots[id]
        guard ProviderAccountID.family(of: id) == "cursor" else { return local }
        guard let identity = incoming.producedByIdentityKey else { return nil }
        if local?.producedByIdentityKey == identity { return local }
        guard cache.producedByIdentityKey(providerID: id) == identity else { return nil }
        var stored = cache.loadSnapshots(providerIDs: [id])[id]
        stored?.producedByIdentityKey = identity
        return stored
    }

    /// 현재 인증에 속하는 응답만 수신. 실패 응답의 로컬 이력 갱신은 한도 성공으로 저장하지 않음.
    func accept(_ incoming: ProviderSnapshot, from provider: ProviderRuntime) -> Update {
        let providerID = provider.provider.id
        var snapshot = incoming
        let unresolvedClaudeIdentity = isUnresolvedClaude(providerID)
        if provider.retainsDedicatedSpendOnScanFailure, snapshot.totalSpendLines != nil {
            snapshot.totalSpendRefreshedAt = snapshot.refreshedAt
        }
        if provider.retainsDedicatedSpendOnScanFailure, snapshot.totalSpendLines == nil, snapshot.warning == nil,
            snapshot.refreshFailure == nil,
           snapshot.isDegraded != true,
           let previous = localSnapshots[providerID],
           Calendar.current.isDate(previous.totalSpendRefreshedAt ?? previous.refreshedAt, inSameDayAs: snapshot.refreshedAt),
           previous.totalSpendLines != nil {
            let warning = "Local usage history is unavailable. Showing the last successful totals."
            snapshot.warning = warning
            snapshot.warningPresentation = [.init(warning)]
            snapshot.isDegraded = true
            AppLog.warn(
                .refresh, "\(AppLog.providerFamily(providerID)) local history unavailable; retained same-day totals")
        }
        if let failure = snapshot.refreshFailure {
            invalidateLiveQuota(for: providerID, responseIdentity: snapshot.producedByIdentityKey)
            var notifyHistoryChange = false
            var render = false
            if unresolvedClaudeIdentity {
                render = true
                let removedHistory = localSnapshots.removeValue(forKey: providerID)?.usageHistory != nil
                notifyHistoryChange = removedHistory
            } else if ProviderAccountID.family(of: providerID) == "cursor" {
                let local = localSnapshots[providerID]
                var retained = previousSnapshot(for: snapshot)
                retained?.liveQuotaObservedAt = nil
                render = local != retained
                notifyHistoryChange = local?.usageHistory != retained?.usageHistory
                localSnapshots[providerID] = retained
            } else if (snapshot.usageHistory != nil && registry.historyDescriptorsByProvider[providerID] != nil)
                      || (provider.provider.usesDedicatedSpendLines && snapshot.totalSpendLines != nil)
                      || (provider.retainsDedicatedSpendOnScanFailure && localSnapshots[providerID]?.totalSpendLines != nil) {
                render = true
                // 한도 실패와 독립된 로컬 이력만 갱신. 기존 한도·플랜·조회 시각은 그대로 보존.
                var retained = localSnapshots[providerID] ?? ProviderSnapshot.make(
                    provider: provider.provider, plan: nil, lines: [], refreshedAt: snapshot.refreshedAt
                )
                if provider.provider.usesDedicatedSpendLines, let lines = snapshot.totalSpendLines {
                    retained.totalSpendLines = lines
                    retained.totalSpendRefreshedAt = snapshot.totalSpendRefreshedAt
                } else if provider.retainsDedicatedSpendOnScanFailure,
                          !Calendar.current.isDate(retained.totalSpendRefreshedAt ?? retained.refreshedAt,
                                                   inSameDayAs: snapshot.refreshedAt) {
                    retained.totalSpendLines = nil
                    retained.totalSpendRefreshedAt = nil
                }
                retained.warning = snapshot.warning
                retained.warningPresentation = snapshot.warningPresentation
                retained.authenticationIssue = snapshot.authenticationIssue
                retained.isDegraded = true
                retained.liveQuotaObservedAt = nil
                retained.codexResetClaimBinding = nil
                if let history = snapshot.usageHistory,
                   let descriptor = registry.historyDescriptorsByProvider[providerID] {
                    retained.usageHistory = history
                    retained = UsageHistorySnapshotRenderer.render(
                        local: retained, history: history, descriptor: descriptor, now: now(), combined: false
                    )
                }
                localSnapshots[providerID] = retained
                // 정상 캐시 없는 이력 전용 값은 저장하지 않음 — CLI가 이를 성공한 한도 조회로 오인하는 상황 방지.
                if !cache.hasStaleAccountStamp(providerID: providerID, currentIdentityKey: identityKeys[providerID]),
                   cache.loadSnapshots(providerIDs: [providerID])[providerID] != nil {
                    cache.store(
                        retained, producedByIdentityKey: identityKeys[providerID], markSessionFresh: false
                    )
                }
                notifyHistoryChange = snapshot.usageHistory != nil
            }
            return .failed(failure, render: render, notifyHistoryChange: notifyHistoryChange)
        }
        // 한도 조회는 성공했지만 로컬 이력이 없으면 마지막 정상 이력만 보존 — 새 한도·플랜·경고·시각은 반영.
        // nil이 아닌 빈 이력은 수집 완료 결과로 취급하여 기존 이력 제거.
        var degraded =
            snapshot.warning != nil || snapshot.isDegraded == true || snapshot.partialRefreshErrorCategory != nil
        if snapshot.usageHistory == nil,
            let history = previousSnapshot(for: snapshot)?.usageHistory,
            let descriptor = registry.historyDescriptorsByProvider[providerID]
        {
            degraded = true
            snapshot.isDegraded = true
            snapshot.usageHistory = history
            snapshot = UsageHistorySnapshotRenderer.render(
                local: snapshot,
                history: history,
                descriptor: descriptor,
                now: now(),
                combined: false
            )
            AppLog.debug(
                .refresh, "preserved last-good history for \(AppLog.providerFamily(providerID)) after scan miss")
        }
        if provider.retainsDedicatedSpendOnScanFailure, snapshot.totalSpendLines == nil,
           let previous = localSnapshots[providerID],
           Calendar.current.isDate(previous.totalSpendRefreshedAt ?? previous.refreshedAt, inSameDayAs: snapshot.refreshedAt),
           let lines = previous.totalSpendLines {
            degraded = true
            snapshot.totalSpendLines = lines
            snapshot.totalSpendRefreshedAt = previous.totalSpendRefreshedAt ?? previous.refreshedAt
            snapshot.isDegraded = true
        }
        localSnapshots[providerID] = snapshot
        // 현재 계정 식별 정보로 저장 결과 귀속 — 비계정 프로바이더·계정 미확인 카드는 식별 키 생략.
        let catalogIdentity = ProviderAccountID.family(of: providerID) == "cursor" ? nil : identityKeys[providerID]
        cache.store(snapshot, producedByIdentityKey: snapshot.producedByIdentityKey ?? catalogIdentity)
        if !unresolvedClaudeIdentity { unresolvedIdentityCacheRejections.remove(providerID) }
        return .succeeded(snapshot, degraded: degraded)
    }

    /// 다운로드한 다른 Mac의 이력 교체 — 기기별 최신 유효 문서만 유지하고 현재 Mac은 메모리 원본 사용.
    func setPeerHistoryDocuments(_ documents: [UsageHistoryDocument], ownDeviceID: String) {
        peerHistoryDocuments = UsageHistoryDocument.newestByDevice(documents)
            .filter { $0.deviceID != ownDeviceID }
    }

    func clearPeerHistoryDocuments() -> Bool {
        guard !peerHistoryDocuments.isEmpty else { return false }
        peerHistoryDocuments = []
        return true
    }

    func localHistoryDocument(
        deviceID: String, deviceName: String, updatedAt: Date = Date(),
        preserving previous: UsageHistoryDocument? = nil
    ) -> UsageHistoryDocument {
        var providers: [String: ProviderUsageHistory] = [:]
        var identities: [String: String] = [:]
        // 로컬 범위 이력은 계정 카드도 동기화 — 계정에서 파생한 ID로 동일 계정 연결.
        // 기본 카드의 이력은 별도 계정 식별 키로 다른 Mac의 카드에 연결.
        for (providerID, descriptor) in registry.historyDescriptorsByProvider
        where descriptor.scope == .machineLocal && isProviderEnabled(providerID) {
            let identity = familyTotalHistoryCardIDs.contains(providerID) ? nil : identityKeys[providerID]
            var history = localSnapshots[providerID]?.usageHistory
            if history == nil, !isUnresolvedClaude(providerID), let previous,
                previous.deviceID == deviceID, previous.identities?[providerID] == identity
            {
                history = previous.providers[providerID]
            }
            if let history {
                providers[providerID] = history
                // 공유 홈 이력은 전환한 모든 계정의 세션을 합한 프로바이더 합계.
                // 전체 합계가 현재 선택 계정에 귀속되지 않도록 계정 식별 키 없이 동기화.
                if let identity {
                    identities[providerID] = identity
                }
            }
        }
        return UsageHistoryDocument(
            deviceID: deviceID,
            deviceName: deviceName,
            updatedAt: updatedAt,
            providers: providers,
            identities: identities.isEmpty ? nil : identities
        )
    }

    func rendered(refreshResults: [String: ProviderRefreshResult]) -> Rendered {
        guard !peerHistoryDocuments.isEmpty else {
            return Rendered(snapshots: localSnapshots)
        }
        let renderDate = now()
        let enabledDescriptors = registry.historyDescriptorsByProvider.reduce(
            into: [String: UsageHistoryDescriptor]()
        ) { result, entry in
            guard isProviderEnabled(entry.key) else { return }
            if ProviderAccountID.family(of: entry.key) == "claude",
                identityKeys[entry.key] == nil,
               localSnapshots[entry.key] == nil,
               refreshResults[entry.key]?.failure != nil { return }
            result[entry.key] = entry.value
        }
        // 다른 Mac의 이력은 카드 ID 대신 계정 식별 정보로 연결 — 같은 계정도 Mac마다 카드 ID가 다를 수 있음.
        // 현재 Mac의 카드와 연결되지 않으면 Total Spend 전용 원격 항목으로 처리.
        let remapped = PeerHistoryRemapper.remap(
            documents: peerHistoryDocuments,
            localIdentityByCardID: identityKeys
        )
        let merged = UsageHistoryAggregator.merged(
            localSnapshots: localSnapshots,
            peerHistories: remapped.histories,
            descriptors: enabledDescriptors,
            now: renderDate
        )
        let enabledFamilies = Set(registry.historyDescriptorsByProvider.keys
            .filter { isProviderEnabled($0) }
            .map { ProviderAccountID.family(of: $0) })
        let remoteOnlySpend = Self.renderRemoteOnlySpend(
            remapped.remoteOnly.filter { enabledFamilies.contains($0.family) },
            registry: registry,
            now: renderDate
        )
        var rendered = localSnapshots
        for (providerID, history) in merged {
            guard let descriptor = registry.historyDescriptorsByProvider[providerID],
                  let provider = registry.provider(id: providerID)
            else { continue }
            let local = localSnapshots[providerID] ?? ProviderSnapshot(
                providerID: providerID,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: peerHistoryDocuments.map(\.updatedAt).max() ?? renderDate
            )
            rendered[providerID] = UsageHistorySnapshotRenderer.render(
                local: local,
                history: history,
                descriptor: descriptor,
                now: renderDate
            )
        }
        for entry in remoteOnlySpend where entry.snapshot.reportedPartialFailure == .decoding {
            let family = ProviderAccountID.family(of: entry.provider.id)
            guard let provider = registry.provider(id: family) else { continue }
            var snapshot =
                rendered[family]
                ?? ProviderSnapshot(
                    providerID: family, displayName: provider.displayName, lines: [], refreshedAt: renderDate)
            UsageHistorySnapshotRenderer.addInvalidHistoryWarning(to: &snapshot)
            rendered[family] = snapshot
        }
        return Rendered(snapshots: rendered, remoteOnlySpend: remoteOnlySpend)
    }

    /// 다른 Mac에만 있는 계정의 Total Spend 항목 생성 — 프로바이더 아이콘을 공유하는 가상 항목.
    /// 실제 카드와 같은 렌더러로 표준 지출 행 구성.
    private static func renderRemoteOnlySpend(
        _ remoteOnly: [PeerHistoryRemapper.RemoteOnlyHistory],
        registry: WidgetRegistry,
        now: Date
    ) -> [(provider: Provider, snapshot: ProviderSnapshot)] {
        remoteOnly.compactMap { entry in
            guard let familyProvider = registry.provider(id: entry.family),
                  let descriptor = registry.historyDescriptorsByProvider[entry.family]
            else { return nil }
            let history = UsageHistoryAggregator.mergeHistories(entry.histories, now: now)
            guard !history.series.daily.isEmpty || history.hasRejectedNumericContributions else { return nil }

            // 합계 항목 이름은 계정 식별 키에서 파생한 카드 ID 사용.
            // 가상 프로바이더 ID는 실제 카드 ID와 충돌하지 않는 별도 형식 사용.
            let provider = Provider(
                id: "\(entry.family)@peer-\(ProviderAccountID.hash8(entry.identityKey))",
                displayName: entry.cardID,
                icon: familyProvider.icon
            )
            let empty = ProviderSnapshot(
                providerID: provider.id,
                displayName: provider.displayName,
                lines: [],
                refreshedAt: now
            )
            let snapshot = UsageHistorySnapshotRenderer.render(
                local: empty,
                history: history,
                descriptor: descriptor,
                now: now
            )
            return (provider, snapshot)
        }
    }

}
