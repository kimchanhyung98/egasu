import Foundation

/// 로컬 추정용 달러 분모로 Go 사용량 미터 구성.
/// 현행 모델별 allowance·계정 사용량과 단위·집계 범위가 달라 크기 관계를 보장하지 않음.
enum OpenCodeUsageMapper {
    static let sessionCap: Double = 12   // rolling 5시간당
    static let weeklyCap: Double = 30    // UTC week당
    static let monthlyCap: Double = 60   // anchored month당

    static func meterLines(_ windows: OpenCodeGoWindows) -> [MetricLine] {
        [
            .progress(
                label: "Session", used: windows.sessionSpend, limit: sessionCap, format: .dollars,
                resetsAt: windows.sessionResetsAt, periodDurationMs: MetricPeriod.sessionMs
            ),
            .progress(
                label: "Weekly", used: windows.weeklySpend, limit: weeklyCap, format: .dollars,
                resetsAt: windows.weeklyResetsAt, periodDurationMs: MetricPeriod.weekMs
            ),
            .progress(
                label: "Monthly", used: windows.monthlySpend, limit: monthlyCap, format: .dollars,
                resetsAt: windows.monthlyResetsAt, periodDurationMs: windows.monthlyPeriodMs
            )
        ]
    }
}
