import Observation
import ServiceManagement

/// Launch at Login 설정을 macOS 상태와 동기화.
/// 변경 실패로 원래 값으로 돌아갈 때 추가 사용자 요청으로 처리하지 않음.
@MainActor
@Observable
final class LaunchAtLoginSetting {
    static var failureMessage: String {
        L10n.errors("macOS wouldn't update Launch at Login. Check System Settings → Login Items.")
    }

    private(set) var isEnabled = false
    private(set) var errorMessage: String?
    private var failedRequestedValue: Bool?

    private let currentStatus: () -> Bool
    private let setSystemEnabled: (Bool) throws -> Void

    init(
        currentStatus: @escaping () -> Bool = { SMAppService.mainApp.status == .enabled },
        setEnabled: @escaping (Bool) throws -> Void = { enabled in
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        }
    ) {
        self.currentStatus = currentStatus
        self.setSystemEnabled = setEnabled
    }

    /// 시스템 설정에서 바꾼 상태 반영 — Settings에 들어올 때마다.
    func refreshStatus() {
        isEnabled = currentStatus()
        if failedRequestedValue == isEnabled {
            errorMessage = nil
            failedRequestedValue = nil
        }
    }

    func update(to enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            try setSystemEnabled(enabled)
            isEnabled = currentStatus()
            errorMessage = nil
            failedRequestedValue = nil
        } catch {
            AppLog.error(
                .config,
                "Launch at Login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)"
            )
            isEnabled = currentStatus()
            errorMessage = Self.failureMessage
            failedRequestedValue = enabled
        }
    }
}
