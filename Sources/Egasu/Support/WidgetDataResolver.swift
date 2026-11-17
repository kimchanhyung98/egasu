import Foundation

/// 정규화 지표와 별도 Reset Watch 값을 표시 데이터로 변환.
enum WidgetDataResolver {
    static func resolve(
        _ descriptor: WidgetDescriptor,
        snapshot: ProviderSnapshot?,
        codexResetWatch: CodexResetWatchResult
    ) -> WidgetData {
        var result: WidgetData
        if ProviderAccountID.canonicalMetricID(descriptor.id) == "codex.resetWatch" {
            if let watch = codexResetWatch.watch {
                result = WidgetData(
                    title: descriptor.sample.title,
                    icon: descriptor.sample.icon,
                    kind: .percent,
                    used: ProviderParse.clampPercent(watch.chancePercent),
                    limit: 100
                )
            } else {
                result = descriptor.sample
                result.hasData = codexResetWatch.isAbsent
            }
            result.forecast = .init(
                deadline: codexResetWatch.watch?.deadline,
                refreshFailed: codexResetWatch.refreshFailed,
                communityYesPercent: codexResetWatch.watch?.communityYesPercent,
                isScheduled: codexResetWatch.watch?.isScheduled ?? false
            )
        } else if let snapshot,
           let line = snapshot.line(label: descriptor.metricLabel),
           let data = resolve(line, descriptor: descriptor) {
            result = data
            if let message = snapshot.metricPresentations?[descriptor.metricLabel] {
                result.valueTextOverride = message.localized
            }
            result.codexResetClaimBinding = snapshot.codexResetClaimBinding
        } else {
            // 실제 지표 행이 없으면 데이터 없음 처리 — 표시 기본값의 숫자는 사용하지 않음.
            result = descriptor.sample
            result.hasData = false
        }

        return result
    }

    private static func resolve(_ line: MetricLine, descriptor: WidgetDescriptor) -> WidgetData? {
        switch line {
        case .progress(_, let used, let limit, let format, let resetsAt, let periodDurationMs, _):
            // 백분율은 표시 데이터 변환 시 0...100으로 제한.
            // 다른 유형은 원본 값을 유지하여 초과 사용도 소진 상태로 전달.
            let normalizedUsed = format == .percent ? ProviderParse.clampPercent(used) : used
            var result = WidgetData(
                title: descriptor.sample.title,
                icon: descriptor.sample.icon,
                kind: format.metricKind,
                used: normalizedUsed,
                limit: limit,
                countSuffix: format.countSuffix,
                valuePrefix: descriptor.sample.valuePrefix,
                resetsAt: resetsAt,
                periodDurationMs: periodDurationMs,
                limitNoun: descriptor.sample.limitNoun,
                infoNote: descriptor.sample.infoNote
            )
            // 기본 금액 행의 0 상한은 API 수치 유지, 화면은 금액·상한 문구 표시.
            if descriptor.sample.limit == nil, format == .dollars, limit == 0 {
                result.limit = nil
                result.valueTextOverride =
                    MetricFormatter.number(used, kind: .dollars, style: .row)
                    + " / " + MetricFormatter.number(limit, kind: .dollars, style: .row)
            }
            // progress 결과는 새로 생성하므로 프로바이더별 미시작 판정 신호 별도 전달.
            result.sessionStartSignal = descriptor.sample.sessionStartSignal
            return result
        case .text:
            // text는 로컬 API용 안내 — 숫자 행은 구조화된 값만 사용하며 표시 문자열 재해석 금지.
            return nil
        case .values(_, let values, _, let expiriesAt, let unknownModels, let modelBreakdown):
            // 표시 기본값은 sample, 실제 수치는 values에서 가져오며 문자열 재해석 생략.
            var data = descriptor.sample
            data.values = values
            // values는 상한 없는 행이므로 기본값에 limit이 있어도 제거.
            data.limit = nil
            // 크레딧 만료 시각 전달 — 툴팁은 주기적 재표시로 현재 남은 시간 반영.
            data.expiriesAt = expiriesAt
            // 가격 미확정 모델 메타데이터 보존 — 집계 제약은 카드 경고와 분리.
            data.unknownModels = unknownModels
            data.modelBreakdown = modelBreakdown
            // 선택한 값이 없으면 "No data" 표시 — 0으로 오인할 수 있는 값 생성 금지.
            data.hasData = !data.selectedValues.isEmpty
            // 선택한 값에 로컬 추정이 있으면 추정 안내 — 그 외에는 설명자의 기본 안내 사용.
            data.infoNote = data.selectedValues.contains(where: \.estimated)
                ? WidgetData.localEstimateNote
                : descriptor.sample.infoNote
            return data
        case .badge(_, let text, _, let subtitle):
            var data = descriptor.sample
            data.valueTextOverride = text
            data.subtitleOverride = subtitle
            return data
        case .chart(_, let points, let note):
            // 일별 값이 없으면 빈 차트 대신 "No data" 표시.
            var data = descriptor.sample
            data.isChart = true
            data.chartPoints = points
            data.chartNote = note
            data.hasData = !points.isEmpty
            return data
        }
    }

}
