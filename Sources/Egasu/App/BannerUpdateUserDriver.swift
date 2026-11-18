import Foundation
import Sparkle

/// 표준 업데이트 UI를 유지하며 배너와 표준창의 선택 응답을 한 번만 전달.
@MainActor
final class BannerUpdateUserDriver: NSObject, SPUUserDriver {
    private let standardDriver: any SPUUserDriver
    private let isBetaChannelEnabled: () -> Bool
    private var activeReply: UpdateReply?
    private var pendingUpdate: UpdateReply?
    /// 베타 철회 후 보관된 재개 대상까지 버리도록 세션 종료 뒤 업데이터 재생성 요청.
    private(set) var requiresFreshUpdater = false

    init(standardDriver: any SPUUserDriver, isBetaChannelEnabled: @escaping () -> Bool = { true }) {
        self.standardDriver = standardDriver
        self.isBetaChannelEnabled = isBetaChannelEnabled
        super.init()
    }

    func isPendingScheduledUpdate(_ itemID: ObjectIdentifier) -> Bool {
        pendingUpdate?.itemID == itemID
    }

    func dismissPendingUpdate() {
        guard let pendingUpdate else { return }
        respond(to: pendingUpdate, with: .dismiss)
    }

    @discardableResult
    func dismissDisallowedUpdate() -> Bool {
        guard !isBetaChannelEnabled(), let activeReply, activeReply.requiresBetaChannel else { return false }
        requiresFreshUpdater = true
        respond(to: activeReply, with: .dismiss)
        return true
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        activeReply?.invalidate()
        let response = UpdateReply(
            reply, itemID: ObjectIdentifier(appcastItem),
            requiresBetaChannel: appcastItem.channel == "beta" && state.stage != .installing
        )
        activeReply = response
        pendingUpdate = state.userInitiated ? nil : response
        guard !dismissDisallowedUpdate() else { return }
        standardDriver.showUpdateFound(with: appcastItem, state: state) { [weak self, response] choice in
            self?.respond(to: response, with: choice)
        }
    }

    private func respond(to response: UpdateReply, with choice: SPUUserUpdateChoice) {
        guard activeReply === response else { return }
        activeReply = nil
        pendingUpdate = nil
        // 원본 응답이 새 업데이트를 동기적으로 시작해도 새 응답을 보존.
        let reply = response.take()
        reply?(choice)
    }

    func dismissUpdateInstallation() {
        activeReply?.invalidate()
        activeReply = nil
        pendingUpdate = nil
        standardDriver.dismissUpdateInstallation()
    }

    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        standardDriver.show(request, reply: reply)
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        standardDriver.showUserInitiatedUpdateCheck(cancellation: cancellation)
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        standardDriver.showUpdateReleaseNotes(with: downloadData)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        standardDriver.showUpdateReleaseNotesFailedToDownloadWithError(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdateNotFoundWithError(error, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdaterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        standardDriver.showDownloadInitiated(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        standardDriver.showDownloadDidReceiveExpectedContentLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        standardDriver.showDownloadDidReceiveData(ofLength: length)
    }

    func showDownloadDidStartExtractingUpdate() {
        standardDriver.showDownloadDidStartExtractingUpdate()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        standardDriver.showExtractionReceivedProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        standardDriver.showReady(toInstallAndRelaunch: reply)
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        standardDriver.showInstallingUpdate(
            withApplicationTerminated: applicationTerminated,
            retryTerminatingApplication: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        standardDriver.showUpdateInstalledAndRelaunched(relaunched, acknowledgement: acknowledgement)
    }

    func showUpdateInFocus() {
        standardDriver.showUpdateInFocus?()
    }

    @MainActor
    private final class UpdateReply {
        private var reply: ((SPUUserUpdateChoice) -> Void)?
        let itemID: ObjectIdentifier
        let requiresBetaChannel: Bool

        init(_ reply: @escaping (SPUUserUpdateChoice) -> Void, itemID: ObjectIdentifier, requiresBetaChannel: Bool) {
            self.reply = reply
            self.itemID = itemID
            self.requiresBetaChannel = requiresBetaChannel
        }

        func take() -> ((SPUUserUpdateChoice) -> Void)? {
            defer { reply = nil }
            return reply
        }

        func invalidate() {
            reply = nil
        }
    }
}
