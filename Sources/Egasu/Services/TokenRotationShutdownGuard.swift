import Foundation

/// OAuth refresh 요청부터 새 토큰 저장까지의 구간과 앱 종료의 경계.
/// 서버는 요청을 받으면 이전 refresh token을 폐기하므로 저장 전 종료는 로그인 손실로 이어짐.
enum TokenRotationShutdownGuard {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var activeRotations = 0
    nonisolated(unsafe) private static var terminationPending = false
    nonisolated(unsafe) private static var idleWaiters: [CheckedContinuation<Void, Never>] = []

    /// 회전 시작 등록. 종료 대기 중이면 서버 토큰을 소비하기 전에 취소.
    static func begin() throws {
        try lock.withLock {
            guard !terminationPending else { throw CancellationError() }
            activeRotations += 1
        }
    }

    static func end() {
        let waiters: [CheckedContinuation<Void, Never>] = lock.withLock {
            activeRotations -= 1
            guard activeRotations == 0 else { return [] }
            let waiters = idleWaiters
            idleWaiters.removeAll()
            return waiters
        }
        for waiter in waiters { waiter.resume() }
    }

    static var isIdle: Bool {
        lock.withLock { activeRotations == 0 }
    }

    static func beginTermination() {
        lock.withLock { terminationPending = true }
    }

    /// 종료가 취소되면 회전 재개.
    static func cancelTermination() {
        lock.withLock { terminationPending = false }
    }

    /// 경고 시점이 지나도 마지막 회전이 끝날 때까지 종료 대기.
    static func waitForIdle(warnAfter delay: Duration, onDelay: @escaping @Sendable () -> Void) async {
        let warning = Task {
            do { try await Task.sleep(for: delay) } catch { return }
            if !isIdle { onDelay() }
        }
        defer { warning.cancel() }
        await withCheckedContinuation { continuation in
            lock.withLock {
                if activeRotations == 0 {
                    continuation.resume()
                } else {
                    idleWaiters.append(continuation)
                }
            }
        }
    }
}

/// SIGTERM을 앱의 정상 종료 경로로 전달.
enum TerminationSignalHandler {
    /// 무시(SIG_IGN) 대신 빈 처리기 사용 — 무시 상태는 `posix_spawn` 자식에게 상속되어 자식 정리용 SIGTERM이 무력화됨.
    static func install(onTerminate: @escaping @Sendable @MainActor () -> Void) -> DispatchSourceSignal {
        signal(SIGTERM) { _ in }
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler {
            // terminateLater의 중첩 실행 루프에서 메인 큐가 회전 저장과 종료 승인을 처리할 수 있도록 큐 콜백부터 반환.
            RunLoop.main.perform(inModes: [.common]) {
                MainActor.assumeIsolated { onTerminate() }
            }
        }
        source.resume()
        return source
    }
}
