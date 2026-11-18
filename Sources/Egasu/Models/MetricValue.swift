import Foundation

/// 지표 행의 측정값 — 숫자 원본을 전달하고 표시 시점에만 MetricFormatter로 서식 적용.
/// 한 행에 금액·토큰 등 여러 값 허용 — ValueSelection으로 표시 대상 선택.
/// 매퍼가 한 번 생성한 자료로 비용 전용·토큰 전용·통합 표시 지원.
struct MetricValue: Hashable, Sendable, Codable {
    /// 원본 수치 — dollars는 USD, percent는 0...100, 나머지는 절대 개수.
    var number: Double
    /// 값별 출력 형식 — 금액·백분율·개수 중 선택.
    var kind: MetricKind
    /// 숫자 뒤 단위 명사 — nil이면 값 자체의 단위 생략.
    /// 위젯의 단일 금액 표시는 `WidgetData.unboundedValueWord`가 설정된 경우 해당 단어 우선.
    var label: String?
    /// 로컬 추정치 여부 — 같은 행에서도 비용은 추정, 토큰은 실측일 수 있어 값별 보관.
    var estimated: Bool

    init(number: Double, kind: MetricKind, label: String? = nil, estimated: Bool = false) {
        self.number = number
        self.kind = kind
        self.label = label
        self.estimated = estimated
    }
}

/// .values 행에서 표시할 값 선택 — 한 행으로 여러 지표 지원.
enum ValueSelection: Hashable, Sendable {
    /// 모든 값을 순서대로 통합 표시 — 예: "$4.08 · 1.2M tokens".
    case all
    /// 특정 유형의 값만 표시 — 비용은 dollars, 토큰은 count.
    case kind(MetricKind)

    func apply(to values: [MetricValue]) -> [MetricValue] {
        switch self {
        case .all:
            return values
        case .kind(let kind):
            return values.filter { $0.kind == kind }
        }
    }
}
