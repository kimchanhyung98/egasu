import Foundation

/// 지표 숫자의 표시 형식.
/// String 기반 Codable — 캐시된 MetricLine의 MetricValue에 저장되는 형식 계약.
enum MetricKind: String, Hashable, Sendable, Codable {
    case percent      // used 범위 0...100
    case dollars      // used는 USD 금액
    case count        // used는 절대 count (suffix 선택)
}
