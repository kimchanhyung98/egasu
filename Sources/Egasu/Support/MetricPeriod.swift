import Foundation

/// 프로바이더가 공유하는 표준 사용량 기간 — 밀리초 단위.
/// 같은 사용량 기간에는 프로바이더별 매퍼에서 이 상수 재사용.
enum MetricPeriod {
    static let sessionMs = 5 * 60 * 60 * 1000
    static let dayMs = 24 * 60 * 60 * 1000
    static let weekMs = 7 * dayMs
    static let monthMs = 30 * dayMs
}
