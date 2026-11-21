import Foundation

/// 지표가 속한 프로바이더의 표시·집계 메타데이터.
struct Provider: Identifiable, Hashable {
    let id: String
    let displayName: String
    let icon: IconSource
    /// 대시보드의 프로바이더별 상태·외부 페이지 바로가기.
    let links: [ProviderLink]
    let usesDedicatedSpendLines: Bool

    init(
        id: String, displayName: String, icon: IconSource,
        links: [ProviderLink] = [], usesDedicatedSpendLines: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.icon = icon
        self.links = links
        self.usesDedicatedSpendLines = usesDedicatedSpendLines
    }

    /// 표시 가능한 링크만 선택 — 공백 제거 후 라벨·URL이 비어 있지 않고 http(s) 방식일 때만 허용.
    var visibleLinks: [ProviderLink] {
        links.compactMap { link in
            let label = link.label.trimmingCharacters(in: .whitespacesAndNewlines)
            let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty,
                  !url.isEmpty,
                  url.hasPrefix("https://") || url.hasPrefix("http://") else { return nil }
            return ProviderLink(label: label, url: url)
        }
    }
}

/// 프로바이더의 외부 바로가기 — 라벨과 기본 브라우저에서 열 URL.
struct ProviderLink: Hashable {
    let label: String
    let url: String
}
