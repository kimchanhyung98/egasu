import SwiftUI

extension EnvironmentValues {
    /// 공유 이미지 렌더 여부 — `ImageRenderer`는 AppKit 컨트롤을 못 그리므로 막대를 도형으로 그림.
    @Entry var drawsLevelsAsShapes = false
}

/// 한도 수준 막대 — macOS 기본 진행 막대 + 고른 속도 기준 위치 눈금.
struct LevelIndicator: View {
    let fill: Double
    let severity: WidgetData.MeterSeverity
    var paceMark: Double?
    /// Soft Limit 위치(0…1) — 속도 눈금(캡슐)과 구분되는 막대 높이 전체의 1pt 실선.
    var softLimitMark: Double?

    @Environment(\.drawsLevelsAsShapes) private var drawsAsShapes

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
    private static let shortestFill: CGFloat = 4

    var body: some View {
        level
            .overlay {
                if let softLimitMark {
                    Rectangle()
                        .fill(Theme.severityColor(.warning))
                        .frame(width: 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visualEffect { content, proxy in content.offset(x: proxy.size.width * softLimitMark - 0.5) }
                        .accessibilityHidden(true)
                }
            }
            .overlay {
                if let paceMark {
                    Capsule()
                        .fill(Theme.paceMark)
                        .frame(width: 2, height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visualEffect { content, proxy in content.offset(x: proxy.size.width * paceMark - 1) }
                        .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private var level: some View {
        if drawsAsShapes {
            shapes
        } else {
            ProgressView(value: min(max(fill, 0), 1))
                .progressViewStyle(.linear)
                .tint(Theme.severityColor(severity))
                .accessibilityHidden(true)
        }
    }

    private var shapes: some View {
        Self.shape
            .fill(Theme.meterTrack)
            .overlay(alignment: .leading) {
                if fill > 0 {
                    GeometryReader { proxy in
                        Self.shape
                            .fill(Theme.severityColor(severity))
                            .frame(width: max(Self.shortestFill, (proxy.size.width * min(fill, 1)).rounded()))
                    }
                }
            }
            .accessibilityHidden(true)
    }
}
