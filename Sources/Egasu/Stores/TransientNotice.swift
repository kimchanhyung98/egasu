import Observation

/// 일정 시간 후 사라지는 공용 화면 안내 상태.
/// present(_:)는 trigger도 증가시켜 같은 값을 다시 표시해도 등장 효과 재생.
/// 팝오버가 닫힐 때 clear()로 초기화하여 다음 열기에서 이전 안내가 다시 나타나지 않도록 처리.
@MainActor
@Observable
final class TransientNotice<Value> {
    private(set) var value: Value
    /// 표시마다 증가하는 뷰 식별값 — .id(trigger)에서 전환 효과 재실행.
    private(set) var trigger = 0

    // let은 관찰 대상이 아니므로 가변 작업에만 ObservationIgnored 적용.
    private let clearedValue: Value
    private let timeout: Duration
    @ObservationIgnored private var clearTask: Task<Void, Never>?

    init(clearedValue: Value, timeout: Duration) {
        self.value = clearedValue
        self.clearedValue = clearedValue
        self.timeout = timeout
    }

    func present(_ newValue: Value) {
        value = newValue
        trigger += 1
        clearTask?.cancel()
        let timeout = self.timeout
        clearTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard let self, !Task.isCancelled else { return }
            value = clearedValue
        }
    }

    func clear() {
        value = clearedValue
        clearTask?.cancel()
        clearTask = nil
    }
}
