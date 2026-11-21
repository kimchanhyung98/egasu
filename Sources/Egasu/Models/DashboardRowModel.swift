import Foundation

/// All Usage 격자 행 한 줄의 표시 모델 — 라벨 · 막대 · 값 · 초기화, 또는 라벨 ··· 값.
struct DashboardRowModel: Equatable {
    enum Mark: Equatable {
        case bar(
            fill: Double, severity: WidgetData.MeterSeverity, value: String, reset: String?, isUsedUp: Bool = false)
        case value(String, detail: String? = nil, severity: WidgetData.MeterSeverity = .normal)
        /// Usage Trend 일별 막대 — 막대·값·초기화 열 전체 폭.
        case chart
    }

    let label: String
    let mark: Mark
    /// 시각 표기는 카운트다운보다 넓어 넓은 초기화 열 사용.
    var showsClockTimes = false
    /// 고른 속도라면 지금 도달했을 막대 위치 — 없으면 nil.
    var paceMark: Double?
    /// Soft Limit 위치 — 표시 방향(Used/Left)에 맞춘 0…1.
    var softLimitMark: Double?
    /// 카드형 한도 행의 전체 값·초기화 설명 — 한 줄 격자는 기존 축약 표기 유지.
    var cardValue: String?
    var cardReset: String?
    var limitSummary: String?

    /// 소진되어 그릴 막대가 없는 한도 — 행 50% 불투명.
    var isFaded: Bool {
        guard case .bar(let fill, _, _, _, let isUsedUp) = mark else { return false }
        return isUsedUp && fill == 0
    }
}

extension DashboardLine {
    func dashboardRow(now: Date = Date()) -> DashboardRowModel {
        var row = data.dashboardRow(now: now)
        guard ProviderAccountID.canonicalMetricID(id) == "codex.individualCredits",
            case .bar = row.mark, let limit = data.limit, limit > 0
        else { return row }

        let percent = MetricFormatter.utilization(data.displayedValue / limit)
        let usage = MetricFormatter.usageValue(percent, word: data.displayMode == .used ? "used" : "left")
        let count = MetricFormatter.number(limit, kind: .count, style: .full)
        let allowance = MetricFormatter.labelledValue(count, label: "credits")
        row.limitSummary = L10n.metrics("%@ · Limit %@", usage, allowance)
        return row
    }
}

extension WidgetData {
    func dashboardRow(now: Date = Date()) -> DashboardRowModel {
        let data = presented(at: now)
        let label = data.localizedTitle
        if data.isChart {
            return DashboardRowModel(label: label, mark: data.hasData ? .chart : .value(Self.noDataSubtitle))
        }
        guard data.hasData else {
            return DashboardRowModel(
                label: label, mark: .value(data.isForecast ? Self.noDataHeadline : Self.noDataSubtitle))
        }
        if data.isBounded, data.valueTextOverride == nil {
            return DashboardRowModel(
                label: label,
                mark: .bar(
                    fill: data.fraction,
                    severity: data.fillSeverity,
                    value: data.gridValueText,
                    reset: data.compactResetText(now: now),
                    isUsedUp: data.isSpent(at: now)
                ),
                showsClockTimes: data.resetDisplayMode == .absolute,
                paceMark: data.paceMark(now: now),
                softLimitMark: data.softLimitMarkerFraction,
                cardValue: data.headline,
                cardReset: data.boundedTrailingText(now: now)
            )
        }
        let figures = data.unboundedDetail.components(separatedBy: " · ")
        let detail = figures.count > 1 ? figures.dropFirst().joined(separator: " · ") : nil
        return DashboardRowModel(
            label: label,
            mark: .value(
                figures.first ?? Self.noDataHeadline, detail: detail, severity: data.expirySeverity(now: now) ?? .normal
            )
        )
    }

    /// 격자 값 열 표기 — 행 스타일 축약 숫자.
    var gridValueText: String {
        guard hasData else { return Self.noDataHeadline }
        if let valueTextOverride { return L10n.metrics(valueTextOverride) }
        return (valuePrefix ?? "") + MetricFormatter.number(displayedValue, kind: kind, style: .row)
    }

    /// Priority 행의 값. Used·Left를 바꿀 수 있는 지표에는 사용·잔여 단어 추가.
    var amountText: String {
        if !isBounded, !selectedValues.isEmpty { return valueText }
        return hasMeterStyleToggle
            ? MetricFormatter.usageValue(gridValueText, word: displayMode == .used ? "used" : "left") : gridValueText
    }

    /// 초기화 열의 짧은 표기 — 카운트다운("3h 5m") 또는 시각("토 02:59").
    func compactResetText(now: Date = Date()) -> String? {
        if let forecast {
            if forecast.refreshFailed { return L10n.metrics("Failed") }
            guard let deadline = forecast.deadline else { return nil }
            guard deadline.timeIntervalSince(now) > 0 else { return Formatters.imminent }
            return Self.resetReading(deadline, as: resetDisplayMode, now: now)
        }
        guard hasData, let resetsAt, !isFreshSessionWindow(now: now) else { return nil }
        guard resetsAt.timeIntervalSince(now) > 0 else { return Formatters.imminent }
        return Self.resetReading(resetsAt, as: resetDisplayMode, now: now)
    }

    private static func resetReading(_ date: Date, as mode: ResetDisplayMode, now: Date) -> String? {
        switch mode {
        case .relative: Formatters.countdown(to: date, now: now)
        case .absolute: Formatters.compactClock(date, now: now)
        }
    }

    /// Reset Watch 값의 호버 문구 — 투표율·예정·실패의 전체 설명.
    func forecastTooltip(now: Date = Date()) -> String? {
        guard isForecast else { return nil }
        let data = presented(at: now)
        let lines = [data.communityVoteLabel, data.boundedTrailingText(now: now)].compactMap { $0 }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    /// 소진 여부 — 남은 양이 표시 정밀도에서 0.
    func isSpent(at now: Date) -> Bool {
        if case .spent = meterState(now: now) { return true }
        return false
    }
}

/// 행 값에 포인터를 올리거나 클릭할 때 여는 상세 패널.
enum WidgetRowDetail: Equatable {
    /// 모델별 사용 내역.
    case breakdown
    /// 합계만 있고 모델 내역이 없음 — 읽은 시각과 사유.
    case saved
    /// 사용량을 아직 받지 못함 — 빈 상태.
    case empty
    /// Limit Resets 만료 타임라인.
    case resets
    /// Usage Trend 30일 상세.
    case trend
}

extension WidgetData {
    /// 값에서 여는 상세 — 없으면 nil(툴팁만).
    /// `reportsModels`는 모델 내역 지원 여부 — 미지원 행은 합계 패널 대신 툴팁 표시.
    func rowDetail(reportsModels: Bool) -> WidgetRowDetail? {
        if showsResetExpiries { return hasData ? .resets : nil }
        if isChart { return hasData && !chartPoints.isEmpty ? .trend : nil }
        guard isUsagePeriod else { return nil }
        if hasModelBreakdown { return .breakdown }
        if !hasData { return .empty }
        if isEmptyUsagePeriod { return nil }
        return reportsModels ? .saved : nil
    }
}
