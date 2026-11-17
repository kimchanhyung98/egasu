import SwiftUI

extension View {
    /// 첫 수신 전 자리 표시 — 회색 채움과 1.6초 빛 이동 효과, Reduce Motion에서는 정지.
    func skeleton() -> some View {
        foregroundStyle(Theme.skeleton).modifier(Shimmer())
    }
}

private struct Shimmer: ViewModifier {
    @Environment(\.reduceAnimations) private var reduceAnimations
    @State private var progress: CGFloat = 0

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceAnimations {
            content
        } else {
            content
                .mask {
                    GeometryReader { proxy in
                        // 행 폭의 3배 그라데이션 — 가운데 흐린 띠가 행 밖에서 시작하고 종료.
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.35),
                                .init(color: .black.opacity(0.4), location: 0.5),
                                .init(color: .black, location: 0.65)
                            ],
                            startPoint: .leading, endPoint: .trailing
                        )
                        .frame(width: proxy.size.width * 3, height: proxy.size.height)
                        .offset(x: proxy.size.width * (2 * progress - 2))
                    }
                }
                .task {
                    progress = 0
                    await Task.yield()
                    guard !Task.isCancelled else { return }
                    withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) { progress = 1 }
                }
        }
    }
}
