import SwiftUI
import os

struct PanelPageMeasurement: Equatable {
    let tab: DashboardTab
    let detail: String?
    let height: CGFloat

    init?(screen: PopoverScreen, tab: DashboardTab, detail: String?, hasFooter: Bool, geometry: ScrollGeometry) {
        // 계정 화면의 바가 배치되기 전 높이와 떠나는 푸터의 이전 여백 제외.
        if screen == .accounts {
            guard geometry.contentInsets.top > 0, hasFooter == (geometry.contentInsets.bottom > 0) else { return nil }
        }
        self.tab = tab
        self.detail = detail
        height = geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom
    }
}

/// 이미 그린 높이에서 새 목표까지 남은 전환 진행률로 보간.
struct PanelHeightPath: Equatable {
    var start: CGFloat = 0
    var end: CGFloat = 0
    var startProgress: CGFloat = 0

    func height(at progress: CGFloat) -> CGFloat {
        guard startProgress < 1 else { return end }
        let fraction = min(1, max(0, (progress - startProgress) / (1 - startProgress)))
        return start + (end - start) * fraction
    }
}

/// 창마다 마지막으로 그린 진행률·높이 보관 — 이전 전환의 지연 프레임 폐기.
final class PanelHeightPresentation: Sendable {
    struct Frame: Sendable {
        var motion = 0
        var progress: CGFloat = 1
        var height: CGFloat = 0
    }

    private let frame = OSAllocatedUnfairLock(initialState: Frame())

    var current: Frame { frame.withLock { $0 } }

    func restart() -> Frame {
        frame.withLock {
            PanelHeightBridge.invalidate()
            $0.motion += 1
            $0.progress = 0
            return $0
        }
    }

    func settle(at height: CGFloat) -> Int {
        let motion = restart().motion
        present(height, at: 1, motion: motion)
        return motion
    }

    func present(_ height: CGFloat, at progress: CGFloat, motion: Int) {
        frame.withLock {
            guard $0.motion == motion else { return }
            $0.height = height
            $0.progress = progress
            PanelHeightBridge.push(height)
        }
    }
}

/// 화면의 위치와 같은 진행률로 높이 전달 — 목표가 바뀌어도 새 애니메이션을 더하지 않음.
struct PanelHeightModifier: GeometryEffect {
    var path: PanelHeightPath
    var progress: CGFloat
    let motion: Int
    let presentation: PanelHeightPresentation

    var animatableData: CGFloat {
        get { progress }
        set {
            progress = newValue
            present()
        }
    }

    func effectValue(size: CGSize) -> ProjectionTransform {
        present()
        return ProjectionTransform()
    }

    private func present() {
        presentation.present(path.height(at: progress), at: progress, motion: motion)
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
