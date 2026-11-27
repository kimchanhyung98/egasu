import CryptoKit
import Foundation

@MainActor
final class CodexCreditExpiryReminders {
    static let prefix = "egasu.codex-credit-expiry."
    static var label: String { L10n.settings("Codex Reset Credit Expiry") }

    private let scheduler: ScheduledReminders
    private let defaults: UserDefaults
    private let receiptsKey = "openusage.notifications.codexCreditExpiry.claims"

    private struct Claim: Codable {
        let at: Date
        let expiry: Date
        let remaining: Int?
        let creditIDs: Set<String>
    }

    private struct Inventory: Equatable {
        let observedAt: Date
        let quotaObservedAt: Date?
        let count: Int?
        let expiries: [Date]

        init(confirmedExpiries: [Date], at date: Date) {
            observedAt = date
            quotaObservedAt = date
            count = confirmedExpiries.count
            expiries = confirmedExpiries.sorted()
        }

        init(_ snapshot: ProviderSnapshot) {
            quotaObservedAt = snapshot.liveQuotaObservedAt ?? snapshot.quotaObservedAt
            observedAt = quotaObservedAt ?? snapshot.refreshedAt
            if case .values(_, let values, _, let dates, _, _) = snapshot.line(label: "Rate Limit Resets") {
                count = values.first.flatMap { Int(exactly: $0.number) }
                expiries = dates.sorted()
            } else {
                count = nil
                expiries = []
            }
        }

        // 같은 시각에는 확정된 0개, 만료일이 있는 응답, 개수만 있는 응답 순으로 채택.
        var precedence: (Date, Int) {
            if count == 0 { return (observedAt, 3) }
            guard let count, count > 0 else { return (observedAt, 0) }
            return (observedAt, expiries.isEmpty ? 1 : 2)
        }
    }

    private struct Observation {
        let inventory: Inventory
        let undatedCount: Int
        var remaining: [TimeInterval: Int]
    }

    private var observations: [String: Observation] = [:]
    private var claims: [String: Claim]
    private static let invalidatedKey = "openusage.notifications.codexCreditExpiry.invalidatedCards"
    private(set) var invalidatedCards: Set<String> {
        didSet {
            if invalidatedCards != oldValue { defaults.set(invalidatedCards.sorted(), forKey: Self.invalidatedKey) }
        }
    }

    init(scheduler: ScheduledReminders, defaults: UserDefaults) {
        self.scheduler = scheduler
        self.defaults = defaults
        invalidatedCards = Set(defaults.stringArray(forKey: Self.invalidatedKey) ?? [])
        claims =
            defaults.data(forKey: receiptsKey).flatMap { try? JSONDecoder().decode([String: Claim].self, from: $0) }
            ?? [:]
    }

    func invalidate(_ ids: Set<String>) {
        invalidatedCards.formUnion(ids.filter { ProviderAccountID.family(of: $0) == "codex" })
    }

    func accept(_ snapshot: ProviderSnapshot) -> Bool {
        guard snapshot.liveQuotaObservedAt != nil, snapshot.authenticationIssue == nil else { return false }
        return invalidatedCards.remove(snapshot.providerID) != nil
    }

    func retainCards(_ ids: Set<String>) {
        invalidatedCards.formIntersection(ids)
    }

    /// 소비 직후의 조회가 실패하거나 재시작해도 이전 캐시로 사용한 권을 다시 예약하지 않음.
    func consumed(account: String, expiry: Date, creditID: String, remaining: Int?, at date: Date) {
        let bucket = Self.bucket(account: account, expiry: expiry)
        let credit = Self.digest(creditID)
        var consumed = claims[bucket]?.creditIDs ?? []
        guard consumed.insert(credit).inserted else { return }
        let previousBound = claims[bucket]?.remaining.map { max(0, $0 - 1) }
        let upperBound = [remaining, previousBound].compactMap { $0 }.min()
        claims[bucket] = Claim(at: date, expiry: expiry, remaining: upperBound, creditIDs: consumed)
        let second = floor(expiry.timeIntervalSince1970)
        if let known = observations[account]?.remaining[second] {
            let available = remaining == nil ? known - 1 : known
            let retained = min(available, upperBound ?? available)
            observations[account]?.remaining[second] = retained > 0 ? retained : nil
        }
        saveClaims()
    }

    func noneAvailable(account: String, expiry: Date, at date: Date) {
        let bucket = Self.bucket(account: account, expiry: expiry)
        claims[bucket] = Claim(at: date, expiry: expiry, remaining: 0, creditIDs: claims[bucket]?.creditIDs ?? [])
        observations[account]?.remaining.removeValue(forKey: floor(expiry.timeIntervalSince1970))
        saveClaims()
    }

    /// 전체 목록으로 현재 계정의 예약을 교체하고 이전 관측에 적용할 만료일별 예약 상한 저장.
    func confirmedInventory(
        account: String, expiries: [Date], selectedExpiry: Date, consumedID: String? = nil,
        snapshots: [ProviderSnapshot], at date: Date
    ) {
        let inventory = Inventory(confirmedExpiries: expiries, at: date)
        let counts = Dictionary(grouping: expiries, by: { floor($0.timeIntervalSince1970) }).mapValues(\.count)
        let selected = floor(selectedExpiry.timeIntervalSince1970)
        var seconds = Set(counts.keys)
        seconds.insert(selected)
        if let previous = observations[account] { seconds.formUnion(previous.remaining.keys) }
        for snapshot in snapshots {
            seconds.formUnion(Inventory(snapshot).expiries.map { floor($0.timeIntervalSince1970) })
        }
        for second in seconds {
            let expiry = Date(timeIntervalSince1970: second)
            let bucket = Self.bucket(account: account, expiry: expiry)
            var credits = claims[bucket]?.creditIDs ?? []
            if selected == second, let consumedID { credits.insert(Self.digest(consumedID)) }
            claims[bucket] = Claim(at: date, expiry: expiry, remaining: counts[second] ?? 0, creditIDs: credits)
        }
        observations[account] = Observation(inventory: inventory, undatedCount: 0, remaining: counts)
        saveClaims()
    }

    @discardableResult
    func reconcile(
        accounts: [(key: String, name: String, snapshot: ProviderSnapshot)], now: Date
    ) -> Task<Void, Never> {
        let previousClaimsCount = claims.count
        claims = claims.filter { $0.value.expiry > now }
        var latest: [String: (inventory: Inventory, cardID: String, name: String)] = [:]
        for account in accounts {
            let inventory = Inventory(account.snapshot)
            let cardID = account.snapshot.providerID
            if let selected = latest[account.key] {
                if selected.inventory.precedence > inventory.precedence { continue }
                if selected.inventory.precedence == inventory.precedence, selected.cardID <= cardID { continue }
            }
            latest[account.key] = (inventory, cardID, account.name)
        }

        observations = observations.filter { latest[$0.key] != nil }
        var reminders: [ScheduledReminder] = []
        for (account, selected) in latest {
            let observation = observation(for: account, inventory: selected.inventory, now: now)
            observations[account] = observation
            for (second, remaining) in observation.remaining {
                let key = Self.bucket(account: account, expiry: Date(timeIntervalSince1970: second))
                for occurrence in 0..<remaining {
                    for hours in [24, 12] {
                        let date = Date(timeIntervalSince1970: second - Double(hours * 3600))
                        guard date > now else { continue }
                        reminders.append(
                            ScheduledReminder(
                                id: "\(Self.prefix)\(key).\(occurrence).\(hours)", date: date, title: Self.label,
                                subtitle: selected.name,
                                body: L10n.settings("An unused reset credit expires in %lld hours.", hours)))
                    }
                }
            }
        }
        if claims.count != previousClaimsCount { saveClaims() }
        return scheduler.reconcile(reminders)
    }

    private func observation(for account: String, inventory: Inventory, now: Date) -> Observation {
        let previous = observations[account]
        if let previous,
            previous.inventory == inventory || previous.inventory.precedence > inventory.precedence
        {
            return previous
        }
        guard let count = inventory.count, count > 0 else {
            return Observation(inventory: inventory, undatedCount: 0, remaining: [:])
        }
        if inventory.expiries.isEmpty {
            var remaining = previous?.remaining.filter { $0.key > now.timeIntervalSince1970 } ?? [:]
            let undatedCount = previous?.undatedCount ?? 0
            if remaining.values.reduce(0, +) > count - undatedCount {
                // 모든 권의 만료일이 같을 때만 줄어든 개수를 해당 만료일에 적용.
                if undatedCount == 0, remaining.count == 1, let second = remaining.keys.first {
                    remaining[second] = count
                } else {
                    remaining.removeAll()
                }
            }
            let knownCount = remaining.values.reduce(0, +)
            return Observation(inventory: inventory, undatedCount: count - knownCount, remaining: remaining)
        }

        let known = inventory.expiries.filter { $0 > now }.prefix(count)
        let dates = Dictionary(grouping: known, by: { floor($0.timeIntervalSince1970) })
        var remaining: [TimeInterval: Int] = [:]
        for (second, expiries) in dates {
            let key = Self.bucket(account: account, expiry: Date(timeIntervalSince1970: second))
            var available = expiries.count
            if let claim = claims[key] {
                if let observed = inventory.quotaObservedAt, observed > claim.at {
                    claims.removeValue(forKey: key)
                } else {
                    available = min(available, claim.remaining ?? (available - claim.creditIDs.count))
                }
            }
            if available > 0 { remaining[second] = available }
        }
        return Observation(
            inventory: inventory, undatedCount: max(0, count - inventory.expiries.count), remaining: remaining)
    }

    private static func bucket(account: String, expiry: Date) -> String {
        let key = "\(account)\u{0}\(floor(expiry.timeIntervalSince1970))"
        return digest(key)
    }

    private static func digest(_ key: String) -> String {
        SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func saveClaims() {
        defaults.set(try? JSONEncoder().encode(claims), forKey: receiptsKey)
    }
}
