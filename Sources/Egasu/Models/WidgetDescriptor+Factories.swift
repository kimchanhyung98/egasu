import Foundation

/// 표시 기본값인 WidgetData를 조립하는 공용 생성 함수.
/// 데이터 조회 전 기본 사용량은 0. 실제 표시 여부와 값은 조회 결과에서 결정.
extension WidgetDescriptor {
    /// 세션·주간 한도용 0–100% 계기.
    /// sessionStartSignal은 프로바이더별 "Not started" 판정 신호.
    static func percent(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        sessionStartSignal: WidgetData.SessionStartSignal? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100)
        sample.sessionStartSignal = sessionStartSignal
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// 공개 초기화 예측용 0–100% 계기 — Used/Left·속도·한도 알림 미적용.
    static func forecast(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        var sample = WidgetData(title: title, icon: provider.icon, kind: .percent, used: 0, limit: 100)
        sample.forecast = WidgetData.Forecast()
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// 보조 문구가 "$<limit> <limitNoun>"인 금액 한도 계기 — 명사 기본값은 "limit".
    /// valueWord는 상한 없는 .values 행의 값 뒤 단어 — 상한 있는 행에서는 미사용.
    static func boundedDollars(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        limitNoun: String? = nil,
        valueWord: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: limit, limitNoun: limitNoun,
                                unboundedValueWord: valueWord))
    }

    /// 개수 한도 계기 — periodDurationMs가 있으면 보조 문구에 초기화 주기 표시.
    static func boundedCount(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        limit: Double,
        suffix: String,
        periodDurationMs: Int? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: limit, countSuffix: suffix,
                                periodDurationMs: periodDurationMs))
    }

    /// 프로바이더의 .values에 기반한 상한 없는 숫자 행.
    /// selection은 표시할 값, valueWord는 단일 금액 뒤 단어 — 추정치 표시는 데이터에서 결정.
    static func values(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        selection: ValueSelection = .all,
        valueWord: String? = nil,
        isUsagePeriod: Bool = false,
        traySuffix: String? = nil,
        showsResetExpiries: Bool = false
    ) -> WidgetDescriptor {
        // 선택된 값은 각각의 `kind`로 표시. 선택된 값 없이 숫자를 표시할 때는 이 기본 유형으로 형식과 단위 결정.
        let kind: MetricKind = { if case .kind(let only) = selection { return only }; return .dollars }()
        var sample = WidgetData(title: title, icon: provider.icon, kind: kind, used: 0, limit: nil,
                                unboundedValueWord: valueWord)
        sample.selection = selection
        sample.isUsagePeriod = isUsagePeriod
        sample.traySuffix = traySuffix
        sample.showsResetExpiries = showsResetExpiries
        return make(id: id, provider: provider, metricLabel: metricLabel ?? title, sample: sample)
    }

    /// .values의 모든 값을 이어 붙인 통합 지표 — 예: "$4.08 · 1.2M tokens".
    static func combined(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        isUsagePeriod: Bool = false
    ) -> WidgetDescriptor {
        values(id: id, provider: provider, title: title, metricLabel: metricLabel, selection: .all,
               isUsagePeriod: isUsagePeriod)
    }

    /// SpendTileMapper 기반 공통 기간별 지출 지표 — Today·Yesterday·Last 30 Days.
    /// 이 생성 함수는 `<provider>.today`, `<provider>.yesterday`, `<provider>.last30`을 사용.
    static func spendTiles(provider: Provider, valueTooltipNote: String? = nil) -> [WidgetDescriptor] {
        let descriptors: [WidgetDescriptor] = [
            .combined(id: "\(provider.id).today", provider: provider, title: "Today", isUsagePeriod: true),
            .combined(id: "\(provider.id).yesterday", provider: provider, title: "Yesterday", isUsagePeriod: true),
            .combined(id: "\(provider.id).last30", provider: provider, title: "Last 30 Days", isUsagePeriod: true)
        ]
        // 공통 기간 지출 지표로 분류. Total Spend는 스냅샷에서 비용·토큰 중 하나의 합계가 양수인 기간 행을 집계.
        // 전용 합계를 쓰는 프로바이더는 `totalSpendLines`의 기간 행 사용.
        return descriptors.map { descriptor in
            var sample = descriptor.sample
            sample.valueTooltipNote = valueTooltipNote
            return WidgetDescriptor(
                id: descriptor.id,
                providerID: descriptor.providerID,
                metricLabel: descriptor.metricLabel,
                sample: sample,
                pinnable: descriptor.pinnable,
                isSpendTile: true,
                limitResources: descriptor.limitResources,
                historyResource: descriptor.historyResource
            )
        }
    }

    /// 값 뒤 단어를 지정하는 상한 없는 금액 잔액 — 예: "$1,503.00 left".
    static func dollarBalance(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil,
        valueWord: String
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .dollars, used: 0, limit: nil, unboundedValueWord: valueWord))
    }

    /// 프로바이더의 .badge를 valueTextOverride로 표시하는 상한 없는 행 — 예: Grok pay-as-you-go.
    static func badge(
        id: String,
        provider: Provider,
        title: String,
        metricLabel: String? = nil
    ) -> WidgetDescriptor {
        make(id: id, provider: provider, metricLabel: metricLabel ?? title,
             sample: WidgetData(title: title, icon: provider.icon,
                                kind: .count, used: 0, limit: nil))
    }

    /// `.chart` 행의 일별 토큰 추이를 표시하는 지표 — Priority 고정 대상에서 제외.
    static func usageTrend(provider: Provider) -> WidgetDescriptor {
        var sample = WidgetData(title: "Usage Trend", icon: provider.icon, kind: .count, used: 0, limit: nil)
        sample.isChart = true
        return make(id: "\(provider.id).trend", provider: provider, metricLabel: "Usage Trend",
                    sample: sample, pinnable: false)
    }

    private static func make(
        id: String,
        provider: Provider,
        metricLabel: String,
        sample: WidgetData,
        pinnable: Bool = true
    ) -> WidgetDescriptor {
        WidgetDescriptor(
            id: id,
            providerID: provider.id,
            metricLabel: metricLabel,
            sample: sample,
            pinnable: pinnable
        )
    }
}
