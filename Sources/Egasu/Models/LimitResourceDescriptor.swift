import Foundation

/// /v1/limits로 공개하는 리소스의 안정적 메타데이터.
/// 정규화된 MetricLine에서 수치를 선택하는 방법 — 설명자가 없는 화면 전용 행은 API에서 제외.
struct LimitResourceDescriptor: Hashable, Sendable {
    enum Kind: String, Hashable, Sendable, Encodable {
        case consumption
        case balance
    }

    enum Source: Hashable, Sendable {
        case progress
        case value(kind: MetricKind, label: String? = nil)
        /// 같은 사용량을 한도 있는 진행률 또는 한도 없는 수치로 보고하는 프로바이더용.
        case progressOrValue(kind: MetricKind, label: String? = nil)
    }

    let key: String
    let kind: Kind
    let unit: String
    let source: Source
    var estimated = false
}

extension WidgetDescriptor {
    /// 지표·프로바이더 매퍼 변경 없이 단일 수치를 limits API에 추가.
    func exportingLimit(
        _ key: String,
        kind: LimitResourceDescriptor.Kind = .consumption,
        unit: String,
        source: LimitResourceDescriptor.Source = .progress,
        estimated: Bool = false
    ) -> WidgetDescriptor {
        var copy = self
        copy.limitResources.append(LimitResourceDescriptor(
            key: key,
            kind: kind,
            unit: unit,
            source: source,
            estimated: estimated
        ))
        return copy
    }
}
