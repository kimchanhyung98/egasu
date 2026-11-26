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
        saveClaims()
    }

    func noneAvailable(account: String, expiry: Date, at date: Date) {
        let key = Self.bucket(account: account, expiry: expiry)
        claims[key] = Claim(at: date, expiry: expiry, remaining: 0, creditIDs: [])
        saveClaims()
    }

    @discardableResult
    func reconcile(
        accounts: [(key: String, name: String, snapshot: ProviderSnapshot)], now: Date
    ) -> Task<Void, Never> {
        let previousClaimsCount = claims.count
        claims = claims.filter { $0.value.expiry > now }
        var reminders: [ScheduledReminder] = []
        for account in accounts {
            guard
                case .values(_, let values, _, let expiries, _, _) = account.snapshot.line(label: "Rate Limit Resets"),
                let count = values.first?.number, count > 0
            else { continue }
            let known = expiries.filter { $0 > now }.sorted().prefix(Int(exactly: count) ?? 0)
            for (second, expiries) in Dictionary(grouping: known, by: { floor($0.timeIntervalSince1970) }) {
                let key = Self.bucket(account: account.key, expiry: Date(timeIntervalSince1970: second))
                var remaining = expiries.count
                if let claim = claims[key] {
                    if let observed = account.snapshot.liveQuotaObservedAt ?? account.snapshot.quotaObservedAt,
                        observed > claim.at
                    {
                        claims.removeValue(forKey: key)
                    } else {
                        remaining = claim.remaining ?? max(0, remaining - claim.creditIDs.count)
                    }
                }
                for occurrence in 0..<min(remaining, expiries.count) {
                    for hours in [24, 12] {
                        let date = Date(timeIntervalSince1970: second - Double(hours * 3600))
                        guard date > now else { continue }
                        reminders.append(
                            ScheduledReminder(
                                id: "\(Self.prefix)\(key).\(occurrence).\(hours)", date: date, title: Self.label,
                                subtitle: account.name,
                                body: L10n.settings("An unused reset credit expires in %lld hours.", hours)))
                    }
                }
            }
        }
        if claims.count != previousClaimsCount { saveClaims() }
        return scheduler.reconcile(reminders)
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
