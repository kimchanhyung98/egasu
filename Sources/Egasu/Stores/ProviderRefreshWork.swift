import Foundation
import Observation

/// 조회 호출과 실제 작업의 수명 분리 — 시간 초과 뒤에도 큐와 계정 전환 대기 유지.
@MainActor
@Observable
final class ProviderRefreshWork {
    struct Lease {
        fileprivate let providerID: String
        fileprivate let runtimeID: ObjectIdentifier
    }

    private let queue: BackgroundWorkQueue
    private let timeout: TimeInterval
    private(set) var refreshingProviderIDs: Set<String> = []
    private var waitingProviderIDs: Set<String> = []
    @ObservationIgnored private var pending: [ObjectIdentifier: String] = [:]
    @ObservationIgnored private var waiters: [
        (providerIDs: Set<String>, continuation: CheckedContinuation<Void, Never>)
    ] = []

    init(queue: BackgroundWorkQueue, timeout: TimeInterval) {
        self.queue = queue
        self.timeout = timeout
    }

    func isPending(_ provider: ProviderRuntime) -> Bool {
        pending[ObjectIdentifier(provider)] != nil
    }

    func isWaiting(_ providerID: String) -> Bool { waitingProviderIDs.contains(providerID) }

    func begin(_ provider: ProviderRuntime) -> Lease? {
        let providerID = provider.provider.id
        guard !isPending(provider), !refreshingProviderIDs.contains(providerID) else { return nil }
        refreshingProviderIDs.insert(providerID)
        waitingProviderIDs.insert(providerID)
        return Lease(providerID: providerID, runtimeID: ObjectIdentifier(provider))
    }

    /// 호출자가 결과를 반영한 뒤 해제. 실제 작업이 남았으면 계정 대기는 계속 유지.
    func finish(_ lease: Lease, wakeSchedule: Bool) {
        refreshingProviderIDs.remove(lease.providerID)
        waitingProviderIDs.remove(lease.providerID)
        if wakeSchedule, pending[lease.runtimeID] == nil { wake() }
        resumeIdleWaiters()
    }

    /// 큐 대기 뒤 실행 직전에 현재 카탈로그·인증 연결을 확인.
    func run(
        _ lease: Lease, provider: ProviderRuntime, trigger: RefreshTrigger,
        isCurrent: @escaping @MainActor () -> Bool = { true },
        prepare: @MainActor () -> Bool
    ) async -> ProviderRefreshDeadline.Result? {
        guard let ticket = await queue.acquire("usage:\(ProviderAccountID.family(of: lease.providerID))") else {
            return nil
        }
        waitingProviderIDs.remove(lease.providerID)
        var workOwnsTicket = false
        defer { if !workOwnsTicket { queue.finish(ticket) } }
        guard !Task.isCancelled, isCurrent(), prepare() else { return nil }
        return await ProviderRefreshDeadline.run(timeout: .seconds(timeout), isCurrent: isCurrent) { [self, queue] in
            workOwnsTicket = true
            defer { queue.finish(ticket) }
            pending[lease.runtimeID] = lease.providerID
            defer {
                pending.removeValue(forKey: lease.runtimeID)
                if !refreshingProviderIDs.contains(lease.providerID) { wake() }
                resumeIdleWaiters()
            }
            return await ProviderRefreshContext.$isManual.withValue(trigger == .manual) {
                await ProviderRefreshContext.$isResetClaim.withValue(trigger == .resetClaim) {
                    await provider.refresh()
                }
            }
        }
    }

    /// 호출자 취소와 무관하게 해당 계정의 실제 작업·결과 반영 종료까지 대기.
    func waitUntilIdle(providerIDs: Set<String>) async {
        while hasWork(providerIDs) {
            await withCheckedContinuation { waiters.append((providerIDs, $0)) }
        }
    }

    private func hasWork(_ providerIDs: Set<String>) -> Bool {
        !refreshingProviderIDs.isDisjoint(with: providerIDs)
            || pending.values.contains { providerIDs.contains($0) }
    }

    private func resumeIdleWaiters() {
        let current = waiters
        waiters.removeAll()
        for waiter in current {
            if hasWork(waiter.providerIDs) { waiters.append(waiter) }
            else { waiter.continuation.resume() }
        }
    }

    private func wake() {
        NotificationCenter.default.post(name: ProviderRefreshSchedule.didChange, object: nil)
    }
}
