import Foundation

/// quota pace-notification subsystem 소유 — metric별 dedup 상태, fire/deliver/commit 결정, debug trace
/// `WidgetDataStore`에서 분리된 독립 관심사 — delivery와 provider 표시명은 closure로 주입
/// metric·reset window 단위 dedup, no-data metric 미발화, 미전달 metric 상태는 prune되어 재등록 시 초기화
@MainActor
final class QuotaNotificationEvaluator {
    typealias Post = @MainActor (String, String, String, String, @MainActor () -> Bool) async -> Bool

    /// store가 이미 resolve한 이번 pass의 enabled·bounded·visible metric 하나
    struct Metric {
        let key: String
        let providerID: String
        let data: WidgetData
    }

    private var notificationState: [String: NotificationState] = [:]
    private var generationsByProvider: [String: Int] = [:]

    /// 계정이 교체·제거된 카드의 baseline만 제거, 대기 중인 이전 평가의 commit도 무효화.
    func reset(providerIDs: Set<String>) {
        guard !providerIDs.isEmpty else { return }
        for providerID in providerIDs {
            generationsByProvider[providerID, default: 0] &+= 1
        }
        notificationState = notificationState.filter { key, _ in
            !providerIDs.contains { key.hasPrefix($0 + ".") }
        }
        AppLog.info(.notifications, "notification baseline reset after account catalog change")
    }

    /// 전체 지표의 알림 조건 평가 후 켜진 조건만 전달 — 프로바이더 이름은 부제목에 사용.
    func evaluate(
        metrics: [Metric],
        isOn: @escaping (PaceMilestone) -> Bool,
        isProviderEnabled: @escaping (String) -> Bool = { _ in true },
        now: Date,
        providerName: @MainActor (String) -> String,
        post: Post
    ) async {
        let evaluationGenerations = generationsByProvider
        let activeKeys = Set(metrics.map(\.key))
        notificationState = notificationState.filter { activeKeys.contains($0.key) }
        metricLoop: for metric in metrics {
            let boundGeneration = evaluationGenerations[metric.providerID, default: 0]
            guard generationsByProvider[metric.providerID, default: 0] == boundGeneration else { continue }
            let key = metric.key
            let data = metric.data
            let state = data.meterState(now: now)
            let previous = notificationState[key] ?? NotificationState()
            let hasPaceContext = data.paceContext != nil
            let currentBucket = PaceNotificationLogic.bucket(for: state, used: data.used, hasPaceContext: hasPaceContext)
            let resetDelta = Self.resetDelta(current: data.resetsAt, previous: previous.resetsAt)
            let resetAdvanced = data.hasData && PaceNotificationLogic.resetWindowAdvanced(
                resetsAt: data.resetsAt,
                previousReset: previous.resetsAt,
                now: now,
                usageReset: data.used == 0 && (previous.previousUsed ?? 0) > 0
            )
            let result = PaceNotificationLogic.transitions(
                state: state,
                severity: data.severity,
                used: data.used,
                resetsAt: data.resetsAt,
                hasPaceContext: hasPaceContext,
                unusedNearReset: PaceNotificationLogic.isUnusedNearReset(data, now: now),
                previous: previous,
                now: now
            )
            if !result.fire.isEmpty || resetAdvanced || Self.isPositiveResetMovement(resetDelta) {
                AppLog.debug(.notifications, "decision \(key): metric=\(data.title) state=\(Self.notificationStateDescription(state)) bucket=\(Self.bucketDescription(currentBucket)) previousBucket=\(Self.bucketDescription(previous.previousBucket)) remaining=\(Self.percentDescription(data.remainingFraction)) reset=\(Self.dateDescription(data.resetsAt)) previousReset=\(Self.dateDescription(previous.resetsAt)) resetDelta=\(Self.resetDeltaDescription(resetDelta)) resetReason=\(Self.resetReasonDescription(delta: resetDelta, advanced: resetAdvanced)) primed=\(previous.primed) previousSeverity=\(Self.severityDescription(previous.previousSeverity)) severity=\(Self.severityDescription(data.severity)) firedBefore=\(Self.milestoneDescription(previous.firedMilestones)) fire=\(Self.milestoneDescription(result.fire)) newBucket=\(Self.bucketDescription(result.newState.previousBucket)) newFired=\(Self.milestoneDescription(result.newState.firedMilestones)) on=\(Self.milestoneDescription(PaceMilestone.allCases.filter(isOn)))")
            }
            // 중복 방지 기록은 실제로 보낸 것만 확정 — 꺼졌거나 못 보낸 알림은 상태를 되돌려 다음 평가에 다시 후보.
            var next = result.newState
            var paceDelivered = false
            var levelDelivered = false
            for milestone in result.fire {
                // 두 단계를 한 번에 지나면 켜진 것 중 더 낮은 단계 하나만 — 나머지는 보낸 것으로 침.
                if levelDelivered, milestone.isLevel {
                    next.firedMilestones.insert(milestone)
                    continue
                }
                let delivered = isOn(milestone) && isProviderEnabled(metric.providerID)
                    ? await deliver(milestone, data: data, providerID: metric.providerID,
                                    providerName: providerName, isCurrent: {
                                        self.generationsByProvider[metric.providerID, default: 0] == boundGeneration
                                            && isOn(milestone) && isProviderEnabled(metric.providerID)
                                    }, post: post)
                    : false
                guard generationsByProvider[metric.providerID, default: 0] == boundGeneration else {
                    continue metricLoop
                }
                if delivered {
                    if milestone.isPace { paceDelivered = true }
                    if milestone.isLevel { levelDelivered = true }
                    next.firedMilestones.insert(milestone)
                }
            }
            let held = PaceNotificationLogic.carriedOver(previous, used: data.used, resetsAt: data.resetsAt, now: now)
            if result.fire.contains(where: \.isPace) && !paceDelivered {
                next.previousBucket = held.previousBucket
            }
            if result.fire.contains(where: \.isLevel) && !levelDelivered {
                next.previousSeverity = held.previousSeverity
            }
            if !result.fire.isEmpty {
                AppLog.debug(.notifications, "commit \(key): paceDelivered=\(paceDelivered) levelDelivered=\(levelDelivered) persistedBucket=\(Self.bucketDescription(next.previousBucket)) persistedSeverity=\(Self.severityDescription(next.previousSeverity)) persistedFired=\(Self.milestoneDescription(next.firedMilestones))")
            }
            notificationState[key] = next
        }
    }

    /// milestone 알림 1건 조립·게시 — title은 trigger명, subtitle은 "Provider Metric", 전달 성공 여부 반환
    private func deliver(
        _ milestone: PaceMilestone,
        data: WidgetData,
        providerID: String,
        providerName: @MainActor (String) -> String,
        isCurrent: @escaping @MainActor () -> Bool,
        post: Post
    ) async -> Bool {
        let subtitle = L10n.metrics("%@ %@", providerName(providerID), data.localizedTitle)
        return await post("\(providerID).\(milestone.rawValue)", milestone.notificationTitle, subtitle, milestone.body(data.priorityLimits)) {
            isCurrent()
        }
    }

    // MARK: - Notification decision trace helpers (debug logging only)

    private static func resetDelta(current: Date?, previous: Date?) -> TimeInterval? {
        guard let current, let previous else { return nil }
        return current.timeIntervalSince(previous)
    }

    private static func isPositiveResetMovement(_ delta: TimeInterval?) -> Bool {
        guard let delta else { return false }
        return delta > 0
    }

    private static func resetReasonDescription(delta: TimeInterval?, advanced: Bool) -> String {
        guard let delta else { return "firstOrMissingReset" }
        if advanced { return "advanced" }
        if delta > PaceNotificationLogic.resetWindowJitterTolerance { return "extendedBeforeReset" }
        if delta > 0 { return "ignoredJitter" }
        if delta < 0 { return "movedEarlier" }
        return "unchanged"
    }

    private static func resetDeltaDescription(_ delta: TimeInterval?) -> String {
        guard let delta else { return "nil" }
        return String(format: "%.3fs", delta)
    }

    private static func dateDescription(_ date: Date?) -> String {
        date.map { EgasuISO8601.string(from: $0) } ?? "nil"
    }

    private static func percentDescription(_ value: Double) -> String {
        String(format: "%.1f%%", value * 100)
    }

    private static func severityDescription(_ severity: WidgetData.MeterSeverity) -> String {
        switch severity {
        case .neutral: return "neutral"
        case .normal: return "normal"
        case .warning: return "warning"
        case .critical: return "critical"
        }
    }

    private static func milestoneDescription(_ milestones: Set<PaceMilestone>) -> String {
        milestoneDescription(milestones.sorted { $0.rawValue < $1.rawValue })
    }

    private static func milestoneDescription(_ milestones: [PaceMilestone]) -> String {
        guard !milestones.isEmpty else { return "[]" }
        return "[" + milestones.map(\.rawValue).joined(separator: ",") + "]"
    }

    private static func bucketDescription(_ bucket: PaceBucket) -> String {
        switch bucket {
        case .untracked: return "untracked"
        case .healthy: return "healthy"
        case .close: return "close"
        case .runningOut: return "runningOut"
        }
    }

    private static func notificationStateDescription(_ state: WidgetData.MeterState) -> String {
        switch state {
        case .noData: return "noData"
        case .spent: return "spent"
        case .runningOut: return "runningOut"
        case .closeToLimit: return "closeToLimit"
        case .healthy: return "healthy"
        case .level(let severity):
            switch severity {
            case .neutral: return "level.neutral"
            case .normal: return "level.normal"
            case .warning: return "level.warning"
            case .critical: return "level.critical"
            }
        }
    }
}
