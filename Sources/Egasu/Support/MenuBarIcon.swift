import AppKit
import SwiftUI

/// menu bar용 template `NSImage`로 egasu 브랜드 gauge mark 렌더링.
/// provider 타일과 같은 SVG→`ProviderIconShape` 파이프라인 재사용 — asset catalog나 두 번째 SVG parser 불필요.
@MainActor
enum MenuBarIcon {
    /// menu bar glyph 한 변 길이(points).
    private static let side: CGFloat = 18

    /// 캐시된 template 이미지 — 브랜드 mark 로드/파싱 실패 시 `nil`.
    static let image: NSImage? = render()

    private static func render() -> NSImage? {
        guard let mark = ProviderMarks.mark(for: "egasu") else { return nil }
        let renderer = ImageRenderer(
            // 원본 viewBox의 안쪽 여백을 고려해 기존 메뉴 막대 기호 크기를 유지.
            content: ProviderIconShape(pathData: mark.path, inset: 0.08)
                .fill(Color.black)
                .frame(width: side, height: side)
        )
        renderer.scale = 2
        guard let nsImage = renderer.nsImage else { return nil }
        nsImage.size = NSSize(width: side, height: side)
        nsImage.isTemplate = true
        return nsImage
    }
}
