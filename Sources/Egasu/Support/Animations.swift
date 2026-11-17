import SwiftUI

/// 모든 전환이 일관되게 느껴지도록 하는 공통 motion 어휘.
enum Motion {
    static let spring = Animation.spring(response: 0.42, dampingFraction: 0.80)
    static let modeSwitch = Animation.easeInOut(duration: 0.18)
    static let navigation = Animation.easeInOut(duration: 0.25)

    static func applyReduction(to transaction: inout Transaction, enabled: Bool) {
        guard enabled else { return }
        transaction.animation = nil
        transaction.disablesAnimations = true
    }
}

private struct ReduceAnimationsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// 시스템 동작 줄이기 상태 — 로딩 효과·팝오버·진행 표시의 분기 기준.
    var reduceAnimations: Bool {
        get { self[ReduceAnimationsKey.self] }
        set { self[ReduceAnimationsKey.self] = newValue }
    }
}

extension View {
    /// 하위 뷰에 시스템 동작 줄이기 정책 적용 — 패널 루트에 한 번 연결.
    func reduceAnimationsWhenRequested() -> some View {
        modifier(ReduceAnimationsModifier())
    }

    func animationReduction(_ enabled: Bool) -> some View {
        modifier(AnimationReductionModifier(enabled: enabled))
    }
}

private struct ReduceAnimationsModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    func body(content: Content) -> some View {
        content.animationReduction(systemReduceMotion)
    }
}

private struct AnimationReductionModifier: ViewModifier {
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .environment(\.reduceAnimations, enabled)
            .transaction { transaction in
                Motion.applyReduction(to: &transaction, enabled: enabled)
            }
    }
}

/// 동작 줄이기에서 회전 대신 정적 아이콘을 표시하는 진행 상태.
struct MotionAwareProgressView: View {
    var controlSize: ControlSize = .small

    @Environment(\.reduceAnimations) private var reduceAnimations

    @ViewBuilder
    var body: some View {
        if reduceAnimations {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: controlSize == .mini ? 8 : 10, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: controlSize == .mini ? 10 : 12, height: controlSize == .mini ? 10 : 12)
        } else {
            ProgressView()
                .controlSize(controlSize)
        }
    }
}

extension View {
    /// macOS "denied" 관용구의 가로 shake — `trigger` 증가마다 1회 재생.
    /// `shakeOnAppear`는 거부 시 새로 삽입되는 라벨 전용(첫 bump를 `onChange`가 못 봄);
    /// 상시 라벨에 켜면 mount할 때마다 이전 shake가 재생됨.
    func denyShake(trigger: Int, shakeOnAppear: Bool = false) -> some View {
        modifier(DenyShakeModifier(trigger: trigger, shakeOnAppear: shakeOnAppear))
    }
}

/// animatable phase(0→1에 `shakes`회 진동)로 구동되는 가로 sine shake.
private struct DenyShakeEffect: GeometryEffect {
    var phase: CGFloat
    var travel: CGFloat = 5
    var shakes: CGFloat = 3

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(
            translationX: travel * sin(phase * .pi * shakes * 2),
            y: 0
        ))
    }
}

private struct DenyShakeModifier: ViewModifier {
    let trigger: Int
    let shakeOnAppear: Bool
    @State private var phase: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .modifier(DenyShakeEffect(phase: phase))
            .onChange(of: trigger) { shake() }
            .onAppear {
                if shakeOnAppear, trigger > 0 { shake() }
            }
    }

    private func shake() {
        // 연속 trigger마다 온전한 shake가 재생되도록 0부터 재시작.
        phase = 0
        withAnimation(.linear(duration: 0.4)) {
            phase = 1
        }
    }
}
