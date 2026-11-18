import Foundation

/// 취소에 응답하지 않는 프로바이더도 호출자의 대기는 종료 — 실제 작업 종료와 결과 반영 분리.
@MainActor
enum ProviderRefreshDeadline {
    enum Result: Sendable {
        case snapshot(ProviderSnapshot)
        case timedOut
        case cancelled
    }

    /// 저장소의 경과 측정과 같은 SuspendingClock 기준 — 시스템 잠자기 동안 대기 시간 정지.
    /// ContinuousClock을 쓰면 잠자기에서 깨자마자 정상 조회가 시간 초과로 폐기됨.
    static func run(
        timeout: Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0, clock: .suspending)
        },
        operation: @escaping @MainActor () async -> ProviderSnapshot
    ) async -> Result {
        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: timeout)
        let race = Race()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.continuation = continuation
                guard !Task.isCancelled else {
                    race.finish(.cancelled)
                    return
                }
                race.work = Task {
                    guard !Task.isCancelled else {
                        race.finish(.cancelled)
                        return
                    }
                    let snapshot = await operation()
                    race.finish(clock.now >= deadline ? .timedOut : .snapshot(snapshot))
                }
                race.timer = Task {
                    // 프로바이더의 동기 실행 구간과 타이머 실행 대기도 최초 호출의 제한 시간에 포함.
                    let remaining = max(.zero, clock.now.duration(to: deadline))
                    do { try await sleep(remaining) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    race.finish(.timedOut)
                }
            }
        } onCancel: {
            Task { @MainActor in race.finish(.cancelled) }
        }
    }

    @MainActor
    private final class Race {
        var continuation: CheckedContinuation<Result, Never>?
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?

        func finish(_ result: Result) {
            guard let continuation else { return }
            self.continuation = nil
            work?.cancel()
            timer?.cancel()
            work = nil
            timer = nil
            continuation.resume(returning: result)
        }
    }
}
