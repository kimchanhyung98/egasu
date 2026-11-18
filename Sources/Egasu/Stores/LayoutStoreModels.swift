/// 프로바이더와 표시 지표 묶음 — 저장 순서대로 대시보드 목록 구성.
struct ProviderGroup: Identifiable {
    let provider: Provider
    let widgets: [PlacedWidget]
    var id: String { provider.id }
}

/// 프로바이더와 전체 지원 지표 묶음 — 표시 여부와 무관하게 저장 순서 유지.
struct ProviderMetrics: Identifiable {
    let provider: Provider
    let metrics: [WidgetDescriptor]
    var id: String { provider.id }
}

/// 프로바이더별 활성 상태와 지표 수 — 순서 계산과 계정 묶음 이동 단위.
struct ProviderRow: Identifiable {
    let provider: Provider
    let isEnabled: Bool
    let metricCount: Int
    var id: String { provider.id }
}
