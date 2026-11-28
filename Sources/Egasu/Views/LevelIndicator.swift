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
    var isFaded = false
    /// Soft Limit 위치(0…1) — 실제 막대 가운데 표시하는 기준선.
    var softLimitMark: Double?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.drawsLevelsAsShapes) private var drawsAsShapes

    private static let shape = RoundedRectangle(cornerRadius: 2, style: .continuous)
    private static let shortestFill: CGFloat = 4

    var body: some View {
        level
            .overlay {
                if let paceMark {
                    Capsule()
                        .fill(Theme.paceMark)
                        .frame(width: 2, height: 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .visualEffect { content, proxy in
                            content.offset(
                                x: MeterMarkerGeometry.offset(
                                    track: proxy.size.width, fraction: paceMark, markerWidth: 2))
                        }
                        .accessibilityHidden(true)
                }
            }
            .opacity(isFaded ? 0.5 : 1)
            .overlay {
                if let softLimitMark {
                    GeometryReader { proxy in
                        Rectangle()
                            .fill(colorScheme == .dark ? Color.white : Color.black)
                            .frame(width: 1)
                            .offset(
                                x: MeterMarkerGeometry.offset(
                                    track: proxy.size.width, fraction: softLimitMark, markerWidth: 1))
                    }
                    .mask {
                        if drawsAsShapes {
                            Self.shape
                        } else {
                            // OS별 기본 막대의 실제 외곽으로 자름. 컨트롤의 배치 높이에는 여백도 포함.
                            nativeLevel(fill: 1)
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
    }

    @ViewBuilder
    private var level: some View {
        if drawsAsShapes {
            shapes
        } else {
            nativeLevel(fill: min(max(fill, 0), 1))
                .accessibilityHidden(true)
        }
    }

    private func nativeLevel(fill: Double) -> some View {
        ProgressView(value: fill)
            .progressViewStyle(.linear)
            .tint(Theme.severityColor(severity))
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

/// meter marker를 fraction 중심에 배치하되 track 양 끝을 넘지 않게 clamp.
enum MeterMarkerGeometry {
    static func offset(track: CGFloat, fraction: Double, markerWidth: CGFloat) -> CGFloat {
        let centered = track * fraction - markerWidth / 2
        return min(max(centered, 0), max(track - markerWidth, 0))
    }
}
