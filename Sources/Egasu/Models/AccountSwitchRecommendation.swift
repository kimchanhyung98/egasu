import Foundation

/// 조직을 저장하지 않은 Claude 로그인은 이번 조회에서 검증한 조직과 토큰에만 연결.
struct LegacyClaudeRecommendationIdentity: Hashable, Sendable {
    let identityKey: String
    private let tokenFingerprint: String

    init(identityKey: String, accessToken: String) {
        self.identityKey = identityKey
        tokenFingerprint = AccountSwitchJournal.fingerprint(accessToken)
    }

    func matches(_ entry: AccountCredentialVault.Entry) -> Bool {
        guard let token = ClaudeAuthStore.parseCredentials(entry.credential)?.claudeAiOauth?.accessToken else {
            return false
        }
        return AccountSwitchJournal.fingerprint(token) == tokenFingerprint
    }
}

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
    var legacyClaudeIdentity: LegacyClaudeRecommendationIdentity?

    static func claude(lines: [MetricLine]) -> Self {
        var result = Self()
        for line in lines {
            guard line.label == "Session" || line.label == "Weekly" else { continue }
            guard case .progress(_, let used, 100, .percent, let reset, _, _) = line, used.isFinite, used >= 0 else {
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
    var legacyCurrentIdentityKey: String?
    var legacyTargetIdentity: LegacyClaudeRecommendationIdentity?

    struct NoLongerAvailable: Error {}

    func validate(departure: String?, latest: Self?) throws {
        guard departure == (legacyCurrentIdentityKey ?? current.identityKey), latest == self else {
            throw NoLongerAvailable()
        }
    }

    func validateTarget(_ entry: AccountCredentialVault.Entry) throws {
        if let legacyTargetIdentity, !legacyTargetIdentity.matches(entry) { throw NoLongerAvailable() }
    }

    static func choose(
        current: AccountProfile, profiles: [AccountProfile], at now: Date,
        quota: (AccountProfile) -> AccountSwitchQuota?
    ) -> Self? {
        guard let currentQuota = quota(current), currentQuota.needsSwitch(at: now) else { return nil }
        let currentIdentity = currentQuota.legacyClaudeIdentity?.identityKey ?? current.identityKey
        var best: (recommendation: Self, reset: Date)?
        for profile in profiles
        where profile.family == current.family && !profile.isArchived
            && profile.id != current.id
        {
            guard let reading = quota(profile),
                (reading.legacyClaudeIdentity?.identityKey ?? profile.identityKey) != currentIdentity,
                let reset = reading.nextCandidateReset(at: now), best.map({ reset < $0.reset }) ?? true
            else { continue }
            let recommendation = Self(
                current: current, target: profile,
                legacyCurrentIdentityKey: currentQuota.legacyClaudeIdentity?.identityKey,
                legacyTargetIdentity: reading.legacyClaudeIdentity)
            best = (recommendation, reset)
        }
        return best?.recommendation
    }
}
