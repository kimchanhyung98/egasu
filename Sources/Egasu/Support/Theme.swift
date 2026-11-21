import SwiftUI
import AppKit

/// 중앙 팔레트 + surface 스타일 — surface는 light/dark 적응형 유지.
/// Liquid Glass는 footer/top-bar chrome 전용, 데이터 카드에는 금지 — 콘텐츠 레이어는 표준 material로 받치는 Apple 가이드 준수.
/// 데이터 영역은 macOS System Settings의 grouped look(`.fill.quaternary`)을 따르고 수동 튜닝 값 없음.
enum Theme {
    static let iconGray = AnyShapeStyle(.secondary)

    /// 경고 단계의 막대 색 — 시스템 팔레트로 밝기·접근성 설정 반영.
    static func meterFill(_ severity: WidgetData.MeterSeverity) -> AnyShapeStyle {
        AnyShapeStyle(severityColor(severity))
    }

    static func severityTextColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .neutral, .normal: severityColor(severity)
        case .warning: adaptive(light: NSColor(red: 0.7, green: 0.37, blue: 0, alpha: 1), dark: .systemOrange)
        case .critical: adaptive(light: NSColor(red: 0.84, green: 0, blue: 0.08, alpha: 1), dark: .systemRed)
        }
    }

    static let notice = AnyShapeStyle(severityColor(.warning))

    static let positive = AnyShapeStyle(Color(nsColor: .systemGreen))

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 6
        static let m: CGFloat = 8
        static let l: CGFloat = 10
        static let xl: CGFloat = 12
        static let xxl: CGFloat = 14
    }

    static let panelBodyNSColor: NSColor = .windowBackgroundColor
    static let panelBody = Color(nsColor: panelBodyNSColor)
    static let hairline = adaptive(light: NSColor(white: 0, alpha: 0.05), dark: NSColor(white: 1, alpha: 0.06))
    static let controlFill = adaptive(light: NSColor(white: 0, alpha: 0.06), dark: NSColor(white: 1, alpha: 0.1))
    static let segmentThumb = adaptive(light: .white, dark: NSColor(white: 1, alpha: 0.18))
    static let meterTrack = adaptive(light: NSColor(white: 0, alpha: 0.09), dark: NSColor(white: 1, alpha: 0.12))
    static let paceMark = Color.primary.opacity(0.55)
    static let skeleton = adaptive(light: NSColor(white: 0, alpha: 0.075), dark: NSColor(white: 1, alpha: 0.086))

    static func severityColor(_ severity: WidgetData.MeterSeverity) -> Color {
        switch severity {
        case .neutral: Color(nsColor: .systemGray)
        case .normal: Color(nsColor: .systemBlue)
        case .warning: Color(nsColor: .systemOrange)
        case .critical: Color(nsColor: .systemRed)
        }
    }

    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    // MARK: - Surfaces

    /// grouped card 뒤 popover의 불투명 backdrop("tray") — 문서 view가 쓰는 밝은 page surface인 `textBackgroundColor`.
    /// `NSColor`로 노출해 AppKit backdrop(`StatusItemController`)과 SwiftUI surface가 한 색을 공유.
    static let trayNSColor: NSColor = .textBackgroundColor
    static var traySurface: Color { Color(nsColor: trayNSColor) }

    /// 카드의 시스템 채움 — 밝기·대비 설정에 맞춰 변경.
    static let cardFill = Color(nsColor: .quaternarySystemFill)

    static let cardCornerRadius: CGFloat = 12

    static var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cardCornerRadius, style: .continuous)
    }
}

extension View {
    /// 카드 표면 — 시스템 채움과 얇은 구분선.
    func cardSurface() -> some View {
        modifier(CardSurfaceModifier())
    }

    /// 단일 행 lifted preview surface — 카드 surface + 아래 행들과 구분하는 얇은 separator hairline.
    /// 여러 행 provider preview는 hairline 없이 그림자만으로 분리감 표현.
    func liftedRowSurface() -> some View {
        cardSurface()
            .background(Theme.panelBody, in: Theme.cardShape)
            .overlay { Theme.cardShape.strokeBorder(.separator, lineWidth: 0.5) }
    }

    /// settings·Customize 행 토글이 공유하는 trailing 스위치 스타일 — inline 라벨 없음, native switch, small 크기.
    func settingsSwitchStyle() -> some View {
        labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
    }
    func inlineGroupedForm() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, -16)
    }

}

private struct CardSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            Theme.cardShape
                .fill(Theme.cardFill)
                .overlay { Theme.cardShape.strokeBorder(Theme.hairline, lineWidth: 0.5) }
        }
    }
}
