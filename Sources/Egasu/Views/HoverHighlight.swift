import SwiftUI

extension View {
    /// 상호작용 텍스트의 호버 강조 — 글자 위치를 유지하고 quaternary 배경만 서서히 표시.
    func hoverHighlight(_ isLit: Bool) -> some View {
        background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(.quaternary)
                .padding(.horizontal, -6)
                .padding(.vertical, -2)
                .opacity(isLit ? 1 : 0)
        }
        .animation(.easeOut(duration: 0.12), value: isLit)
    }
}
