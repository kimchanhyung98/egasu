import Foundation
import Observation

/// 메뉴 막대의 개인정보 보호 상태 — 저장된 설정과 현재 캡처 상태를 결합.
/// 상태 반영 후 StatusItemImageUpdater에 전달하여 캡처 중 메뉴 막대를 앱 아이콘으로 표시.
/// 설정을 켜면 주기적 조회와 윈도 서버 변경 알림으로 캡처 감시.
@MainActor
@Observable
final class MenuBarPrivacyStore {
    static let key = "hideUsageWhileScreenSharing"

    /// 변경 알림의 누락을 보완하는 캡처 상태 재확인 주기.
    static let pollInterval: Duration = .seconds(3)

    /// 기본 켜짐 설정 — SwiftUI·AppKit이 같은 저장값 사용.
    /// 설정을 끄면 주기적 조회 중지. 등록된 변경 알림은 수신하되 캡처 상태 조회 생략.
    var hideUsageWhileScreenSharing: Bool {
        didSet {
            guard hideUsageWhileScreenSharing != oldValue else { return }
            defaults.set(hideUsageWhileScreenSharing, forKey: Self.key)
            if hideUsageWhileScreenSharing {
                startMonitoring()
            } else {
                stopMonitoring()
            }
            publishConcealUsageChange()
        }
    }

    /// 현재 캡처 여부 — 설정이 꺼져 있으면 항상 false.
    private(set) var screenIsCaptured = false

    /// 메뉴 막대 사용량을 앱 아이콘으로 바꿀 조건.
    var concealUsage: Bool { hideUsageWhileScreenSharing && screenIsCaptured }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let probe: @MainActor () -> Bool
    @ObservationIgnored private let installChangeNotifications: @MainActor (@escaping @Sendable () -> Void) -> Void
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var concealUsageObserver: ((Bool) -> Void)?
    @ObservationIgnored private var lastPublishedConcealUsage: Bool?

    /// 기본값은 ScreenCaptureProbe의 윈도 서버 조회·알림 — 테스트에서 교체 가능.
    init(
        defaults: UserDefaults = .standard,
        probe: @escaping @MainActor () -> Bool = ScreenCaptureProbe.isScreenCaptured,
        installChangeNotifications: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void = ScreenCaptureProbe.installChangeNotifications
    ) {
        self.defaults = defaults
        self.probe = probe
        self.installChangeNotifications = installChangeNotifications
        self.hideUsageWhileScreenSharing = defaults.bool(forKey: Self.key, default: true)
        // 초기화 중 didSet이 실행되지 않으므로 저장값이 켜짐이면 직접 감시 시작.
        if hideUsageWhileScreenSharing {
            startMonitoring()
        }
    }

    deinit { pollTask?.cancel() }

    /// 메뉴 막대 이미지 갱신 콜백 하나 등록 — 사용량 숨김 상태가 반영된 순서대로 전달.
    func setConcealUsageObserver(_ observer: @escaping (Bool) -> Void) {
        concealUsageObserver = observer
        lastPublishedConcealUsage = concealUsage
    }

    /// 주기적 조회·감시 시작 시 캡처 상태 재확인 후 변경 전달.
    /// 현재 설정을 함께 확인하여 설정을 끈 뒤 도착한 이전 알림으로 다시 숨겨지지 않도록 처리.
    func refreshCaptureState() {
        applyCaptureState(hideUsageWhileScreenSharing && probe())
    }

    private func applyCaptureState(_ captured: Bool) {
        guard captured != screenIsCaptured else { return }
        screenIsCaptured = captured
        publishConcealUsageChange()
        AppLog.info(.menubar, captured
            ? "Screen capture detected; menu bar shows the wordmark"
            : "Screen capture ended; menu bar shows usage again")
    }

    private func startMonitoring() {
        guard pollTask == nil else { return }
        installChangeNotifications { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshCaptureState()
            }
        }
        refreshCaptureState()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard !Task.isCancelled else { return }
                self?.refreshCaptureState()
            }
        }
    }

    private func stopMonitoring() {
        pollTask?.cancel()
        pollTask = nil
        if screenIsCaptured {
            screenIsCaptured = false
        }
        publishConcealUsageChange()
    }

    private func publishConcealUsageChange() {
        guard let concealUsageObserver else { return }
        let current = concealUsage
        guard current != lastPublishedConcealUsage else { return }
        lastPublishedConcealUsage = current
        concealUsageObserver(current)
    }
}
