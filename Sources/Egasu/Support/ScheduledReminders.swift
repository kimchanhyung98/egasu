import Foundation
import UserNotifications

struct ScheduledReminder: Equatable {
    let id: String
    let date: Date
    let title: String
    let subtitle: String
    let body: String

    var request: UNNotificationRequest {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let components = calendar.dateComponents(
            [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: date)
        let content = UNMutableNotificationContent()
        content.title = title
        content.subtitle = subtitle
        content.body = body
        content.sound = .default
        content.threadIdentifier = "openusage"
        return UNNotificationRequest(
            identifier: id, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
    }
}

@MainActor
final class ScheduledReminders {
    typealias Schedule = @MainActor (ScheduledReminder, @escaping @MainActor () -> Bool) async -> Void

    private let prefix: String
    private let now: () -> Date
    private let pending: @MainActor () async -> [ScheduledReminder]
    private let schedule: Schedule
    private let remove: @MainActor ([String]) -> Void
    private var desired: [String: ScheduledReminder] = [:]
    private var dirty = false
    private var worker: Task<Void, Never>?

    init(
        prefix: String, now: @escaping () -> Date = Date.init,
        pending: @escaping @MainActor () async -> [ScheduledReminder] = ScheduledReminders.pendingRequests,
        schedule: @escaping Schedule = ScheduledReminders.scheduleRequest,
        remove: @escaping @MainActor ([String]) -> Void = ScheduledReminders.removeRequests
    ) {
        self.prefix = prefix
        self.now = now
        self.pending = pending
        self.schedule = schedule
        self.remove = remove
    }

    /// 시스템에 남은 예약과 비교해 재실행 후에도 같은 시점의 알림은 한 건만 유지.
    @discardableResult
    func reconcile(_ reminders: [ScheduledReminder]) -> Task<Void, Never> {
        desired = Dictionary(
            reminders.filter { $0.id.hasPrefix(prefix) }.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        dirty = true
        if let worker { return worker }
        let task = Task { await reconcilePending() }
        worker = task
        return task
    }

    private func reconcilePending() async {
        defer { worker = nil }
        while dirty {
            dirty = false
            let requests = await pending().filter { $0.id.hasPrefix(prefix) }
            let current = desired.filter { $0.value.date > now() }
            let obsolete = requests.filter { current[$0.id] == nil }.map(\.id)
            if !obsolete.isEmpty { remove(obsolete) }
            let existing = Dictionary(uniqueKeysWithValues: requests.map { ($0.id, $0) })
            for reminder in current.values.sorted(by: { $0.date < $1.date }) where existing[reminder.id] != reminder {
                let isCurrent = { @MainActor [self] in desired[reminder.id] == reminder && reminder.date > now() }
                guard isCurrent() else { continue }
                await schedule(reminder, isCurrent)
            }
        }
    }

    private static func pendingRequests() async -> [ScheduledReminder] {
        guard !AppNotifications.isRunningUnderTests else { return [] }
        return await UNUserNotificationCenter.current().pendingNotificationRequests().compactMap { request in
            guard let trigger = request.trigger as? UNCalendarNotificationTrigger,
                let date = trigger.nextTriggerDate()
            else { return nil }
            return ScheduledReminder(
                id: request.identifier, date: date, title: request.content.title,
                subtitle: request.content.subtitle, body: request.content.body)
        }
    }

    private static func scheduleRequest(_ reminder: ScheduledReminder, isCurrent: @escaping @MainActor () -> Bool) async
    {
        guard !AppNotifications.isRunningUnderTests else { return }
        let center = UNUserNotificationCenter.current()
        let request = reminder.request
        do {
            _ = try await AppNotifications.deliver(
                request, isCurrent: isCurrent,
                authorize: {
                    await AppNotifications.isAuthorizedForDelivery(
                        idPrefix: "scheduled", authorization: AppNotifications.shared.requestAuthorization(),
                        authorizationStatus: { await center.notificationSettings().authorizationStatus })
                }, add: { try await center.add($0) }, remove: { removeRequests([$0]) })
        } catch {
            AppDiagnostics.failure(.notificationDelivery, error: error)
        }
    }

    private static func removeRequests(_ ids: [String]) {
        guard !AppNotifications.isRunningUnderTests else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ids)
    }
}
