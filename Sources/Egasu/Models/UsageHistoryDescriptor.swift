import Foundation

/// 프로바이더 일별 지출 이력의 Mac 간 합산 가능 여부.
/// 공용 지출 지표를 제공하는 프로바이더는 집계 범위를 명시해야 함. 계정 전체 사용량의 중복 합산 방지.
struct UsageHistoryDescriptor: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable, Codable {
        case machineLocal
        case accountWide
    }

    let scope: Scope
    let estimatedCost: Bool
    let sourceNote: String
}

extension WidgetDescriptor {
    /// 프로바이더의 정규화된 일별 이력을 외부 출력 리소스와 함께 분류.
    func exportingHistory(
        scope: UsageHistoryDescriptor.Scope,
        estimatedCost: Bool,
        sourceNote: String
    ) -> WidgetDescriptor {
        var copy = self
        copy.historyResource = UsageHistoryDescriptor(
            scope: scope,
            estimatedCost: estimatedCost,
            sourceNote: sourceNote
        )
        return copy
    }
}
