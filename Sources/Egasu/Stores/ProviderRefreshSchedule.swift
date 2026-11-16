import Foundation
import Observation

/// 대상별 다음 조회와 실패 대기 관리 — 타이머 조회는 정기 조회를 대체하지 않음.
@MainActor
@Observable
final class ProviderRefreshSchedule {
    nonisolated static let didChange = Notification.Name("UsageRefreshScheduleDidChange")
    static let failureRetryBackoff: TimeInterval = 60

    private let now: () -> Date
    private let monotonicNow: () -> TimeInterval
    private(set) var dates: [String: Date] = [:]
    @ObservationIgnored private var updatedAt: [String: TimeInterval] = [:]
    @ObservationIgnored private var retryAfter: [String: Date] = [:]
    @ObservationIgnored private var needsScheduledRefresh: Set<String> = []

    init(now: @escaping () -> Date, monotonicNow: @escaping () -> TimeInterval) {
        self.now = now
        self.monotonicNow = monotonicNow
    }

    func date(for providerID: String, usageRetryAfter: Date?) -> Date? {
        [dates[providerID], retryAfter[providerID], usageRetryAfter].compactMap { $0 }.max()
    }

    func requiresScheduledRefresh(_ providerID: String, trigger: RefreshTrigger) -> Bool {
        trigger == .scheduled && needsScheduledRefresh.contains(providerID)
    }

    func isBackedOff(_ providerID: String, force: Bool) -> Bool {
        !force && retryAfter[providerID].map { now() < $0 } == true
    }

    func reusedCache(_ snapshot: ProviderSnapshot, trigger: RefreshTrigger) {
        guard trigger == .scheduled else { return }
        dates[snapshot.providerID] = snapshot.freshnessDate.addingTimeInterval(
            RefreshSetting.interval(for: snapshot.providerID))
    }

    func attempted(_ providerID: String, trigger: RefreshTrigger) {
        guard trigger == .scheduled || dates[providerID] == nil else { return }
        updatedAt[providerID] = monotonicNow()
        dates[providerID] = now().addingTimeInterval(RefreshSetting.interval(for: providerID))
    }

    func failed(_ providerID: String) {
        retryAfter[providerID] = now().addingTimeInterval(Self.failureRetryBackoff)
    }

    func succeeded(_ snapshot: ProviderSnapshot, trigger: RefreshTrigger, unresolvedIdentity: Bool) {
        let providerID = snapshot.providerID
        retryAfter[providerID] = nil
        if trigger == .weeklyTimerCheck || trigger == .weeklyTimer { needsScheduledRefresh.insert(providerID) }
        else { needsScheduledRefresh.remove(providerID) }
        if unresolvedIdentity {
            let deadline = snapshot.freshnessDate.addingTimeInterval(RefreshSetting.interval(for: providerID))
            if (dates[providerID] ?? .distantPast) < deadline {
                dates[providerID] = deadline
                updatedAt[providerID] = monotonicNow()
            }
        }
    }

    func clear(_ providerID: String) {
        retryAfter[providerID] = nil
        dates[providerID] = nil
        updatedAt[providerID] = nil
    }

    /// 시계 변경 후 완료한 조회와 계정별 서버 대기는 유지.
    func rebase(providerIDs: [String], at date: Date, clockChangedAt: TimeInterval) {
        for id in providerIDs {
            if let updatedAt = updatedAt[id], updatedAt >= clockChangedAt { continue }
            dates[id] = date
            needsScheduledRefresh.insert(id)
            if let deadline = retryAfter[id] {
                retryAfter[id] = min(deadline, date.addingTimeInterval(Self.failureRetryBackoff))
            }
        }
    }

    func retain(liveIDs: Set<String>, discardedSnapshotIDs: Set<String>, keepsState: (String) -> Bool) {
        needsScheduledRefresh.formIntersection(liveIDs)
        retryAfter = retryAfter.filter { keepsState($0.key) }
        dates = dates.filter { keepsState($0.key) && !discardedSnapshotIDs.contains($0.key) }
        updatedAt = updatedAt.filter { keepsState($0.key) && !discardedSnapshotIDs.contains($0.key) }
    }
}
