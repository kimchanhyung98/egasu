import Foundation

/// 대시보드에 배치된 지표 하나.
/// 안정적 id는 순서 변경·애니메이션의 식별자 — descriptorID는 등록된 데이터와 표시 유형에 연결.
struct PlacedWidget: Identifiable, Hashable, Codable {
    var id: UUID
    let descriptorID: String

    init(id: UUID = UUID(), descriptorID: String) {
        self.id = id
        self.descriptorID = descriptorID
    }
}
