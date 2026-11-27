import Darwin
import Foundation

/// 실행 인스턴스와 독립적으로 프로세스 그룹·출력 정리 완료까지 정상 종료 대기.
final class StreamingProcessOwner: @unchecked Sendable {
    static let shared = StreamingProcessOwner()

    private let lock = NSLock()
    private var isShuttingDown = false
    private var active: [UUID: ProcessTerminationController] = [:]
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var isIdle: Bool { lock.withLock { active.isEmpty } }

    func register(_ termination: ProcessTerminationController) throws -> UUID {
        try lock.withLock {
            guard !isShuttingDown else { throw CancellationError() }
            let id = UUID()
            active[id] = termination
            return id
        }
    }

    func unregister(_ id: UUID) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            active.removeValue(forKey: id)
            guard active.isEmpty else { return [] }
            let ready = waiters
            waiters.removeAll()
            return ready
        }
        for waiter in ready { waiter.resume() }
    }

    /// 종료 상태 전환과 실제 spawn을 직렬화. 호출부의 타이머 실행 권한은 그대로 유지.
    func withLaunchPermission(_ launch: () throws -> pid_t) throws -> pid_t {
        try lock.withLock {
            guard !isShuttingDown else { throw CancellationError() }
            return try launch()
        }
    }

    func beginShutdown() {
        lock.withLock { isShuttingDown = true }
    }

    func shutdown() async {
        let controllers = lock.withLock {
            isShuttingDown = true
            return Array(active.values)
        }
        for controller in controllers { controller.requestTermination() }
        await withCheckedContinuation { continuation in
            let alreadyIdle = lock.withLock {
                guard !active.isEmpty else { return true }
                waiters.append(continuation)
                return false
            }
            if alreadyIdle { continuation.resume() }
        }
    }
}
