import Foundation

/// 다른 Mac의 동기화 이력을 계정 식별자로 이 Mac의 카드에 연결.
/// 식별 정보가 부족한 기본 카드와 식별자가 없는 추가 카드는 카드 ID로 대조.
/// 이 Mac에 카드 없는 peer 계정은 `remoteOnly` — Total Spend에만 표시, ghost 카드 금지.
enum PeerHistoryRemapper {
    struct Remapped {
        /// 로컬 카드 id로 주소 지정된 peer history — same-id day merge 대상.
        var histories: [(cardID: String, history: ProviderUsageHistory)] = []
        /// 로컬 카드 없는 peer 계정 — identity 기준 그룹.
        var remoteOnly: [RemoteOnlyHistory] = []
    }

    struct RemoteOnlyHistory {
        var identityKey: String
        var family: String
        /// 계정 식별자로 생성한 ID 또는 원격 카드 ID.
        /// Total Spend slice 이름 — 출처 Mac은 의도적 미포함(합계에 무관).
        var cardID: String
        var histories: [ProviderUsageHistory]
    }

    /// `localIdentityByCardID`: 이 Mac의 카드 → identity map (launch 계정 pass의 `identityKeysByCard`).
    static func remap(
        documents: [UsageHistoryDocument],
        localIdentityByCardID: [String: String]
    ) -> Remapped {
        // identity → 카드로 역전 — 한 identity가 로컬 카드 2개에 동시 등장 시(swap 전후 일시 가능) bare(default) 카드 우선.
        var localCardByIdentity: [String: String] = [:]
        for (cardID, identity) in localIdentityByCardID.sorted(by: { $0.key < $1.key }) {
            if let existing = localCardByIdentity[identity], !ProviderAccountID.isAccountCard(existing) {
                continue
            }
            if ProviderAccountID.isAccountCard(cardID), localCardByIdentity[identity] != nil {
                continue
            }
            localCardByIdentity[identity] = cardID
        }

        var result = Remapped()
        var remoteByIdentity: [String: RemoteOnlyHistory] = [:]
        func collectRemoteOnly(identity: String, family: String, cardID: String, history: ProviderUsageHistory) {
            var entry = remoteByIdentity[identity] ?? RemoteOnlyHistory(
                identityKey: identity, family: family, cardID: cardID, histories: []
            )
            entry.histories.append(history)
            remoteByIdentity[identity] = entry
        }

        for document in UsageHistoryDocument.newestByDevice(documents) {
            for (peerCardID, history) in document.providers.sorted(by: { $0.key < $1.key }) {
                let family = ProviderAccountID.family(of: peerCardID)
                if let identity = document.identities?[peerCardID] {
                    if let localCard = localCardByIdentity[identity] {
                        result.histories.append((localCard, history))
                    } else if !ProviderAccountID.isAccountCard(peerCardID), localIdentityByCardID[peerCardID] == nil {
                        // 로컬 기본 카드의 계정이 미확인이면 카드 ID로 병합해 같은 계정의 이력 분리를 방지.
                        // 로컬 계정이 확인되면 계정 식별자로 다시 대조.
                        result.histories.append((peerCardID, history))
                    } else {
                        collectRemoteOnly(
                            identity: identity,
                            family: family,
                            cardID: ProviderAccountID.make(family: family, identityKey: identity),
                            history: history
                        )
                    }
                    continue
                }
                // identity 미기록(v1 문서, 또는 peer가 미식별한 카드): bare id는 legacy same-card-id merge, account-card id는 이 Mac에 같은 id 있으면 매칭, 없으면 remote-only.
                // 이 경우 원격 카드 ID를 그룹과 표시 식별자로 사용.
                if !ProviderAccountID.isAccountCard(peerCardID) || localIdentityByCardID[peerCardID] != nil {
                    result.histories.append((peerCardID, history))
                } else {
                    collectRemoteOnly(identity: peerCardID, family: family, cardID: peerCardID, history: history)
                }
            }
        }

        result.remoteOnly = remoteByIdentity.values.sorted { $0.identityKey < $1.identityKey }
        return result
    }
}
