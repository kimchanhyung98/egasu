import AppKit
import SwiftUI

/// 패널의 스크롤 페이지 — `panelBars`가 위아래에 둔 바 밑으로 스크롤.
struct PopoverScrollView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.vertical) {
            content
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize)
    }
}

extension View {
    /// 스크롤 페이지 위아래 바 설정.
    /// 위쪽 바 아래는 내용 가림, 아래쪽 바 뒤는 흐림 — macOS 27 시스템 효과, 이전 버전은 별도 흐림 뷰 사용.
    /// 아래 바 밑에 내용이 없으면 아무것도 그리지 않음.
    /// 패널이 아직 페이지 높이에 맞지 않는 동안은 아래 바가 밑의 내용을 패널 색으로 가림.
    func panelBars(@ViewBuilder top: () -> some View, @ViewBuilder bottom: () -> some View) -> some View {
        modifier(PanelBars(top: top(), bottom: bottom()))
    }
}

private struct PanelBars<Top: View, Bottom: View>: ViewModifier {
    /// 아래 바를 완전히 흐리는 데 필요한 바 밑 내용 길이.
    private static var fullFrost: CGFloat { 12 }

    let top: Top
    let bottom: Bottom
    @State private var underBottom: CGFloat = 0
    /// 패널 높이가 이 페이지 높이와 다른지 — 탭 전환은 패널이 새 높이를 받기 한 프레임 전에 새 행을 그림.
    /// 그 프레임에 새 행이 아래 바(Next update)를 통해 비치지 않게 가림.
    @State private var isResizing = false

    func body(content: Content) -> some View {
        let barred = content
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                let below = geometry.contentSize.height + geometry.contentInsets.bottom
                    - geometry.containerSize.height - geometry.contentOffset.y
                return min(max(below / Self.fullFrost, 0), 1)
            } action: { _, under in
                underBottom = under
            }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                guard let clampHeight = MenuBarPopover.clampHeight else { return false }
                let ideal = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
                return abs(geometry.visibleRect.height - clampHeight(ideal)) > 1
            } action: { _, resizing in
                isResizing = resizing
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                top.background(Theme.panelBody)
            }
        let footer = bottom.background { if isResizing { Theme.panelBody } }
        if #available(macOS 27, *) {
            barred
                .safeAreaBar(edge: .bottom, spacing: 0) { footer }
                .scrollEdgeEffectStyle(.soft, for: .bottom)
                .scrollEdgeEffectHidden(true, for: underBottom > 0 ? .top : .vertical)
        } else {
            barred.safeAreaInset(edge: .bottom, spacing: 0) {
                footer.background {
                    FooterFrost(opacity: underBottom)
                        .padding(.top, -FooterFrost.reach)
                }
            }
        }
    }
}

/// macOS 27 이전의 하단 흐림 — 창 내부 콘텐츠에 흐림과 반투명 패널색 적용.
/// 패널 가장자리부터 바 위쪽 직전까지 가득 차고, 바 위로 조금 올라가며 사라짐.
private struct FooterFrost: NSViewRepresentable {
    /// 흐림 효과가 바 위쪽 콘텐츠까지 닿는 거리.
    static let reach: CGFloat = 10

    let opacity: CGFloat

    func makeNSView(context: Context) -> FrostView { FrostView() }

    func updateNSView(_ view: FrostView, context: Context) {
        view.alphaValue = opacity
    }

    final class FrostView: NSView {
        private let blur = NSVisualEffectView()
        private let wash = CALayer()
        private let fade = CAGradientLayer()

        init() {
            super.init(frame: .zero)
            blur.material = .menu
            blur.blendingMode = .withinWindow
            blur.state = .active
            addSubview(blur)
            wantsLayer = true
            wash.zPosition = 1
            layer?.addSublayer(wash)
            fade.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.clear.cgColor]
            fade.startPoint = CGPoint(x: 0.5, y: 0)
            fade.endPoint = CGPoint(x: 0.5, y: 1)
            layer?.mask = fade
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsLayout = true
        }

        override func layout() {
            super.layout()
            blur.frame = bounds
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fade.frame = bounds
            wash.frame = bounds
            effectiveAppearance.performAsCurrentDrawingAppearance {
                wash.backgroundColor = Theme.panelBodyNSColor.withAlphaComponent(0.5).cgColor
            }
            let fadeLength = FooterFrost.reach + 4
            fade.locations = [0, NSNumber(value: Double(max(bounds.height - fadeLength, 0) / max(bounds.height, 1))), 1]
            CATransaction.commit()
        }
    }
}
