import AppKit
import Combine
import Foundation
import Observation
import Sparkle

private extension UserDefaults {
    @objc dynamic var betaUpdatesEnabled: Bool { bool(forKey: #keyPath(UserDefaults.betaUpdatesEnabled)) }
}

/// Sparkle 표준 업데이터 연결 — 앱의 다른 영역은 Sparkle에 의존하지 않음.
/// SUFeedURL이 있는 패키지 번들에서만 동작 — swift run·개발 빌드는 비활성.
@MainActor
@Observable
final class UpdaterController {
    /// 베타 채널 참여 설정 키 — SwiftUI 토글과 Sparkle 채널 선택이 공유하는 단일 값.
    static let betaChannelDefaultsKey = #keyPath(UserDefaults.betaUpdatesEnabled)

    // SPUUpdaterDelegate는 MainActor, SPUStandardUserDriverDelegate는 nonisolated이므로 별도 객체 사용.
    // 두 프로토콜을 한 클래스에서 구현하면 Swift 6 격리 규칙 충돌.
    private let channelDelegate = UpdaterChannelDelegate()
    private var userDriverDelegate: UpdaterUserDriverDelegate?
    private let presentationController: UpdaterPresentationController
    private var updater: SPUUpdater?
    private var userDriver: BannerUpdateUserDriver?
    private var canCheckObservation: AnyCancellable?
    private let defaults: UserDefaults
    private var betaChannelObservation: AnyCancellable?
    private var currentBetaChannel: Bool
    @ObservationIgnored var onBetaChannelChange: ((Bool) -> Void)?

    /// 업데이트 피드가 있는 빌드에서의 활성 상태 — 자동 확인 설정의 활성화 조건.
    private(set) var isActive = false
    /// Sparkle KVO의 canCheckForUpdates 반영 — "Check for Updates…" 버튼 활성화 조건.
    private(set) var canCheckForUpdates = false
    /// 자동 확인에서 발견한 업데이트 버전 — 없으면 nil.
    /// Dock 없는 앱의 창이 뒤에 열리는 문제를 피하도록 대시보드 배너 표시.
    private(set) var availableUpdateVersion: String?

    /// "Beta Updates" 설정 저장 — 변경 시 확인 주기를 재설정하여 다음 확인부터 새 채널 적용.
    var betaChannelEnabled: Bool {
        get { currentBetaChannel }
        set {
            defaults.set(newValue, forKey: Self.betaChannelDefaultsKey)
            applyBetaChannel(newValue)
        }
    }

    /// "Update Automatically" 설정 — 별도 사본 없이 Sparkle의 저장값에 직접 연결.
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    init(
        presentationController: UpdaterPresentationController = UpdaterPresentationController(),
        defaults: UserDefaults = .standard
    ) {
        self.presentationController = presentationController
        self.defaults = defaults
        self.currentBetaChannel = defaults.betaUpdatesEnabled
        betaChannelObservation = defaults.publisher(for: \.betaUpdatesEnabled, options: [.new])
            .sink { @Sendable [weak self] enabled in
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.applyBetaChannel(enabled) }
                } else {
                    DispatchQueue.main.async { [weak self] in
                        guard let self else { return }
                        self.applyBetaChannel(self.defaults.betaUpdatesEnabled)
                    }
                }
            }
    }

    private func applyBetaChannel(_ enabled: Bool) {
        guard currentBetaChannel != enabled else { return }
        currentBetaChannel = enabled
        onBetaChannelChange?(enabled)
        if userDriver?.dismissDisallowedUpdate() == true { availableUpdateVersion = nil }
        updater?.resetUpdateCycle()
        AppLog.info(.updates, "channel set to \(enabled ? "early access" : "stable")")
    }

    /// 업데이트 피드가 있는 빌드에서만 업데이터 시작 — 중복 호출 무시.
    func start() {
        guard updater == nil else { return }
        guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else {
            AppLog.info(.updates, "disabled: no SUFeedURL (unbundled or dev build)")
            return
        }
        let userDriverDelegate = UpdaterUserDriverDelegate()
        // nonisolated 델리게이트의 메인 스레드 콜백을 메인 액터로 연결하여 배너 상태 반영.
        userDriverDelegate.onUpdateFound = { [weak self] version in
            self?.availableUpdateVersion = version
            AppLog.info(.updates, "scheduled check found \(version); showing in-app banner")
        }
        userDriverDelegate.onUpdateResolved = { [weak self] in
            self?.availableUpdateVersion = nil
        }
        userDriverDelegate.onUpdateWillShow = { [weak self] in
            self?.presentationController.bringToFront(reason: "Sparkle will show update")
        }
        userDriverDelegate.onUpdateSessionFinished = { [weak self] in
            self?.presentationController.returnToMenuBar()
        }
        channelDelegate.isCurrentUpdater = { [weak self] updater in self?.updater === updater }
        channelDelegate.onUpdateCycleFinished = { [weak self] in
            guard let self, self.userDriver?.requiresFreshUpdater == true else { return }
            self.canCheckObservation = nil
            self.updater = nil
            self.userDriver = nil
            self.userDriverDelegate = nil
            self.isActive = false
            self.canCheckForUpdates = false
            self.start()
        }
        let userDriver = BannerUpdateUserDriver(
            standardDriver: SPUStandardUserDriver(hostBundle: .main, delegate: userDriverDelegate),
            isBetaChannelEnabled: { [weak self] in self?.betaChannelEnabled ?? false }
        )
        userDriverDelegate.isPendingScheduledUpdate = { [weak self, weak userDriver] itemID in
            guard let userDriver, self?.userDriver === userDriver else { return false }
            return userDriver.isPendingScheduledUpdate(itemID)
        }
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main,
            userDriver: userDriver, delegate: channelDelegate
        )
        self.userDriverDelegate = userDriverDelegate
        do {
            try updater.start()
        } catch {
            AppDiagnostics.failure(.updateCheck, error: error, localContext: "Updater failed to start")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self else { return }
                self.presentationController.bringToFront(reason: "updater failed to start")
                userDriver.showUpdaterError(error) { userDriver.dismissUpdateInstallation() }
            }
            return
        }
        self.updater = updater
        self.userDriver = userDriver
        isActive = true
        // Sparkle KVO를 Observable 상태로 연결 — 메인 큐 전달로 메인 액터 변경 보장.
        canCheckForUpdates = updater.canCheckForUpdates
        canCheckObservation = updater.publisher(for: \.canCheckForUpdates)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] value in
                MainActor.assumeIsolated { self?.canCheckForUpdates = value }
            }
        AppLog.info(.updates, "started (feed present)")
    }

    /// 사용자의 업데이트 확인 요청 — Sparkle 표준 화면 표시.
    func checkForUpdates() {
        guard let updater else { return }
        // Sparkle에 제어를 넘기기 전에 앱을 전면으로 전환.
        // 다음 실행 루프에서 확인 창 표시 — 앱 활성화 정책 변경 직후 창이 뒤에 열리는 현상 방지.
        presentationController.bringToFront(reason: "user initiated check")
        DispatchQueue.main.async {
            updater.checkForUpdates()
        }
    }

    /// 배너의 설치 요청을 사용자 확인 경로로 전달 — 유효한 업데이트는 Sparkle이 전면 표시.
    func installAvailableUpdate() {
        checkForUpdates()
    }

    static func recordUpdateCycle(error: Error?) {
        let channel = UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? "early access" : "stable"
        guard let error else {
            AppDiagnostics.record(.updateCheck, result: .success)
            AppLog.info(.updates, "check finished (channel=\(channel), no error)")
            return
        }
        let code = (error as NSError).code
        let downloadError = underlyingDownloadURLError(error)
        if code == Int(SUError.noUpdateError.rawValue) {
            AppDiagnostics.record(.updateCheck, result: .success)
            AppLog.info(.updates, "check finished (channel=\(channel), no update available)")
        } else if code == Int(SUError.installationCanceledError.rawValue) || downloadError?.code == .cancelled {
            AppDiagnostics.record(.updateCheck, result: .cancelled)
            AppLog.info(.updates, "check finished (channel=\(channel), user canceled)")
        } else {
            let category: ErrorCategory = downloadError == nil ? ErrorCategory.classify(error) : .network
            AppDiagnostics.record(.updateCheck, result: .failure, category: category, error: error,
                                  localContext: "Update check or download failed")
        }
    }

    private static func underlyingDownloadURLError(_ error: Error) -> URLError? {
        var current = error as NSError
        // 다운로드·appcast의 연속 포장 두 단계에서 URL 오류 원인과 취소 코드만 복원.
        for _ in 0..<2 {
            guard current.domain == SUSparkleErrorDomain,
                  current.code == Int(SUError.downloadError.rawValue),
                  let underlying = current.userInfo[NSUnderlyingErrorKey] as? Error else { break }
            if let urlError = underlying as? URLError { return urlError }
            current = underlying as NSError
        }
        return nil
    }

    /// 배너 닫기는 일시 보류 응답 — 세션 종료 뒤 Sparkle의 다음 자동 확인에서 다시 알림.
    func dismissAvailableUpdate() {
        guard availableUpdateVersion != nil else { return }
        availableUpdateVersion = nil
        userDriver?.dismissPendingUpdate()
    }
}

/// Dock 없는 메뉴 막대 앱의 Sparkle 창 표시를 위한 AppKit 제어.
/// 다른 앱이 활성화된 상태에서도 전면 표시하도록 ignoringOtherApps 사용.
/// 주입된 클로저로 macOS 포커스 자동화 없이 동작 검증.
@MainActor
final class UpdaterPresentationController {
    private let activationPolicy: @MainActor () -> NSApplication.ActivationPolicy
    private let isActive: @MainActor () -> Bool
    private let setActivationPolicy: @MainActor (NSApplication.ActivationPolicy) -> Bool
    private let activate: @MainActor (Bool) -> Void

    convenience init(application: NSApplication = .shared) {
        self.init(
            activationPolicy: { application.activationPolicy() },
            isActive: { application.isActive },
            setActivationPolicy: { application.setActivationPolicy($0) },
            activate: { application.activate(ignoringOtherApps: $0) }
        )
    }

    init(
        activationPolicy: @escaping @MainActor () -> NSApplication.ActivationPolicy,
        isActive: @escaping @MainActor () -> Bool,
        setActivationPolicy: @escaping @MainActor (NSApplication.ActivationPolicy) -> Bool,
        activate: @escaping @MainActor (Bool) -> Void
    ) {
        self.activationPolicy = activationPolicy
        self.isActive = isActive
        self.setActivationPolicy = setActivationPolicy
        self.activate = activate
    }

    func bringToFront(reason: String) {
        let beforePolicy = activationPolicy()
        let beforeActive = isActive()
        let policyChanged = setActivationPolicy(.regular)
        activate(true)
        AppLog.info(
            .updates,
            "foreground updater (reason=\(reason), policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(beforeActive)->\(isActive()), policyChanged=\(policyChanged))"
        )
    }

    func returnToMenuBar() {
        let beforePolicy = activationPolicy()
        let policyChanged = setActivationPolicy(.accessory)
        AppLog.info(
            .updates,
            "finish updater presentation (policy=\(beforePolicy.rawValue)->\(activationPolicy().rawValue), " +
                "active=\(isActive()), policyChanged=\(policyChanged))"
        )
    }
}

/// Sparkle의 MainActor 채널 선택 델리게이트 — 설정 키에 직접 접근.
@MainActor
final class UpdaterChannelDelegate: NSObject, SPUUpdaterDelegate {
    var isCurrentUpdater: (SPUUpdater) -> Bool = { _ in true }
    var onUpdateCycleFinished: (() -> Void)?

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard isCurrentUpdater(updater) else {
            throw NSError(
                domain: SUSparkleErrorDomain, code: Int(SUError.installationCanceledError.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "The update session was replaced."]
            )
        }
    }

    /// 기본은 정식 채널 — beta 반환 시 베타를 추가하며 정식 릴리스도 계속 포함.
    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        UserDefaults.standard.bool(forKey: UpdaterController.betaChannelDefaultsKey) ? ["beta"] : []
    }

    /// 업데이트 확인 결과 기록 — 업데이트 없음·사용자 취소는 INFO, 실패는 공통 진단 기록.
    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        guard isCurrentUpdater(updater) else { return }
        UpdaterController.recordUpdateCycle(error: error)
        onUpdateCycleFinished?()
    }
}

/// 메뉴 막대 앱의 활성화 처리 델리게이트 — Sparkle 프로토콜은 nonisolated.
/// 콜백은 메인 스레드에서 실행되므로 NSApp 접근 시 MainActor.assumeIsolated 사용.
final class UpdaterUserDriverDelegate: NSObject, SPUStandardUserDriverDelegate {
    /// 자동 확인에서 발견한 버전을 메인 액터의 UpdaterController에 전달하여 배너 표시.
    var onUpdateFound: (@MainActor @Sendable (String) -> Void)?
    var isPendingScheduledUpdate: (@MainActor @Sendable (ObjectIdentifier) -> Bool)?
    /// 배너 해제 — 사용자가 업데이트에 주의를 주었거나 세션 종료.
    var onUpdateResolved: (@MainActor @Sendable () -> Void)?
    /// Sparkle 업데이트 화면 표시 직전에 전면 위치 확보.
    var onUpdateWillShow: (@MainActor @Sendable () -> Void)?
    /// 세션 종료 후 Dock 없는 앱 활성화 정책 복원.
    var onUpdateSessionFinished: (@MainActor @Sendable () -> Void)?

    /// 자동 확인 알림이 포커스를 가져가지 않도록 조용한 알림 사용.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    /// 자동 업데이트 알림을 onUpdateFound 경유 패널 배너로 표시 — Dock 없는 앱에서 창이 뒤에 열리는 현상 방지.
    /// 사용자가 시작한 확인은 이 메서드를 거치지 않고 Sparkle이 직접 전면 표시.
    func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        false
    }

    /// 업데이트 화면을 표시하는 동안만 일반 앱으로 전환 — accessory 상태의 창 포커스 문제 방지.
    /// handleShowingUpdate가 true여서 실제 창을 표시할 때만 전환.
    /// 배너만 표시할 때는 Dock 아이콘이 잠깐 나타나지 않도록 기존 정책 유지.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        let version = update.displayVersionString
        let itemID = ObjectIdentifier(update)
        // Swift 6 격리 규칙 준수 — 메인 액터 클로저에는 nonisolated self 대신 Sendable 콜백만 캡처.
        let onUpdateFound = onUpdateFound
        let isPendingScheduledUpdate = isPendingScheduledUpdate
        let onUpdateWillShow = onUpdateWillShow
        MainActor.assumeIsolated {
            guard handleShowingUpdate else {
                // Sparkle이 알림을 다음 실행 루프로 전달하므로 그 사이 철회된 제안은 표시하지 않음.
                if isPendingScheduledUpdate?(itemID) == true { onUpdateFound?(version) }
                return
            }
            onUpdateWillShow?()
        }
    }

    /// 사용자가 Sparkle 업데이트 창을 확인하면 배너 해제.
    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        let onUpdateResolved = onUpdateResolved
        MainActor.assumeIsolated { () -> Void in
            onUpdateResolved?()
        }
    }

    /// 업데이트 세션 종료 시 메뉴 막대 전용 상태 복원과 남은 앱 내 표시 해제.
    func standardUserDriverWillFinishUpdateSession() {
        let onUpdateResolved = onUpdateResolved
        let onUpdateSessionFinished = onUpdateSessionFinished
        MainActor.assumeIsolated { () -> Void in
            onUpdateSessionFinished?()
            onUpdateResolved?()
        }
    }
}
