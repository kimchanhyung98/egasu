import Foundation

/// 사용 추세·모델별 내역 팝오버의 열림·닫힘 상태 관리.
/// 포인터가 머무르면 열고, 행·팝오버 양쪽을 벗어나면 유예 시간 후 닫기.
/// `@State` 보유와 `isPresented` 바인딩을 위한 `@Observable` 참조 타입.
@MainActor
@Observable
final class HoverPopoverState {
    var isPresented = false

    /// 살아 있는 모든 상태 객체 추적 — 패널 닫기 시 팝오버 일괄 정리.
    /// orderOut 뒤에도 뷰가 유지되므로 onDisappear 외에 직접 정리 필요.
    @ObservationIgnored private static let live = NSHashTable<HoverPopoverState>.weakObjects()

    static func dismissAll() {
        for state in live.allObjects { state.dismiss() }
    }

    /// 포인터가 행·값 위에 있는지 관찰하여 호버 표시 구동.
    /// dismiss에서 반드시 초기화하여 패널 재열기 시 이전 호버 상태 재사용 방지.
    private(set) var overInline = false
    @ObservationIgnored private var overDetail = false
    /// 초기화권 사용 확인·요청 중에는 포인터 위치와 무관하게 팝오버 유지.
    /// 직접 닫기는 고정보다 우선 — isPinned로 요청 중 데이터 변경에 따른 닫기 보류 가능.
    @ObservationIgnored private var pinned = false
    var isPinned: Bool { pinned }
    /// 클릭·Space로 연 상태 — 포인터 이탈로 닫지 않고 Limit Resets의 작업 버튼 표시.
    private(set) var openedExplicitly = false
    @ObservationIgnored private var showTask: Task<Void, Never>?
    @ObservationIgnored private var hideTask: Task<Void, Never>?
    @ObservationIgnored private var releasePinTask: Task<Void, Never>?

    /// 표시 지연 400ms, 닫힘 유예 180ms — 행에서 팝오버로 포인터를 옮길 시간 확보, 테스트에서 주입 가능.
    private let revealDelay: Duration
    private let hideGrace: Duration
    private let waitForPinRelease: @MainActor (Duration) async throws -> Void

    init(
        revealDelay: Duration = .milliseconds(400),
        hideGrace: Duration = .milliseconds(180),
        waitForPinRelease: @escaping @MainActor (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    ) {
        self.revealDelay = revealDelay
        self.hideGrace = hideGrace
        self.waitForPinRelease = waitForPinRelease
        Self.live.add(self)
    }

    func inlineHover(_ active: Bool) {
        // 연속 호버 이벤트 중 실제 상태가 바뀔 때만 갱신하여 중복 알림 방지.
        if overInline != active { overInline = active }
        active ? scheduleShow() : scheduleHide()
    }

    func detailHover(_ inside: Bool) {
        overDetail = inside
        if inside { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// 팝오버 고정·해제 — 고정 시 예약된 닫기 취소, 해제 시 포인터 이탈 유예 재시작.
    func setPinned(_ active: Bool) {
        releasePinTask?.cancel()
        releasePinTask = nil
        guard pinned != active else { return }
        pinned = active
        if active { hideTask?.cancel(); hideTask = nil } else { scheduleHide() }
    }

    /// 포인터가 떠난 상태에서도 초기화권 사용 결과를 읽을 시간 확보.
    @discardableResult
    func releasePin(after delay: Duration) -> Task<Void, Never>? {
        guard pinned else { return nil }
        releasePinTask?.cancel()
        releasePinTask = Task { [weak self, waitForPinRelease] in
            try? await waitForPinRelease(delay)
            guard let self, !Task.isCancelled else { return }
            releasePinTask = nil
            setPinned(false)
        }
        return releasePinTask
    }

    /// 클릭·Space로 즉시 열기 — 호버 대기와 포인터 이탈 닫기 생략.
    func openDetails() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        openedExplicitly = true
        isPresented = true
    }

    /// 상세를 표시할 수 없으면 팝오버의 이전 열림·고정 상태 폐기.
    func detailAvailabilityChanged(_ isAvailable: Bool) {
        if !isAvailable { dismiss() }
    }

    /// 팝오버·대시보드 종료 시 강제로 닫아 화면에 남는 표시 방지.
    func dismiss() {
        showTask?.cancel(); showTask = nil
        hideTask?.cancel(); hideTask = nil
        releasePinTask?.cancel()
        releasePinTask = nil
        overInline = false
        overDetail = false
        pinned = false
        openedExplicitly = false
        isPresented = false
    }

    private func scheduleShow() {
        hideTask?.cancel(); hideTask = nil
        guard !isPresented, showTask == nil else { return }
        let delay = revealDelay
        showTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if overInline { isPresented = true }
            showTask = nil
        }
    }

    private func scheduleHide() {
        guard !pinned, !openedExplicitly else { return }   // 고정·명시적 열기 동안 포인터 이탈 무시
        showTask?.cancel(); showTask = nil
        hideTask?.cancel()
        let delay = hideGrace
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled else { return }
            if !overInline, !overDetail, !pinned { isPresented = false }
            hideTask = nil
        }
    }
}
