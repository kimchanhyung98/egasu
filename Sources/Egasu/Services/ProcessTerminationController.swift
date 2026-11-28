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
        if Darwin.kill(-processGroupID, SIGKILL) != 0 {
            let code = errno
            Self.reportTerminationFailure(code, processGroupID: processGroupID)
        }
        self.processGroupID = nil
        completed = true
    }

    static func reportTerminationFailure(
        _ code: Int32,
        processGroupID: pid_t,
        readProcessGroup: (pid_t) -> [kinfo_proc]? = ProcessTerminationController.readProcessGroup
    ) {
        guard code != ESRCH else { return }
        if code == EPERM,
            let members = readProcessGroup(processGroupID),
            members.contains(where: { $0.kp_proc.p_pid == processGroupID }),
            members.allSatisfy({
                $0.kp_eproc.e_pgid == processGroupID && Int32($0.kp_proc.p_stat) == SZOMB
            })
        {
            AppLog.debug(.subprocess, "No live command process group members observed after cleanup")
        } else {
            AppLog.error(.subprocess, "Failed to terminate command process group (errno \(code))")
        }
    }

    /// 전체 조회에 성공한 구성원만 반환. 조회 중 그룹 변화가 가능하므로 종료 보장이 아닌 로그 판정에만 사용.
    private static func readProcessGroup(_ processGroupID: pid_t) -> [kinfo_proc]? {
        var name = [CTL_KERN, KERN_PROC, KERN_PROC_PGRP, processGroupID]
        var byteCount = 0
        guard sysctl(&name, UInt32(name.count), nil, &byteCount, nil, 0) == 0,
            byteCount > 0
        else { return nil }

        let stride = MemoryLayout<kinfo_proc>.stride
        let capacity = (byteCount + stride - 1) / stride
        var members = [kinfo_proc](repeating: kinfo_proc(), count: capacity)
        let allocatedBytes = capacity * stride
        byteCount = allocatedBytes
        let result = members.withUnsafeMutableBytes { buffer in
            sysctl(&name, UInt32(name.count), buffer.baseAddress, &byteCount, nil, 0)
        }
        guard result == 0, byteCount > 0, byteCount <= allocatedBytes,
            byteCount.isMultiple(of: stride)
        else { return nil }
        return Array(members.prefix(byteCount / stride))
    }
}
