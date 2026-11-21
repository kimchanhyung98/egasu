import SwiftUI
import os

/// SwiftUI 애니메이션에 패널 높이 동기화 — AppKit의 별도 setFrame 애니메이션과 경합 방지.
/// `animatableData` 설정자와 `effectValue`에서 높이 전달 — 0 이하의 높이는 생략.
/// GeometryEffect로 Animatable의 nonisolated 요구 준수 — ViewModifier의 body는 MainActor로 추론.
struct PanelHeightModifier: GeometryEffect {
    var height: CGFloat

    var animatableData: CGFloat {
        get { height }
        set {
            height = newValue
            PanelHeightBridge.push(newValue)
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        PanelHeightBridge.push(height)
        return ProjectionTransform()
    }
}

/// nonisolated Animatable 설정자에서 메인 액터 패널 연결부로 보간 높이 전달.
/// 메인 큐에 비동기 전달 — SwiftUI 갱신 중 동기 setFrame 호출로 인한 레이아웃 재귀 방지.
/// 연속 높이 변경은 최신 값으로 병합하여 지난 애니메이션 프레임 적용 방지.
enum PanelHeightBridge {
    private struct State {
        var generation = 0
        var pendingHeight: CGFloat?
        var isScheduled = false
    }

    /// 패널 열기·닫기마다 세대 증가 — 예약과 실행 시점의 세대가 다르면 지난 높이 폐기.
    /// push·invalidate의 동시 접근은 OSAllocatedUnfairLock으로 보호.
    private static let state = OSAllocatedUnfairLock(initialState: State())

    /// 예약된 모든 높이 무효화 — 패널 열기·닫기 시 호출 필수.
    nonisolated static func invalidate() {
        state.withLock {
            $0.generation += 1
            $0.pendingHeight = nil
            $0.isScheduled = false
        }
    }

    nonisolated static func push(_ height: CGFloat) {
        guard height > 0 else { return }
        let (scheduled, shouldSchedule) = state.withLock { state in
            state.pendingHeight = height
            let scheduled = state.generation
            guard !state.isScheduled else { return (scheduled, false) }
            state.isScheduled = true
            return (scheduled, true)
        }
        guard shouldSchedule else { return }
        DispatchQueue.main.async {
            let height = state.withLock { state -> CGFloat? in
                guard state.generation == scheduled else { return nil }
                let height = state.pendingHeight
                state.pendingHeight = nil
                state.isScheduled = false
                return height
            }
            guard let height else { return }
            MainActor.assumeIsolated {
                MenuBarPopover.applyHeight?(height)
            }
        }
    }
}

extension View {
    /// 메뉴 막대 패널 높이를 SwiftUI 애니메이션에 동기화.
    /// body 루트의 `.animation(nil, …)` 범위 밖에 부착 필수.
    func drivesPanelHeight(_ height: CGFloat) -> some View {
        modifier(PanelHeightModifier(height: height))
    }
}
