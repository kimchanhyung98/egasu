import Foundation
import Observation

@MainActor
@Observable
final class AccountRecommendationSettingsStore {
    static let reappearanceMinuteOptions = [1, 5, 15, 30, 60]
    private static let prefix = "openusage.accountRecommendations."
    private static let enabledKey = prefix + "enabled.v1"
    private static let triggerKey = prefix + "triggerPercent.v1"
    private static let candidateKey = prefix + "candidateLimitPercent.v1"
    private static let delayKey = prefix + "reappearanceMinutes.v1"
    private static let dismissedKey = prefix + "dismissedAt.v1"
    private let defaults: UserDefaults
    private var storedEnabled: Bool
    private var storedTrigger: Int
    private var storedCandidateLimit: Int
    private var dismissedAt: [String: Date]
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

    var reappearanceMinutes: Int {
        didSet {
            if !Self.reappearanceMinuteOptions.contains(reappearanceMinutes) { reappearanceMinutes = 15 }
            defaults.set(reappearanceMinutes, forKey: Self.delayKey)
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
        let delay = defaults.object(forKey: Self.delayKey) as? Int ?? 15
        reappearanceMinutes = Self.reappearanceMinuteOptions.contains(delay) ? delay : 15
        dismissedAt = defaults.dictionary(forKey: Self.dismissedKey) as? [String: Date] ?? [:]
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

    func dismiss(for family: String, at date: Date) {
        dismissedAt[family] = date
        defaults.set(dismissedAt, forKey: Self.dismissedKey)
    }

    func nextRecommendationDate(for family: String, at now: Date) -> Date? {
        guard isActive, let dismissed = dismissedAt[family] else { return nil }
        let deadline = dismissed.addingTimeInterval(TimeInterval(reappearanceMinutes * 60))
        return deadline > now ? deadline : nil
    }

    func recommendation(
        current: AccountProfile, profiles: [AccountProfile], at now: Date,
        quota: (AccountProfile) -> AccountSwitchQuota?
    ) -> AccountSwitchRecommendation? {
        guard isActive, nextRecommendationDate(for: current.family, at: now) == nil else { return nil }
        return .choose(
            current: current, profiles: profiles, at: now,
            triggerPercent: triggerPercent, candidateLimitPercent: candidateLimitPercent, quota: quota)
    }

    private func percentage(from text: String) -> Int? {
        guard let value = Int(text.trimmingCharacters(in: .whitespacesAndNewlines)), (1...100).contains(value) else {
            AppLog.warn(.config, "Invalid account recommendation threshold: expected a whole percentage from 1 to 100")
            return nil
        }
        return value
    }
}
