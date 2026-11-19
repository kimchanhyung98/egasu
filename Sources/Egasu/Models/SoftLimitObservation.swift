import Foundation

enum SoftLimitQuotaState: Equatable, Sendable {
    case unknown
    case belowLimit
    case reached
}

/// 실측 한도 관측 — 같은 계정 안에서도 각 사용량 기간의 초기화 시각을 독립 적용.
struct SoftLimitObservation: Equatable, Sendable {
    private struct Reading: Equatable, Sendable {
        let usedFraction: Double
        let expiresAt: Date
    }

    let observedAt: Date
    private let readings: [Reading]
    private let hasInvalidReading: Bool

    func maximumUsedFraction(at now: Date) -> Double? {
        guard observedAt <= now else { return nil }
        return readings.lazy.filter { now < $0.expiresAt }.map(\.usedFraction).max()
    }

    func nextExpiry(after now: Date) -> Date? {
        readings.lazy.map(\.expiresAt).filter { $0 > now }.min()
    }

    /// 한 항목이라도 실측값이 기준에 도달하면 도달 확정. 미도달은 모든 대상 항목이 유효할 때만 확정.
    func quotaState(thresholdPercent: Int, at now: Date) -> SoftLimitQuotaState {
        guard let fraction = maximumUsedFraction(at: now) else { return .unknown }
        if fraction >= Double(thresholdPercent) / 100 { return .reached }
        let incomplete = hasInvalidReading || readings.contains { now >= $0.expiresAt }
        return incomplete ? .unknown : .belowLimit
    }

    /// 선택한 기간의 실측 한도만 추출. 각 값은 사용량 초기화와 다음 조회 기한 중 이른 시각에 만료.
    static func project(
        snapshot: ProviderSnapshot,
        descriptors: [WidgetDescriptor],
        window: SoftLimitWindowSelection,
        now: Date
    ) -> Self? {
        guard snapshot.errorCategory == nil, !snapshot.lines.contains(where: \.isError),
            (snapshot.usageRetryAfter ?? .distantPast) <= now,
            let observedAt = snapshot.liveQuotaObservedAt, observedAt <= now
        else { return nil }
        let deadline = observedAt.addingTimeInterval(RefreshSetting.interval(for: snapshot.providerID))
        guard now < deadline else { return nil }

        var readings: [Reading] = []
        var hasInvalidReading = snapshot.incompleteQuotaWindows?.contains(where: window.includes) == true
        for descriptor in descriptors where descriptor.providerID == snapshot.providerID {
            guard descriptor.softLimitWindows.contains(where: window.includes),
                descriptor.limitResources.contains(where: { $0.kind == .consumption && !$0.estimated }),
                let line = snapshot.line(label: descriptor.metricLabel),
                case let .progress(_, used, limit, _, resetsAt, duration, _) = line
            else { continue }
            guard descriptor.supportsSoftLimit(window, periodDurationMs: duration) else {
                if (duration ?? 0) <= 0 { hasInvalidReading = true }
                continue
            }
            guard used.isFinite, used >= 0, limit.isFinite, limit > 0, (used / limit).isFinite else {
                hasInvalidReading = true
                continue
            }
            readings.append(Reading(usedFraction: used / limit, expiresAt: min(resetsAt ?? deadline, deadline)))
        }
        guard readings.contains(where: { now < $0.expiresAt }) else { return nil }
        return Self(observedAt: observedAt, readings: readings, hasInvalidReading: hasInvalidReading)
    }
}
