import Foundation

/// .progress 행 값의 표시 형식.
enum ProgressFormat: Hashable, Sendable, Codable {
    case percent
    case dollars
    case count(suffix: String)

    var metricKind: MetricKind {
        switch self {
        case .percent:
            return .percent
        case .dollars:
            return .dollars
        case .count:
            return .count
        }
    }

    var countSuffix: String? {
        if case .count(let suffix) = self { return suffix }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case suffix
    }

    private enum Kind: String, Codable {
        case percent
        case dollars
        case count
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .percent:
            self = .percent
        case .dollars:
            self = .dollars
        case .count:
            self = .count(suffix: try container.decode(String.self, forKey: .suffix))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .percent:
            try container.encode(Kind.percent, forKey: .kind)
        case .dollars:
            try container.encode(Kind.dollars, forKey: .kind)
        case .count(let suffix):
            try container.encode(Kind.count, forKey: .kind)
            try container.encode(suffix, forKey: .suffix)
        }
    }
}

/// .chart 행의 하루치 데이터 — 출력 문자열과 재표시할 원본 날짜·수량.
/// date는 이전 캐시와 호환되는 선택 필드 — 로컬 HTTP API에서는 제외.
struct MetricChartPoint: Hashable, Sendable, Codable {
    var value: Double
    var label: String
    var valueLabel: String?
    var date: Date? = nil

    var localizedLabel: String {
        date.map { Formatters.monthDayLabel($0) } ?? label
    }

    var localizedReadout: String {
        MetricFormatter.labelledValue(MetricFormatter.number(value, kind: .count, style: .row), label: "tokens")
    }
}

enum MetricLine: Hashable, Sendable, Codable {
    case text(label: String, value: String, colorHex: String? = nil, subtitle: String? = nil)
    /// Usage Trend의 일별 막대 자료 — 원본 일별 값과 안내 문구를 전달하고 뷰에서 서식 적용.
    /// 상한이 없으며 Priority 고정 불가.
    case chart(label: String, points: [MetricChartPoint], note: String? = nil)
    /// 원본 MetricValue를 담는 상한 없는 행 — 표시 시점에 값 선택과 서식 적용.
    /// `expiriesAt`은 현재 시각에 맞춰 만료를 표시하도록 `Date`로 유지. `unknownModels`는 가격 미확정 모델 목록.
    /// modelBreakdown은 앱 내부 표시 자료 — 로컬 HTTP API 응답에서는 제외.
    case values(
        label: String,
        values: [MetricValue],
        colorHex: String? = nil,
        expiriesAt: [Date] = [],
        unknownModels: [String] = [],
        modelBreakdown: ModelUsageBreakdown? = nil
    )
    case progress(
        label: String,
        used: Double,
        limit: Double,
        format: ProgressFormat,
        resetsAt: Date? = nil,
        periodDurationMs: Int? = nil,
        colorHex: String? = nil
    )
    case badge(label: String, text: String, colorHex: String? = nil, subtitle: String? = nil)

    var label: String {
        switch self {
        case .text(let label, _, _, _),
             .progress(let label, _, _, _, _, _, _),
             .values(let label, _, _, _, _, _),
             .badge(let label, _, _, _),
             .chart(let label, _, _):
            return label
        }
    }

    /// ProviderSnapshot.error가 생성하는 오류 배지 라벨.
    /// 생성과 isError 판정이 같은 상수 사용 — 오류가 일반 상태로 표시되거나 캐시되는 상황 방지.
    static let errorBadgeLabel = "Error"

    var isError: Bool {
        if case .badge(let label, _, _, _) = self {
            return label == Self.errorBadgeLabel
        }
        return false
    }

    /// 프로바이더가 지표를 반환하지 않았을 때의 공통 데이터 없음 배지.
    static let noUsageData = MetricLine.badge(label: "Status", text: "No usage data", colorHex: "#A3A3A3")

    /// 빈 결과에는 noUsageData를 추가하여 명시적 상태 표시.
    static func appendNoDataIfNeeded(_ lines: inout [MetricLine]) {
        if lines.isEmpty {
            lines.append(.noUsageData)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case label
        case value
        case values
        case used
        case limit
        case format
        case resetsAt
        case expiriesAt
        case unknownModels
        case modelBreakdown
        case periodDurationMs
        case colorHex
        case subtitle
        case text
        case points
        case note
    }

    private enum LineType: String, Codable {
        case text
        case values
        case progress
        case badge
        case chart
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let label = try container.decode(String.self, forKey: .label)
        switch try container.decode(LineType.self, forKey: .type) {
        case .text:
            self = .text(
                label: label,
                value: try container.decode(String.self, forKey: .value),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case .values:
            self = .values(
                label: label,
                values: try container.decode([MetricValue].self, forKey: .values),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                expiriesAt: try container.decodeIfPresent([Date].self, forKey: .expiriesAt) ?? [],
                unknownModels: try container.decodeIfPresent([String].self, forKey: .unknownModels) ?? [],
                modelBreakdown: try container.decodeIfPresent(ModelUsageBreakdown.self, forKey: .modelBreakdown)
            )
        case .progress:
            self = .progress(
                label: label,
                used: try container.decode(Double.self, forKey: .used),
                limit: try container.decode(Double.self, forKey: .limit),
                format: try container.decode(ProgressFormat.self, forKey: .format),
                resetsAt: try container.decodeIfPresent(Date.self, forKey: .resetsAt),
                periodDurationMs: try container.decodeIfPresent(Int.self, forKey: .periodDurationMs),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex)
            )
        case .badge:
            self = .badge(
                label: label,
                text: try container.decode(String.self, forKey: .text),
                colorHex: try container.decodeIfPresent(String.self, forKey: .colorHex),
                subtitle: try container.decodeIfPresent(String.self, forKey: .subtitle)
            )
        case .chart:
            self = .chart(
                label: label,
                points: try container.decode([MetricChartPoint].self, forKey: .points),
                note: try container.decodeIfPresent(String.self, forKey: .note)
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let label, let value, let colorHex, let subtitle):
            try container.encode(LineType.text, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(value, forKey: .value)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        case .values(let label, let values, let colorHex, let expiriesAt, let unknownModels, let modelBreakdown):
            try container.encode(LineType.values, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(values, forKey: .values)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            if !expiriesAt.isEmpty { try container.encode(expiriesAt, forKey: .expiriesAt) }
            if !unknownModels.isEmpty { try container.encode(unknownModels, forKey: .unknownModels) }
            try container.encodeIfPresent(modelBreakdown, forKey: .modelBreakdown)
        case .progress(let label, let used, let limit, let format, let resetsAt, let periodDurationMs, let colorHex):
            try container.encode(LineType.progress, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(used, forKey: .used)
            try container.encode(limit, forKey: .limit)
            try container.encode(format, forKey: .format)
            try container.encodeIfPresent(resetsAt, forKey: .resetsAt)
            try container.encodeIfPresent(periodDurationMs, forKey: .periodDurationMs)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
        case .badge(let label, let text, let colorHex, let subtitle):
            try container.encode(LineType.badge, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(text, forKey: .text)
            try container.encodeIfPresent(colorHex, forKey: .colorHex)
            try container.encodeIfPresent(subtitle, forKey: .subtitle)
        case .chart(let label, let points, let note):
            try container.encode(LineType.chart, forKey: .type)
            try container.encode(label, forKey: .label)
            try container.encode(points, forKey: .points)
            try container.encodeIfPresent(note, forKey: .note)
        }
    }
}
