import Darwin
import Foundation

final class ProcessTerminationController: @unchecked Sendable {
    private let lock = NSLock()
    private let forceCleanup: @Sendable () -> Void
    private var processGroupID: pid_t?
    private var terminationRequested = false
    private var completed = false

    init(forceCleanup: @escaping @Sendable () -> Void) {
        self.forceCleanup = forceCleanup
    }

    func prepareToLaunch() throws {
        lock.lock()
        defer { lock.unlock() }
        if terminationRequested {
            throw CancellationError()
        }
    }

    func didLaunch(processGroupID: pid_t) {
        lock.lock()
        self.processGroupID = processGroupID
        let shouldTerminate = terminationRequested
        if shouldTerminate { terminateLocked() }
        lock.unlock()
        if shouldTerminate { forceCleanup() }
    }

    func requestTermination() {
        lock.lock()
        terminationRequested = true
        let shouldCleanUp = completed || processGroupID != nil
        terminateLocked()
        lock.unlock()
        if shouldCleanUp { forceCleanup() }
    }

    func didCompleteNaturally() {
        requestTermination()
    }

    /// wait 실패 시 소유권을 입증할 수 없는 숫자 PID에 추가 signal 금지.
    func relinquishProcessGroup() {
        lock.lock()
        completed = true
        processGroupID = nil
        lock.unlock()
        forceCleanup()
    }

    /// 리더 프로세스 회수 전에 잠금 안에서 종료 신호 전송과 그룹 ID 해제를 처리. 동시 취소가 재사용된 ID로 신호를 보내는 상황 방지.
    private func terminateLocked() {
        guard !completed, let processGroupID else { return }
        if Darwin.kill(-processGroupID, SIGKILL) != 0, errno != ESRCH {
            AppLog.error(.subprocess, "Failed to terminate command process group (errno \(errno))")
        }
        self.processGroupID = nil
        completed = true
    }
}
