import Foundation
import Observation

@MainActor
@Observable
final class AccountRecommendationSettingsStore {
    private static let prefix = "openusage.accountRecommendations."
    private static let enabledKey = prefix + "enabled.v1"
    private static let triggerKey = prefix + "triggerPercent.v1"
    private static let candidateKey = prefix + "candidateLimitPercent.v1"
    private static let dismissedKey = prefix + "dismissals.v2"
    private let defaults: UserDefaults
    private var storedEnabled: Bool
    private var storedTrigger: Int
    private var storedCandidateLimit: Int
    private var dismissals: [Dismissal]
    private(set) var labsAvailable: Bool

    var enabled: Bool {
        get { storedEnabled }
        set {
            guard (!newValue || labsAvailable), newValue != storedEnabled else { return }
            storedEnabled = newValue
            defaults.set(newValue, forKey: Self.enabledKey)
        }
    }

    var isActive: Bool { labsAvailable && enabled }

    var triggerPercent: Int {
        get { storedTrigger }
        set {
            storedTrigger = min(max(newValue, 1), 100)
            defaults.set(storedTrigger, forKey: Self.triggerKey)
        }
    }

    var candidateLimitPercent: Int {
        get { storedCandidateLimit }
        set {
            storedCandidateLimit = min(max(newValue, 1), 100)
            defaults.set(storedCandidateLimit, forKey: Self.candidateKey)
        }
    }

    init(defaults: UserDefaults = .standard, labsAvailable: Bool) {
        self.defaults = defaults
        self.labsAvailable = labsAvailable
        storedEnabled = defaults.bool(forKey: Self.enabledKey, default: false)
        storedTrigger = min(
            max(
                defaults.object(forKey: Self.triggerKey) as? Int ?? AccountSwitchRecommendation.defaultTriggerPercent, 1
            ), 100)
        storedCandidateLimit = min(
            max(
                defaults.object(forKey: Self.candidateKey) as? Int
                    ?? AccountSwitchRecommendation.defaultCandidateLimitPercent, 1), 100)
        if let data = defaults.data(forKey: Self.dismissedKey) {
            do { dismissals = try JSONDecoder().decode([Dismissal].self, from: data) } catch {
                dismissals = []
                AppLog.error(.config, "Could not read account recommendation dismissals")
            }
        } else {
            dismissals = []
        }
        defaults.removeObject(forKey: Self.prefix + "reappearanceMinutes.v1")
        defaults.removeObject(forKey: Self.prefix + "dismissedAt.v1")
        if !labsAvailable { enabled = false }
    }

    func setLabsAvailable(_ available: Bool) {
        labsAvailable = available
        if !available { enabled = false }
    }

    func setTrigger(from text: String) -> Bool {
        guard let value = percentage(from: text) else { return false }
        triggerPercent = value
        return true
    }

    func setCandidateLimit(from text: String) -> Bool {
        guard let value = percentage(from: text) else { return false }
        candidateLimitPercent = value
        return true
    }

    @discardableResult
    func dismiss(
        _ recommendation: AccountSwitchRecommendation, at date: Date,
        quota: (AccountProfile) -> AccountSwitchQuota?
    ) -> Bool {
        guard let departureQuota = quota(recommendation.current), let targetQuota = quota(recommendation.target),
            let departureKey = accountKey(for: recommendation.current, quota: departureQuota),
            let targetKey = accountKey(for: recommendation.target, quota: targetQuota)
        else { return false }
        let family = recommendation.current.family
        dismissals.removeAll {
            $0.family == family && $0.departure.accountKey == departureKey && $0.target.accountKey == targetKey
        }
        dismissals.append(
            Dismissal(
                family: family,
                departure: Session(
                    accountKey: departureKey, window: departureQuota.windows[.session], family: family, at: date),
                target: Session(accountKey: targetKey, window: targetQuota.windows[.session], family: family, at: date))
        )
        saveDismissals()
        return true
    }

    /// 신원·신선도 검증을 통과한 계정 관측만 사용하며 기능을 끈 동안에도 세션 기준 갱신.
    func observeSession(for profile: AccountProfile, quota: AccountSwitchQuota, observedAt: Date, at now: Date) {
        guard observedAt <= now, let window = quota.windows[.session],
            let key = accountKey(for: profile, quota: quota)
        else { return }
        let updated = dismissals.compactMap { original -> Dismissal? in
            guard original.family == profile.family else { return original }
            var record = original
            if record.departure.accountKey == key,
                record.departure.observe(window, family: profile.family, at: observedAt)
            {
                return nil
            }
            if record.target.accountKey == key,
                record.target.observe(window, family: profile.family, at: observedAt)
            {
                return nil
            }
            return record
        }
        guard updated != dismissals else { return }
        dismissals = updated
        saveDismissals()
    }

    func recommendation(
        current: AccountProfile, profiles: [AccountProfile], at now: Date,
        quota: (AccountProfile) -> AccountSwitchQuota?
    ) -> AccountSwitchRecommendation? {
        guard isActive, let currentQuota = quota(current),
            let currentKey = accountKey(for: current, quota: currentQuota)
        else { return nil }
        let records = dismissals.filter { $0.family == current.family }
        guard !records.contains(where: { $0.departure.accountKey == currentKey }) else { return nil }
        let eligible = profiles.filter { profile in
            guard let reading = quota(profile), let key = accountKey(for: profile, quota: reading) else { return false }
            return !records.contains { $0.target.accountKey == key }
        }
        return .choose(
            current: current, profiles: eligible, at: now,
            triggerPercent: triggerPercent, candidateLimitPercent: candidateLimitPercent, quota: quota)
    }

    private func accountKey(for profile: AccountProfile, quota: AccountSwitchQuota) -> String? {
        if profile.family == "codex" { return quota.codexAccountKey }
        return UsageTimerObservation.accountKey(
            family: profile.family, identity: quota.legacyClaudeIdentity?.identityKey ?? profile.identityKey)
    }

    private func saveDismissals() {
        do { defaults.set(try JSONEncoder().encode(dismissals), forKey: Self.dismissedKey) } catch {
            AppLog.error(.config, "Could not save account recommendation dismissals")
        }
    }

    private struct Dismissal: Codable, Equatable {
        let family: String
        var departure: Session
        var target: Session
    }

    private struct Session: Codable, Equatable {
        let accountKey: String
        var reset: Date?
        var used: Double
        var started: Bool
        var stableSince: Date
        var observedAt: Date

        init(accountKey: String, window: AccountSwitchQuota.Window?, family: String, at date: Date) {
            self.accountKey = accountKey
            reset = window?.reset.flatMap { $0 > date ? $0 : nil }
            used = window?.percent ?? 0
            started = (used > 0 && (window?.reset == nil || reset != nil)) || (family == "claude" && reset != nil)
            stableSince = date
            observedAt = date
        }

        mutating func observe(_ window: AccountSwitchQuota.Window, family: String, at date: Date) -> Bool {
            guard date > observedAt else { return false }
            observedAt = date
            guard let next = window.reset, next > date else {
                if family == "claude", started, window.percent == 0 { return true }
                if window.reset == nil, window.percent > 0 {
                    if !started {
                        reset = nil
                        used = window.percent
                        started = true
                    } else {
                        used = max(used, window.percent)
                    }
                }
                return false
            }
            let sameReset = UsageTimerObservation.resetTimesMatch(reset, next)
            if started {
                if reset != nil, used > 0, window.percent == 0 { return true }
                if let reset, !sameReset,
                    date >= reset || window.percent == 0 || window.percent < used
                {
                    return true
                }
            }
            if !sameReset {
                reset = next
                stableSince = date
            }
            if window.percent > 0 || (family == "claude" && reset != nil)
                || (reset != nil && sameReset
                    && date.timeIntervalSince(stableSince) >= UsageTimerObservation.verificationInterval)
            {
                started = true
            }
            used = window.percent
            return false
        }
    }

    private func percentage(from text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...100).contains(value) else {
            AppLog.warn(.config, "Invalid account recommendation threshold: expected a whole percentage from 1 to 100")
            return nil
        }
        return value
    }
}
