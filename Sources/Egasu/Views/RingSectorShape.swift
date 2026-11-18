import SwiftUI

/// 시작·끝 비율을 animatableData로 보간하는 도넛 조각.
/// 프로바이더별 조각의 색상은 호출부에서 유지하고 각도만 보간.
/// 비율은 12시부터 시계 방향으로 0...1.
struct RingSectorShape: Shape {
    var startFraction: Double
    var endFraction: Double
    /// 지름 대비 구멍 비율 (황금비 도넛).
    var innerRadiusRatio: CGFloat = 0.618
    /// 인접 섹터 간 간격의 외곽 림 기준 호 길이 (pt).
    var gapWidth: CGFloat = 1.6
    var cornerRadius: CGFloat = 3

    var animatableData: AnimatablePair<Double, Double> {
        get { AnimatablePair(startFraction, endFraction) }
        set {
            startFraction = newValue.first
            endFraction = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        let outer = Double(min(rect.width, rect.height) / 2)
        let inner = outer * Double(innerRadiusRatio)
        let center = CGPoint(x: rect.midX, y: rect.midY)

        // 화면 y축은 아래로 증가하므로 각도 증가 방향은 시계 방향.
        let top = -Double.pi / 2
        let halfGap = Double(gapWidth) / outer / 2
        let a0 = top + startFraction * 2 * .pi + halfGap
        let a1 = top + endFraction * 2 * .pi - halfGap
        let width = a1 - a0
        guard width > 0.001 else { return Path() }

        // 모서리 반지름을 띠 두께·조각 각도로 제한하여 인접 모서리 호의 교차 방지.
        let s = sin(min(width / 2, .pi / 2))
        var corner = min(Double(cornerRadius), (outer - inner) / 2)
        corner = min(corner, outer * s / (1 + s))
        if s < 1 {
            corner = min(corner, inner * s / (1 - s))
        }

        if corner < 0.25 {
            return plainWedge(center: center, inner: inner, outer: outer, a0: a0, a1: a1)
        }
        return roundedWedge(center: center, inner: inner, outer: outer, a0: a0, a1: a1, corner: corner)
    }

    /// 매우 얇거나 애니메이션 중 압축된 조각의 모서리 없는 도형.
    private func plainWedge(center: CGPoint, inner: Double, outer: Double, a0: Double, a1: Double) -> Path {
        var path = Path()
        path.addArc(center: center, radius: outer, startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(a1), endAngle: .radians(a0), clockwise: true)
        path.closeSubpath()
        return path
    }

    /// 바깥·안쪽 호, 접선 모서리 호 4개와 방사형 변 2개로 구성한 둥근 조각.
    private func roundedWedge(center: CGPoint, inner: Double, outer: Double, a0: Double, a1: Double, corner: Double) -> Path {
        // 모서리 원이 둘레와 변에 동시에 접하도록 중심 각도 조정.
        let betaOuter = asin(min(1, corner / (outer - corner)))
        let betaInner = asin(min(1, corner / (inner + corner)))

        func polar(_ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
        }
        func around(_ point: CGPoint, _ radius: Double, _ angle: Double) -> CGPoint {
            CGPoint(x: point.x + radius * cos(angle), y: point.y + radius * sin(angle))
        }

        var path = Path()
        // 외곽 림, 시계방향
        path.addArc(
            center: center, radius: outer,
            startAngle: .radians(a0 + betaOuter), endAngle: .radians(a1 - betaOuter), clockwise: false
        )
        // 바깥 모서리에서 끝쪽 변으로 진입.
        let trailingOuter = polar(outer - corner, a1 - betaOuter)
        path.addArc(
            center: trailingOuter, radius: corner,
            startAngle: .radians(a1 - betaOuter), endAngle: .radians(a1 + .pi / 2), clockwise: false
        )
        // 끝쪽 방사형 변을 따라 안쪽으로 이동.
        let trailingInner = polar(inner + corner, a1 - betaInner)
        path.addLine(to: around(trailingInner, corner, a1 + .pi / 2))
        // 끝쪽 변의 안쪽 모서리.
        path.addArc(
            center: trailingInner, radius: corner,
            startAngle: .radians(a1 + .pi / 2), endAngle: .radians(a1 - betaInner + .pi), clockwise: false
        )
        // 안쪽 둘레를 따라 시작쪽 변까지 반시계 방향으로 이동.
        path.addArc(
            center: center, radius: inner,
            startAngle: .radians(a1 - betaInner), endAngle: .radians(a0 + betaInner), clockwise: true
        )
        // 시작쪽 변의 안쪽 모서리.
        let leadingInner = polar(inner + corner, a0 + betaInner)
        path.addArc(
            center: leadingInner, radius: corner,
            startAngle: .radians(a0 + betaInner + .pi), endAngle: .radians(a0 + 3 * .pi / 2), clockwise: false
        )
        // 시작쪽 방사형 변을 따라 바깥으로 이동.
        let leadingOuter = polar(outer - corner, a0 + betaOuter)
        path.addLine(to: around(leadingOuter, corner, a0 - .pi / 2))
        // 바깥 모서리에서 둘레로 복귀.
        path.addArc(
            center: leadingOuter, radius: corner,
            startAngle: .radians(a0 + 3 * .pi / 2), endAngle: .radians(a0 + betaOuter), clockwise: false
        )
        path.closeSubpath()
        return path
    }
}
