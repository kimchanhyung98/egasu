import AppKit
import os

/// 갱신 순회 사이 대기 — 주기 만료, 활성 프로바이더·갱신 일정·시계 변경, 절전 해제 시 반환.
/// 첫 순회 전 동기 구독 — `.bufferingNewest(1)`로 대기자 없는 동안의 신호도 보존.
/// 연속 신호는 대기 중인 신호 하나로 병합하여 순회 중 변경도 다음 순회에 반영.
@MainActor
final class RefreshWakeSignal {
    private let stream: AsyncStream<Void>
    private let continuation: AsyncStream<Void>.Continuation
    private let center: NotificationCenter
    private let clockChanged = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)
    /// 비격리 `deinit`에서 관찰자를 해제할 수 있도록 불변 토큰을 `nonisolated(unsafe)`로 공유.
    private nonisolated(unsafe) let observer: NSObjectProtocol
    private nonisolated(unsafe) let scheduleObserver: NSObjectProtocol
    private nonisolated(unsafe) let wakeObserver: NSObjectProtocol
    private nonisolated(unsafe) let clockObserver: NSObjectProtocol

    init(
        name: Notification.Name = ProviderEnablementStore.didChangeNotification,
        center: NotificationCenter = .default
    ) {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        self.stream = stream
        self.continuation = continuation
        self.center = center
        // 동기 등록으로 초기화 직후 알림도 수신 — Sendable인 continuation은 모든 실행 문맥에서 전달 가능.
        self.observer = center.addObserver(forName: name, object: nil, queue: nil) { _ in
            continuation.yield()
        }
        self.scheduleObserver = center.addObserver(
            forName: WidgetDataStore.refreshScheduleDidChange, object: nil, queue: nil
        ) { _ in continuation.yield() }
        self.wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in continuation.yield() }
        let clockChanged = self.clockChanged
        self.clockObserver = center.addObserver(
            forName: .NSSystemClockDidChange, object: nil, queue: nil
        ) { _ in
            clockChanged.withLock { $0 = ProcessInfo.processInfo.systemUptime }
            continuation.yield()
        }
    }

    deinit {
        center.removeObserver(observer)
        center.removeObserver(scheduleObserver)
        center.removeObserver(clockObserver)
        NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        continuation.finish()
    }

    /// 일반 깨우기 신호와 병합되어도 마지막 시계 변경의 단조 시각은 다음 순회까지 보존.
    func consumeClockChange() -> TimeInterval? {
        clockChanged.withLock { changed in
            defer { changed = nil }
            return changed
        }
    }

    /// 보관된 신호·새 신호·시간 제한 중 먼저 도착하면 반환 — 작업 취소 시에도 즉시 반환.
    /// 신호와 시간 제한이 겹치면 남은 신호는 다음 대기에서 소비 가능. 소비자는 순차 갱신 루프 하나로 제한.
    func waitForWake(timeout: TimeInterval) async {
        let timer = Task { [continuation] in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            continuation.yield()
        }
        defer { timer.cancel() }
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}
