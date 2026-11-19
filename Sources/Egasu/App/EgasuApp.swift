import AppKit

@MainActor
public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var container: AppContainer?
    private var statusItemController: StatusItemController?
    private var singleInstanceLock: SingleInstanceLock.Token?
    private var isAwaitingProcessShutdown = false
    private let updater = UpdaterController()

    public override init() {
        super.init()
    }

    /// SwiftUI·AppKit 초기화 전에 앱 표시 언어 적용.
    public static func configureLanguageForLaunch() {
        LanguageSetting.configureLaunch()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // 다른 로그보다 먼저 bootstrap — 세션 첫 라인 캡처.
        AppLog.bootstrap()
        // 커널 수준 single-instance lock (#874) — workspace guard snapshot이 놓치는 근접 동시 런치도 차단.
        var holdsLock = false
        if let bundleID = Bundle.main.bundleIdentifier {
            switch SingleInstanceLock.acquire(bundleIdentifier: bundleID) {
            case .acquired(let token):
                singleInstanceLock = token
                holdsLock = true
            case .alreadyRunning:
                SingleInstanceGuard.activateExistingInstance()
                AppLog.info(.lifecycle, "duplicate launch detected by process lock; terminating")
                NSApp.terminate(nil)
                return
            case .failed(let message):
                AppLog.error(.lifecycle, "single-instance lock unavailable: \(message)")
            }
        }
        // lock 승자는 workspace guard 미참조 필수 — snapshot의 mid-exit 패자에 양보하면 zero instance (#874);
        // guard는 unbundled 런치·lock 실패의 fallback 전용. `terminate(_:)`는 비동기 unwind — 여기서 return 필수.
        if !holdsLock, SingleInstanceGuard.deferToExistingInstance() {
            AppLog.info(.lifecycle, "duplicate launch detected; handing off to the running instance and terminating")
            NSApp.terminate(nil)
            return
        }
        // 이동 후에는 기존 bundle 경로에서 번역 리소스를 읽을 수 없으므로 필요한 문구를 먼저 로드.
        let renameRelaunchFailure = L10n.errors("egasu was renamed but could not reopen. Open egasu.app to finish the update.")
        let renameFailureTitle = L10n.errors("Couldn't Rename the App")
        let renameFailureMessage = L10n.errors("The update was installed, but OpenUsage.app could not be renamed to egasu.app. Check the folder permissions and any existing egasu.app. Your accounts and settings are unchanged.")
        let recoveryFailureTitle = L10n.errors("Couldn't Finish the App Update")
        let recoveryFailureMessage = L10n.errors("Open egasu.app again to finish the update and repair the terminal commands. Your accounts and settings are unchanged.")
        let confirmationTitle = L10n.dashboard("OK")
        do {
            if try AppBundleMigration.migrateIfNeeded(scheduleRelaunch: { destination in
                try AppRelauncher.makeRelaunchProcess(
                    bundleURL: destination,
                    processIdentifier: ProcessInfo.processInfo.processIdentifier,
                    failureMessage: renameRelaunchFailure,
                    confirmationTitle: confirmationTitle
                ).run()
            }) {
                NSApp.terminate(nil)
                return
            }
        } catch {
            AppDiagnostics.failure(.appRestart, error: error, localContext: "Legacy app bundle rename failed")
            let alert = NSAlert()
            let recoveryRequired = error is AppBundleMigration.RecoveryError
            alert.messageText = recoveryRequired ? recoveryFailureTitle : renameFailureTitle
            alert.informativeText = recoveryRequired ? recoveryFailureMessage : renameFailureMessage
            alert.addButton(withTitle: confirmationTitle)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            guard FileManager.default.fileExists(atPath: Bundle.main.bundlePath) else {
                NSApp.terminate(nil)
                return
            }
        }
        // 저장소 이전 전에 최초 실행 여부 캡처 — 이전 완료 표시가 설정 도메인을 변경.
        let isFreshInstall = SettingsMigrator.isFreshInstall()
        // 1.0.0의 "OpenUsage" 저장 위치를 egasu 이름으로 1회 이전 — 저장소를 사용하는 앱 구성보다 먼저 실행.
        do {
            try StorageMigration.runIfNeeded()
        } catch {
            AppDiagnostics.failure(.storageMigration, error: error, localContext: "Saved app data migration failed")
            let alert = NSAlert()
            alert.messageText = recoveryFailureTitle
            alert.informativeText = L10n.errors("Saved app data could not be moved. Check the app log and try again.")
            alert.addButton(withTitle: confirmationTitle)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
            return
        }
        SettingsMigrator.migrate(capturedFreshInstall: isFreshInstall)
        // 운영 앱에 기존 레이아웃이 없을 때만 원본 앱의 지표 설정 복사.
        if Bundle.main.bundleIdentifier == StorageNamespace.productionBundleIdentifier {
            SettingsMigrator.importUpstreamLayoutIfNeeded()
        }
        // 시작은 `SMAppService` login item 단독 담당 — AppKit reopen-on-login opt-out으로 재부팅 시 이중 런치 예방.
        NSApp.disableRelaunchOnLogin()
        // 레거시 Tauri autostart agent 정리 — 로그인 이중 실행 원인 (#607/#874). guard 이후 실행 필수 — 생존 copy만 파일 접근.
        LegacyLaunchAgentCleanup.removeLeftoverAgent()
        // 앱 전역 theme override는 AppKit 수준 적용 — popover가 SwiftUI `preferredColorScheme` 미준수.
        AppearanceSetting.applyCurrent()
        let migrationError: Error?
        do {
            try ClaudeLegacyShellMigration.runIfNeeded()
            migrationError = nil
        } catch {
            migrationError = error
        }
        let container = AppContainer(
            isFreshInstall: isFreshInstall,
            labsAvailable: updater.betaChannelEnabled,
            claudeShellMigrationIssue: migrationError.map(ClaudeLegacyShellMigration.message(for:)))
        if let migrationError {
            let reason = (migrationError as? ClaudeShellLoginMigrationError)?.rawValue ?? "system"
            AppDiagnostics.failure(
                .storageMigration, error: migrationError, providerID: "claude",
                localContext: "legacy shell login " + reason)
        }
        updater.onBetaChannelChange = { [weak container] enabled in
            container?.softLimitSettings.setLabsAvailable(enabled)
            container?.popover.reconcileSettingsTab(betaUpdatesEnabled: enabled)
        }
        self.container = container
        statusItemController = StatusItemController(container: container, updater: updater)
        // 백그라운드 업데이트 체크 시작 (release build 한정).
        updater.start()
    }

    /// Runner 소유 process group 정리까지 app 종료 지연.
    public func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isAwaitingProcessShutdown else { return .terminateLater }
        guard let container, container.hasRunningBackgroundProcesses else { return .terminateNow }
        isAwaitingProcessShutdown = true
        Task { @MainActor in
            await container.shutdownBackgroundProcesses()
            self.isAwaitingProcessShutdown = false
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// 종료 시 대기 telemetry flush — SDK lifecycle autocapture off라 자동 flush 부재, 저빈도 이벤트 유실 방지.
    public func applicationWillTerminate(_ notification: Notification) {
        container?.telemetry.flush()
    }
}
