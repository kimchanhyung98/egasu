import Foundation
import Observation

@MainActor
@Observable
final class QuotaResetReminders {
    static let prefix = "openusage.quota-reset."
    private static let invalidatedCardsKey = "openusage.notifications.quotaResetInvalidatedCards"
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
    }

    func invalidate(_ ids: Set<String>?) {
        if let ids, !ids.isSubset(of: invalidatedCards) { invalidatedCards.formUnion(ids) }
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
        observe { [weak settings, weak dataStore, weak enablement] invalidated in
            guard settings?.weeklyMonthlyResetReminders == true, let dataStore, let enablement else { return [] }
            let failures = dataStore.refreshResults
            return dataStore.limitDescriptorsByProvider.flatMap { card, descriptors -> [ScheduledReminder] in
                guard enablement.isEnabled(card), !invalidated.contains(card),
                    let snapshot = dataStore.localSnapshots[card], failures[card]?.failure?.authenticationIssue == nil,
                    dataStore.reconciliationFailure(for: card) == nil
                else { return [] }
                let name = dataStore.resolveDisplayName?(card) ?? snapshot.displayName
                return Self.reminders(for: snapshot, descriptors: descriptors, account: name, now: .now)
            }
        }
    }

    private func observe(_ desired: @escaping @MainActor (Set<String>) -> [ScheduledReminder]) {
        let reminders = withObservationTracking {
            desired(invalidatedCards)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observe(desired) }
        }
        scheduler.reconcile(reminders)
    }

    static func reminders(
        for snapshot: ProviderSnapshot, descriptors: [WidgetDescriptor], account: String, now: Date
    ) -> [ScheduledReminder] {
        guard snapshot.authenticationIssue == nil, snapshot.refreshFailure == nil,
            !ProviderSnapshotCache.requiresCredentialIdentity(snapshot.providerID)
                || snapshot.producedByIdentityKey != nil
        else { return [] }
        var reminders: [ScheduledReminder] = []
        for descriptor in descriptors {
            guard let line = snapshot.line(label: descriptor.metricLabel),
                case let .progress(_, _, limit, _, reset?, duration, _) = line, limit > 0,
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
            for hours in [24, 12] {
                let fire = Date(timeIntervalSince1970: TimeInterval(resetSeconds) - Double(hours * 3600))
                guard fire > now else { continue }
                reminders.append(
                    ScheduledReminder(
                        id: "\(prefix)\(descriptor.id).\(resetSeconds).\(hours)", date: fire, title: title,
                        subtitle: L10n.metrics("%@ %@", account, descriptor.sample.localizedTitle),
                        body: L10n.settings("This limit resets in %lld hours.", hours)))
            }
        }
        return reminders
    }
}
