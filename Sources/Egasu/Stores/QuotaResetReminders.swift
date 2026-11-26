import CryptoKit
import Foundation
import Observation

@MainActor
@Observable
final class QuotaResetReminders {
    static let prefix = "openusage.quota-reset."
    private static let invalidatedCardsKey = "openusage.notifications.quotaResetInvalidatedCards"
    private static let windowsKey = "openusage.notifications.quotaResetWindows"
    private static let leadHours = [24, 12]
    private static let supportedFamilies: Set<String> = ["claude", "codex", "cursor"]

    struct LimitKey: Codable, Hashable {
        let metricID: String
        let accountDigest: String

        init(descriptorID: String, account: String) {
            metricID = ProviderAccountID.canonicalMetricID(descriptorID)
            accountDigest = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        }

        var requestKey: String { "\(metricID).\(accountDigest)" }
    }

    private struct Window: Codable, Equatable {
        let period: SoftLimitWindow
        let reset: Date
        let positiveUsageObservedAt: Date?
        let pendingRecovery: NotificationState.Recovery?
        let elapsedHours: Set<Int>
    }

    @ObservationIgnored private var windows: [LimitKey: Window]
    private let scheduler: ScheduledReminders
    private let defaults: UserDefaults
    private var invalidatedCards: Set<String> {
        didSet { defaults.set(invalidatedCards.sorted(), forKey: Self.invalidatedCardsKey) }
    }

    init(
        scheduler: ScheduledReminders = ScheduledReminders(prefix: QuotaResetReminders.prefix),
        defaults: UserDefaults = .standard
    ) {
        self.scheduler = scheduler
        self.defaults = defaults
        invalidatedCards = Set(defaults.stringArray(forKey: Self.invalidatedCardsKey) ?? [])
        windows = [:]
        if let data = defaults.data(forKey: Self.windowsKey) {
            do {
                windows = try JSONDecoder().decode([LimitKey: Window].self, from: data)
            } catch {
                AppLog.warn(.notifications, "Could not read quota reset reminder windows")
            }
        }
    }

    private static func supports(_ card: String) -> Bool {
        supportedFamilies.contains(ProviderAccountID.family(of: card))
    }

    func invalidate(_ ids: Set<String>?) {
        guard let ids else { return }
        let supported = ids.filter { Self.supports($0) }
        if !supported.isSubset(of: invalidatedCards) { invalidatedCards.formUnion(supported) }
    }

    func refreshFailed(for card: String, category: ErrorCategory?) {
        switch category {
        case .authExpired, .authInvalid, .notLoggedIn: invalidate([card])
        default: break
        }
    }

    func receivedSnapshot(_ snapshot: ProviderSnapshot) {
        guard invalidatedCards.contains(snapshot.providerID), snapshot.authenticationIssue == nil,
            snapshot.liveQuotaObservedAt != nil
                || (snapshot.isDegraded != true && snapshot.quotaObservedAt == nil && snapshot.usageRetryAfter == nil)
        else { return }
        invalidatedCards.remove(snapshot.providerID)
    }

    func observe(settings: NotificationSettingsStore, dataStore: WidgetDataStore, enablement: ProviderEnablementStore) {
        observe { [weak self, weak settings, weak dataStore, weak enablement] invalidated in
            guard settings?.weeklyMonthlyResetReminders == true, let self, let dataStore, let enablement else {
                return []
            }
            let descriptorsByCard = dataStore.limitDescriptorsByProvider.filter { Self.supports($0.key) }
            let metricIDs = Set(descriptorsByCard.values.joined().map { ProviderAccountID.canonicalMetricID($0.id) })
            let failures = dataStore.refreshResults
            let snapshots = dataStore.localSnapshots
            let now = Date.now
            var latest:
                [LimitKey: (
                    snapshot: ProviderSnapshot, descriptor: WidgetDescriptor, name: String,
                    identity: String, observedAt: Date
                )] = [:]
            for (card, descriptors) in descriptorsByCard {
                guard enablement.isEnabled(card), !invalidated.contains(card),
                    let snapshot = snapshots[card], failures[card]?.failure?.authenticationIssue == nil,
                    snapshot.authenticationIssue == nil, snapshot.refreshFailure == nil,
                    dataStore.reconciliationFailure(for: card) == nil
                else { continue }
                let catalogIdentity: String?
                if case .account(let current) = dataStore.claimRefreshBinding(providerID: card) {
                    catalogIdentity = current
                } else {
                    catalogIdentity = nil
                }
                guard let identity = Self.accountIdentity(for: snapshot, catalogIdentity: catalogIdentity) else {
                    continue
                }
                let managed = ProviderAccountID.families.contains(ProviderAccountID.family(of: card))
                let hasAccountName = (!managed || catalogIdentity != nil) && Self.canUseRegisteredName(for: snapshot)
                let accountName = hasAccountName ? dataStore.resolveDisplayName?(card) : nil
                let name = accountName ?? ProviderAccountID.cardTitle(providerID: card, fallback: snapshot.displayName)
                let observedAt = snapshot.liveQuotaObservedAt ?? snapshot.freshnessDate
                // 최신 관측에서 초기화 시각이 사라진 경우도 이전 별칭의 예약을 대체.
                for descriptor in descriptors {
                    let key = LimitKey(descriptorID: descriptor.id, account: identity)
                    if let previous = latest[key] {
                        if previous.observedAt > observedAt { continue }
                        if previous.observedAt == observedAt, previous.snapshot.providerID <= card { continue }
                    }
                    latest[key] = (snapshot, descriptor, name, identity, observedAt)
                }
            }

            var observedKeys: Set<LimitKey> = []
            let reminders = latest.values.flatMap { reading in
                Self.reminders(
                    for: reading.snapshot, descriptors: [reading.descriptor], account: reading.name,
                    now: now, accountIdentity: reading.identity
                ) { key, period, reset, duration, used in
                    observedKeys.insert(key)
                    return self.elapsedHours(
                        key: key, period: period, reset: reset, duration: duration,
                        used: used, observedAt: reading.observedAt, now: now)
                }
            }
            // 카드에서 잠시 빠진 계정도 남은 주기 동안 기록 유지.
            self.windows = self.windows.filter { key, window in
                observedKeys.contains(key) || (metricIDs.contains(key.metricID) && window.reset > now)
            }
            return reminders
        }
    }

    private static func accountIdentity(for snapshot: ProviderSnapshot, catalogIdentity: String?) -> String? {
        switch ProviderAccountID.family(of: snapshot.providerID) {
        case "claude":
            guard let catalogIdentity else { return snapshot.liveQuotaAccountKey }
            let identity: String
            if catalogIdentity.contains("|") {
                identity = catalogIdentity
            } else {
                guard let verified = snapshot.legacyClaudeSwitchIdentity?.identityKey,
                    verified.hasPrefix(catalogIdentity + "|"), snapshot.liveQuotaAccountKey != nil
                else { return nil }
                identity = verified
            }
            let key = UsageTimerObservation.accountKey(family: "claude", identity: identity)
            if let reading = snapshot.liveQuotaAccountKey, reading != key { return nil }
            return key
        case "codex":
            if let catalogIdentity, snapshot.codexSwitchIdentity != catalogIdentity { return nil }
            return snapshot.liveQuotaAccountKey
        case "cursor":
            return snapshot.producedByIdentityKey
        default:
            return nil
        }
    }

    private static func canUseRegisteredName(for snapshot: ProviderSnapshot) -> Bool {
        guard ProviderAccountID.family(of: snapshot.providerID) == "codex" else { return true }
        guard case .accountSnapshot(let profileID) = snapshot.codexResetClaimBinding?.source else { return false }
        return snapshot.providerID == AccountUsageCardPlanner.cardID(family: "codex", profileID: profileID)
    }

    private func observe(_ desired: @escaping @MainActor (Set<String>) -> [ScheduledReminder]) {
        let previous = windows
        let reminders = withObservationTracking {
            desired(invalidatedCards)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(desired) }
        }
        if windows != previous {
            do {
                defaults.set(try JSONEncoder().encode(windows), forKey: Self.windowsKey)
            } catch {
                AppLog.warn(.notifications, "Could not save quota reset reminder windows")
            }
        }
        scheduler.reconcile(reminders)
    }

    private func elapsedHours(
        key: LimitKey, period: SoftLimitWindow, reset: Date, duration: Int?, used: Double, observedAt: Date,
        now: Date
    ) -> Set<Int> {
        let stored = windows[key]
        let previous = stored?.period == period ? stored : nil
        let state = NotificationState(
            resetsAt: previous?.reset, positiveUsageObservedAt: previous?.positiveUsageObservedAt,
            pendingRecovery: previous?.pendingRecovery)
        let change = PaceNotificationLogic.windowChange(
            from: state, used: used, resetsAt: reset, period: duration.map { Double($0) / 1000 }, now: observedAt)
        let updated = PaceNotificationLogic.carriedOver(
            state, used: used, resetsAt: reset, change: change, now: observedAt)

        var elapsed = Set(Self.leadHours.filter { Self.fireDate(reset: reset, hours: $0) <= now })
        if change == .unchanged, let previous {
            elapsed.formUnion(previous.elapsedHours)
            elapsed.formUnion(Self.leadHours.filter { Self.fireDate(reset: previous.reset, hours: $0) <= now })
        }
        windows[key] = Window(
            period: period, reset: reset, positiveUsageObservedAt: updated.positiveUsageObservedAt,
            pendingRecovery: updated.pendingRecovery, elapsedHours: elapsed)
        return elapsed
    }

    private static func fireDate(reset: Date, hours: Int) -> Date {
        Date(timeIntervalSince1970: reset.timeIntervalSince1970.rounded(.down) - Double(hours * 3600))
    }

    static func reminders(
        for snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor], account: String, now: Date,
        accountIdentity: String?,
        elapsedHours: (LimitKey, SoftLimitWindow, Date, Int?, Double) -> Set<Int> = { _, _, _, _, _ in [] }
    ) -> [ScheduledReminder] {
        guard supports(snapshot.providerID), let accountIdentity,
            snapshot.authenticationIssue == nil, snapshot.refreshFailure == nil,
            !ProviderSnapshotCache.requiresCredentialIdentity(snapshot.providerID)
                || snapshot.producedByIdentityKey == accountIdentity
        else { return [] }
        var reminders: [ScheduledReminder] = []
        for descriptor in descriptors {
            guard let line = snapshot.line(label: descriptor.metricLabel),
                case let .progress(_, used, limit, format, reset?, duration, _) = line, limit > 0,
                !descriptor.isCursorRequestLimitAlias(format: format),
                descriptor.limitResources.contains(where: {
                    $0.kind == .consumption && !$0.estimated && $0.matches(line)
                })
            else { continue }

            let window = SoftLimitWindow.allCases.first { window in
                guard descriptor.softLimitWindows.isEmpty || descriptor.softLimitWindows.contains(window) else {
                    return false
                }
                if let duration {
                    return window.matches(
                        periodDurationMs: duration, allowsDSTOffset: descriptor.softLimitAllowsDSTOffset)
                }
                return descriptor.acceptsMissingSoftLimitDuration && descriptor.softLimitWindows == [window]
            }
            guard let window else { continue }
            let title = window == .weekly ? L10n.settings("Weekly Limit Reset") : L10n.settings("Monthly Limit Reset")
            guard let resetSeconds = Int64(exactly: reset.timeIntervalSince1970.rounded(.down)) else { continue }
            let key = LimitKey(descriptorID: descriptor.id, account: accountIdentity)
            let elapsed = elapsedHours(key, window, reset, duration, used)
            for hours in leadHours where !elapsed.contains(hours) {
                let fire = fireDate(reset: reset, hours: hours)
                guard fire > now else { continue }
                reminders.append(
                    ScheduledReminder(
                        id: "\(prefix)\(key.requestKey).\(resetSeconds).\(hours)", date: fire, title: title,
                        subtitle: L10n.metrics("%@ %@", account, descriptor.sample.localizedTitle),
                        body: L10n.settings("This limit resets in %lld hours.", hours)))
            }
        }
        return reminders
    }
}
