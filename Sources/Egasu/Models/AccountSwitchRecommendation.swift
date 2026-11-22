import Foundation

/// 기본 구독 한도의 이번 응답만 비교. 서버가 생략한 기간은 해당 요금제에 없는 기간으로 처리.
struct AccountSwitchQuota: Hashable, Sendable {
    enum Period: Hashable, Sendable {
        case session, weekly, monthly
    }

    struct Window: Hashable, Sendable {
        var percent: Double
        var reset: Date?
    }

    var windows: [Period: Window] = [:]
    var incomplete = false

    static func claude(lines: [MetricLine]) -> Self {
        var result = Self()
        for line in lines {
            guard line.label == "Session" || line.label == "Weekly" else { continue }
            guard case .progress(_, let used, 100, .percent, let reset, _, _) = line, (0...100).contains(used) else {
                result.incomplete = true
                continue
            }
            result.windows[line.label == "Session" ? .session : .weekly] = Window(percent: used, reset: reset)
        }
        return result
    }

    func needsSwitch(at now: Date) -> Bool {
        windows.values.contains { $0.percent >= 95 && ($0.reset ?? .distantFuture) > now }
    }

    func nextCandidateReset(at now: Date) -> Date? {
        guard !incomplete, windows.values.allSatisfy({ $0.percent < 90 && ($0.reset ?? .distantFuture) > now }) else {
            return nil
        }
        return [windows[.session]?.reset, windows[.weekly]?.reset].compactMap { $0 }.min()
    }
}

extension ProviderSnapshot {
    var accountSwitchQuota: AccountSwitchQuota? {
        switch ProviderAccountID.family(of: providerID) {
        case "claude": .claude(lines: lines)
        case "codex": codexSwitchQuota
        default: nil
        }
    }

    func recommendationDeadlines(after now: Date) -> [Date] {
        guard let observed = liveQuotaObservedAt, liveQuotaAccountKey != nil else { return [] }
        let expiry = observed.addingTimeInterval(RefreshSetting.interval(for: providerID))
        guard expiry > now, let quota = accountSwitchQuota, !quota.windows.isEmpty else { return [] }
        let resets = quota.windows.values.compactMap(\.reset).filter { $0 > now && $0 < expiry }
        return (observed > now ? [observed, expiry] : [expiry]) + resets
    }
}

struct AccountSwitchRecommendation: Equatable {
    let current: AccountProfile
    let target: AccountProfile

    struct NoLongerAvailable: Error {}

    func validate(departure: String?, latest: Self?) throws {
        guard departure == current.identityKey, latest == self else { throw NoLongerAvailable() }
    }

    static func choose(
        current: AccountProfile, profiles: [AccountProfile], at now: Date,
        quota: (AccountProfile) -> AccountSwitchQuota?
    ) -> Self? {
        guard quota(current)?.needsSwitch(at: now) == true else { return nil }
        var best: (AccountProfile, Date)?
        for profile in profiles
        where profile.family == current.family && !profile.isArchived
            && profile.id != current.id && profile.identityKey != current.identityKey
        {
            guard let reset = quota(profile)?.nextCandidateReset(at: now),
                best.map({ reset < $0.1 }) ?? true
            else { continue }
            best = (profile, reset)
        }
        return best.map { Self(current: current, target: $0.0) }
    }
}
