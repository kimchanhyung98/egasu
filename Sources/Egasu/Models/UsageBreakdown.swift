import Foundation

/// 사용 내역 Top Models가 보여 주는 수치 — 선택은 앱 전역으로 유지.
enum ModelFigure: String, CaseIterable, Hashable, Sendable {
    case cost
    case tokens

    static let key = "usageBreakdownModelFigure"

    var label: String {
        switch self {
        case .cost: L10n.metrics("Cost")
        case .tokens: L10n.metrics("Tokens")
        }
    }

    func text(_ number: Double) -> String {
        switch self {
        case .cost: MetricFormatter.number(number, kind: .dollars, style: .row)
        case .tokens: MetricFormatter.number(number, kind: .count, style: .row)
        }
    }
}

/// 기간 행 하나의 사용 내역 — 요약 수치와 모델별 목록(상위 5개 + Other).
struct UsageBreakdown: Equatable {
    struct Row: Equatable {
        let name: String
        /// nil이면 이 수치를 모름(가격 없는 모델의 비용) — "—"로 표시.
        let number: Double?
        var variants: [ModelUsageVariant] = []

        var variantTooltip: String? {
            guard !variants.isEmpty else { return nil }
            return variants.map { variant in
                let cost = variant.costUSD.map { MetricFormatter.number($0, kind: .dollars, style: .full) } ?? "—"
                let tokens = MetricFormatter.string(
                    for: MetricValue(number: Double(variant.totalTokens), kind: .count, label: "tokens"), style: .full
                )
                return "\(UsageBreakdown.displayName(variant.model)): \(cost) · \(tokens)"
            }.joined(separator: "\n")
        }
    }

    let title: String
    let breakdown: ModelUsageBreakdown

    static let topCount = 5

    /// 집계 기준일이 지난 상세·공유 제목 — 기준일 없는 이전 캐시는 원래 제목 유지.
    func displayTitle(at now: Date = Date()) -> String {
        guard let period = breakdown.period, !period.calendar.isDate(period.asOf, inSameDayAs: now) else {
            return title
        }
        let end =
            period.window == .yesterday
            ? period.calendar.startOfDay(for: period.asOf).addingTimeInterval(-1) : period.asOf
        let date = end.formatted(
            Date.FormatStyle(
                date: .abbreviated, time: .omitted, locale: L10n.locale,
                calendar: period.calendar, timeZone: period.calendar.timeZone
            ))
        return period.window == .last30 ? L10n.metrics("30 Days Ending %@", date) : date
    }

    /// 아무것도 보고되지 않은 기간 — 빈 상태로 그림.
    var isEmpty: Bool {
        breakdown.models.isEmpty && breakdown.totalTokens == 0 && (breakdown.totalCostUSD ?? 0) == 0
    }

    /// 요약 수치 — 비용(모든 모델 가격이 확정일 때만), 다음 토큰.
    var figures: [String] {
        var result: [String] = []
        if let cost = breakdown.totalCostUSD {
            result.append(ModelFigure.cost.text(cost))
        }
        if breakdown.totalTokens > 0 {
            result.append(
                MetricFormatter.string(
                    for: MetricValue(number: Double(breakdown.totalTokens), kind: .count, label: "tokens"),
                    style: .row
                ))
        }
        return result
    }

    /// 고를 수 있는 수치 — 가격 있는 모델이 하나라도 있어야 Cost.
    var modelFigures: [ModelFigure] {
        guard !breakdown.models.isEmpty else { return [] }
        return breakdown.models.contains { $0.costUSD != nil } ? [.cost, .tokens] : [.tokens]
    }

    /// 수치가 큰 순 상위 5개 + 나머지를 합친 Other — 가격 없는 모델은 Cost 보기에서 끝에 "—".
    /// 하나라도 가격이 없는 묶음의 비용은 합치지 않음(부분 비용을 합계로 보이지 않는 규칙).
    func rows(by figure: ModelFigure) -> [Row] {
        func value(_ model: ModelUsageEntry) -> Double? {
            figure == .cost ? model.costUSD : Double(model.totalTokens)
        }
        let named = breakdown.models.filter { $0.model != ModelUsageEntry.otherModelName }
        let sorted = named.enumerated().sorted { lhs, rhs in
            switch (value(lhs.element), value(rhs.element)) {
            case let (left?, right?): return left != right ? left > right : lhs.offset < rhs.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return lhs.offset < rhs.offset
            }
        }.map(\.element)
        var rows = sorted.prefix(Self.topCount).map {
            Row(name: Self.displayName($0.model), number: value($0), variants: $0.variants ?? [])
        }
        let rest =
            Array(sorted.dropFirst(Self.topCount))
            + breakdown.models.filter { $0.model == ModelUsageEntry.otherModelName }
        if !rest.isEmpty {
            let numbers = rest.map(value)
            let total = numbers.contains { $0 == nil } ? nil : numbers.compactMap { $0 }.reduce(0, +)
            let variants = rest.flatMap { model in
                if model.model == ModelUsageEntry.otherModelName { return model.variants ?? [] }
                return [ModelUsageVariant(model: model.model, totalTokens: model.totalTokens, costUSD: model.costUSD)]
            }
            rows.append(Row(name: L10n.metrics(ModelUsageEntry.otherModelName), number: total, variants: variants))
        }
        return rows
    }

    static func displayName(_ model: String) -> String {
        model == ModelUsageEntry.unattributedModelName || model == ModelUsageEntry.otherModelName
            ? L10n.metrics(model) : model
    }
}
