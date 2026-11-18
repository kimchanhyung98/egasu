import Foundation
import Sparkle
import XCTest
@testable import Egasu

@MainActor
final class BannerUpdateUserDriverTests: XCTestCase {
    func testBannerDismissRepliesOnceAndIgnoresTheLateStandardResponse() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let item = try makeItem()
        let state = try makeState()
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: item, state: state) { choices.append($0) }

        driver.dismissPendingUpdate()
        driver.dismissPendingUpdate()
        standard.updateReplies[0](.install)

        XCTAssertEqual(choices, [.dismiss])
        XCTAssertTrue(standard.foundItem === item)
        XCTAssertTrue(standard.foundState === state)
        XCTAssertEqual(standard.dismissCount, 0, "배너는 UI만 닫지 않고 Sparkle에 선택 응답 전달")
    }

    func testEveryStandardChoiceResolvesTheBannerResponseOnce() throws {
        for choice in [SPUUserUpdateChoice.install, .dismiss, .skip] {
            let standard = RecordingUpdateUserDriver()
            let driver = BannerUpdateUserDriver(standardDriver: standard)
            var choices: [SPUUserUpdateChoice] = []
            driver.showUpdateFound(with: try makeItem(), state: try makeState()) { choices.append($0) }

            standard.updateReplies[0](choice)
            driver.dismissPendingUpdate()
            standard.updateReplies[0](.dismiss)

            XCTAssertEqual(choices, [choice])
        }
    }

    func testManualUpdateCannotBeDismissedByTheBanner() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: try makeItem(), state: try makeState(userInitiated: true)) {
            choices.append($0)
        }

        driver.dismissPendingUpdate()
        XCTAssertTrue(choices.isEmpty)
        standard.updateReplies[0](.install)
        standard.updateReplies[0](.skip)

        XCTAssertEqual(choices, [.install])
    }

    func testSynchronousStandardResponseIsRegisteredBeforeForwarding() throws {
        let standard = RecordingUpdateUserDriver()
        standard.immediateChoice = .skip
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        var choices: [SPUUserUpdateChoice] = []

        driver.showUpdateFound(with: try makeItem(), state: try makeState()) { choices.append($0) }
        driver.dismissPendingUpdate()

        XCTAssertEqual(choices, [.skip])
    }

    func testNewUpdateInvalidatesTheOldReplyWithoutConsumingTheNewReply() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let item = try makeItem()
        let state = try makeState()
        var first: [SPUUserUpdateChoice] = []
        var second: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: item, state: state) { first.append($0) }
        driver.showUpdateFound(with: item, state: state) { second.append($0) }

        standard.updateReplies[0](.install)
        driver.dismissPendingUpdate()
        standard.updateReplies[1](.skip)

        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [.dismiss])
    }

    func testReplyCanStartTheNextUpdateReentrantly() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let item = try makeItem()
        let state = try makeState()
        var first: [SPUUserUpdateChoice] = []
        var second: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: item, state: state) { choice in
            first.append(choice)
            driver.dismissPendingUpdate()
            driver.showUpdateFound(with: item, state: state) { second.append($0) }
        }

        driver.dismissPendingUpdate()
        standard.updateReplies[0](.install)
        driver.dismissPendingUpdate()

        XCTAssertEqual(first, [.dismiss])
        XCTAssertEqual(second, [.dismiss])
    }

    func testSessionTeardownInvalidatesRepliesBeforeTheStandardDriverRuns() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let item = try makeItem()
        let state = try makeState()
        var first: [SPUUserUpdateChoice] = []
        var second: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: item, state: state) { first.append($0) }
        let oldReply = standard.updateReplies[0]
        standard.onDismiss = { oldReply(.install) }

        driver.dismissUpdateInstallation()
        driver.dismissPendingUpdate()
        driver.showUpdateFound(with: item, state: state) { second.append($0) }
        oldReply(.skip)
        driver.dismissPendingUpdate()

        XCTAssertEqual(standard.dismissCount, 1)
        XCTAssertTrue(first.isEmpty)
        XCTAssertEqual(second, [.dismiss])
    }

    func testTeardownAlsoInvalidatesAManualUpdateReply() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: try makeItem(), state: try makeState(userInitiated: true)) {
            choices.append($0)
        }

        driver.dismissUpdateInstallation()
        standard.updateReplies[0](.install)

        XCTAssertTrue(choices.isEmpty)
    }

    func testResolvedAndInvalidatedRepliesReleaseTheirCaptures() throws {
        for resolves in [false, true] {
            let standard = RecordingUpdateUserDriver()
            let driver = BannerUpdateUserDriver(standardDriver: standard)
            weak var retainedProbe: NSObject?
            do {
                let probe = NSObject()
                retainedProbe = probe
                driver.showUpdateFound(with: try makeItem(), state: try makeState()) { [probe] _ in
                    _ = probe.description
                }
            }
            XCTAssertNotNil(retainedProbe)

            if resolves { driver.dismissPendingUpdate() } else { driver.dismissUpdateInstallation() }

            XCTAssertNil(retainedProbe, "표준 드라이버가 늦은 callback을 보유해도 원본 캡처 해제")
        }
    }

    func testRetainedStandardCallbackDoesNotRetainTheAdapter() throws {
        let standard = RecordingUpdateUserDriver()
        weak var releasedDriver: BannerUpdateUserDriver?
        do {
            let driver = BannerUpdateUserDriver(standardDriver: standard)
            releasedDriver = driver
            driver.showUpdateFound(with: try makeItem(), state: try makeState()) { _ in }
        }

        XCTAssertNil(releasedDriver)
        standard.updateReplies[0](.dismiss)
    }

    func testStandardProgressFocusAndErrorRoutesAreForwarded() {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let error = NSError(domain: "test.updater", code: 7)
        var checkCancelled = false
        var downloadCancelled = false
        var acknowledgements = 0
        var installationChoices: [SPUUserUpdateChoice] = []
        var retriedTermination = false

        driver.showUserInitiatedUpdateCheck { checkCancelled = true }
        driver.showDownloadInitiated { downloadCancelled = true }
        driver.showDownloadDidReceiveExpectedContentLength(120)
        driver.showDownloadDidReceiveData(ofLength: 30)
        driver.showDownloadDidStartExtractingUpdate()
        driver.showExtractionReceivedProgress(0.25)
        driver.showReady(toInstallAndRelaunch: { installationChoices.append($0) })
        driver.showInstallingUpdate(withApplicationTerminated: false) { retriedTermination = true }
        driver.showUpdateReleaseNotesFailedToDownloadWithError(error)
        driver.showUpdateNotFoundWithError(error) { acknowledgements += 1 }
        driver.showUpdaterError(error) { acknowledgements += 1 }
        driver.showUpdateInstalledAndRelaunched(true) { acknowledgements += 1 }
        driver.showUpdateInFocus()

        standard.checkCancellation?()
        standard.downloadCancellation?()
        standard.installReply?(.install)
        standard.retryTermination?()
        for acknowledge in standard.acknowledgements { acknowledge() }
        XCTAssertTrue(checkCancelled)
        XCTAssertTrue(downloadCancelled)
        XCTAssertTrue(retriedTermination)
        XCTAssertEqual(acknowledgements, 3)
        XCTAssertEqual(installationChoices, [.install])
        XCTAssertEqual(standard.expectedLength, 120)
        XCTAssertEqual(standard.receivedLength, 30)
        XCTAssertEqual(standard.progress, 0.25)
        XCTAssertEqual(standard.extractionCount, 1)
        XCTAssertEqual(standard.applicationTerminated, false)
        XCTAssertEqual(standard.relaunched, true)
        XCTAssertEqual(standard.focusCount, 1)
        XCTAssertEqual(standard.errors.map { $0 as NSError }, [error, error, error])
    }

    func testPermissionAndReleaseNotesAreForwardedUnchanged() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let request = SPUUpdatePermissionRequest(systemProfile: [])
        let response = SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false)
        let notes = SPUDownloadData()
        var permissionResponse: SUUpdatePermissionResponse?

        driver.show(request) { permissionResponse = $0 }
        driver.showUpdateReleaseNotes(with: notes)
        standard.permissionReply?(response)

        XCTAssertTrue(standard.permissionRequest === request)
        XCTAssertTrue(permissionResponse === response)
        XCTAssertTrue(standard.releaseNotes === notes)
    }

    func testDisablingBetaWithdrawsScheduledAndManualOffersOnce() throws {
        for stage in [SPUUserUpdateStage.notDownloaded, .downloaded] {
            for userInitiated in [false, true] {
                var betaEnabled = true
                let standard = RecordingUpdateUserDriver()
                let driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { betaEnabled })
                var choices: [SPUUserUpdateChoice] = []
                driver.showUpdateFound(
                    with: try makeItem(channel: "beta"),
                    state: try makeState(userInitiated: userInitiated, stage: stage)
                ) {
                    choices.append($0)
                }
                betaEnabled = false

                XCTAssertTrue(driver.dismissDisallowedUpdate())
                XCTAssertFalse(driver.dismissDisallowedUpdate())
                standard.updateReplies[0](.install)
                driver.dismissUpdateInstallation()

                XCTAssertEqual(choices, [.dismiss])
                XCTAssertTrue(driver.requiresFreshUpdater, "종료 뒤에도 보관된 베타 재개 대상 제거 요청 유지")
            }
        }
    }

    func testBetaResponseArrivingAfterOptOutNeverReachesTheStandardUI() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { false })
        var choices: [SPUUserUpdateChoice] = []

        driver.showUpdateFound(with: try makeItem(channel: "beta"), state: try makeState()) { choices.append($0) }

        XCTAssertNil(standard.foundItem)
        XCTAssertTrue(standard.updateReplies.isEmpty)
        XCTAssertEqual(choices, [.dismiss])
        XCTAssertTrue(driver.requiresFreshUpdater)
    }

    func testDelayedScheduledPresentationOnlyPublishesTheMatchingPendingOffer() throws {
        let standard = RecordingUpdateUserDriver()
        var betaEnabled = true
        let driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { betaEnabled })
        let delegate = UpdaterUserDriverDelegate()
        delegate.isPendingScheduledUpdate = { driver.isPendingScheduledUpdate($0) }
        var displayedVersions: [String] = []
        delegate.onUpdateFound = { displayedVersions.append($0) }

        let state = try makeState()
        let stable = try makeItem()
        let beta = try makeItem(channel: "beta", version: stable.displayVersionString)
        driver.showUpdateFound(with: stable, state: state) { _ in }
        delegate.standardUserDriverWillHandleShowingUpdate(false, forUpdate: stable, state: state)
        XCTAssertEqual(displayedVersions, [stable.displayVersionString])

        driver.dismissPendingUpdate()
        delegate.standardUserDriverWillHandleShowingUpdate(false, forUpdate: stable, state: state)
        XCTAssertEqual(displayedVersions.count, 1)

        driver.showUpdateFound(with: beta, state: state) { _ in }
        delegate.standardUserDriverWillHandleShowingUpdate(false, forUpdate: stable, state: state)
        XCTAssertEqual(displayedVersions.count, 1, "표시 버전이 같아도 제안이 달라지면 이전 알림 무시")
        delegate.standardUserDriverWillHandleShowingUpdate(false, forUpdate: beta, state: state)
        XCTAssertEqual(displayedVersions.count, 2)

        betaEnabled = false
        XCTAssertTrue(driver.dismissDisallowedUpdate())
        delegate.standardUserDriverWillHandleShowingUpdate(false, forUpdate: beta, state: state)
        XCTAssertEqual(displayedVersions.count, 2)
    }

    func testDefaultChannelIsPreservedEvenWhenItsVersionContainsBeta() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { false })
        let item = try makeItem(version: "2.0-beta.1")
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: item, state: try makeState()) { choices.append($0) }

        XCTAssertFalse(driver.dismissDisallowedUpdate())
        XCTAssertFalse(driver.requiresFreshUpdater)
        XCTAssertTrue(standard.foundItem === item)
        XCTAssertTrue(choices.isEmpty)
    }

    func testBetaOptOutPreservesAnUpdateThatIsAlreadyInstalling() throws {
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { false })
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: try makeItem(channel: "beta"), state: try makeState(stage: .installing)) {
            choices.append($0)
        }

        XCTAssertFalse(driver.dismissDisallowedUpdate())
        XCTAssertFalse(driver.requiresFreshUpdater)
        XCTAssertNotNil(standard.foundItem)
        XCTAssertTrue(choices.isEmpty)
    }

    func testBetaOptOutDoesNotCancelAnAcceptedInstallChoice() throws {
        var betaEnabled = true
        let standard = RecordingUpdateUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { betaEnabled })
        var choices: [SPUUserUpdateChoice] = []
        driver.showUpdateFound(with: try makeItem(channel: "beta"), state: try makeState()) { choices.append($0) }
        standard.updateReplies[0](.install)
        betaEnabled = false

        XCTAssertFalse(driver.dismissDisallowedUpdate())
        XCTAssertFalse(driver.requiresFreshUpdater)
        XCTAssertEqual(choices, [.install])
    }

    func testOptingBackInAllowsTheSameBetaWithoutSkippingIt() throws {
        var betaEnabled = false
        let standard = RecordingUpdateUserDriver()
        let item = try makeItem(channel: "beta")
        let oldDriver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { betaEnabled })
        var oldChoices: [SPUUserUpdateChoice] = []
        oldDriver.showUpdateFound(with: item, state: try makeState()) { oldChoices.append($0) }
        oldDriver.dismissUpdateInstallation()
        betaEnabled = true
        let newDriver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { betaEnabled })
        var newChoices: [SPUUserUpdateChoice] = []
        newDriver.showUpdateFound(with: item, state: try makeState()) { newChoices.append($0) }

        XCTAssertEqual(oldChoices, [.dismiss])
        XCTAssertTrue(newChoices.isEmpty)
        XCTAssertTrue(standard.foundItem === item)
        XCTAssertFalse(newDriver.requiresFreshUpdater)
    }

    private func makeState(
        userInitiated: Bool = false, stage: SPUUserUpdateStage = .notDownloaded
    ) throws -> SPUUserUpdateState {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(stage.rawValue, forKey: "SPUUserUpdateStateStage")
        encoder.encode(userInitiated, forKey: "SPUUserUpdateStateUserInitiated")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        defer { decoder.finishDecoding() }
        return try XCTUnwrap(SPUUserUpdateState(coder: decoder))
    }

    private func makeItem(channel: String? = nil, version: String = "2.0") throws -> SUAppcastItem {
        let encoder = NSKeyedArchiver(requiringSecureCoding: true)
        encoder.encode(URL(string: "https://example.invalid/update.zip")!, forKey: "fileURL")
        encoder.encode("application", forKey: "SUAppcastItemInstallationType")
        encoder.encode(version, forKey: "versionString")
        encoder.encode(version, forKey: "displayVersionString")
        if let channel { encoder.encode(channel, forKey: "sparkle:channel") }
        encoder.encode([String: String](), forKey: "propertiesDictionary")
        encoder.finishEncoding()
        let decoder = try NSKeyedUnarchiver(forReadingFrom: encoder.encodedData)
        defer { decoder.finishDecoding() }
        return try XCTUnwrap(SUAppcastItem(coder: decoder))
    }
}

@MainActor
private final class RecordingUpdateUserDriver: NSObject, SPUUserDriver {
    var updateReplies: [(SPUUserUpdateChoice) -> Void] = []
    var immediateChoice: SPUUserUpdateChoice?
    var foundItem: SUAppcastItem?
    var foundState: SPUUserUpdateState?
    var dismissCount = 0
    var onDismiss: (() -> Void)?
    var permissionRequest: SPUUpdatePermissionRequest?
    var permissionReply: ((SUUpdatePermissionResponse) -> Void)?
    var releaseNotes: SPUDownloadData?
    var checkCancellation: (() -> Void)?
    var downloadCancellation: (() -> Void)?
    var installReply: ((SPUUserUpdateChoice) -> Void)?
    var retryTermination: (() -> Void)?
    var acknowledgements: [() -> Void] = []
    var errors: [Error] = []
    var expectedLength: UInt64?
    var receivedLength: UInt64?
    var extractionCount = 0
    var progress: Double?
    var applicationTerminated: Bool?
    var relaunched: Bool?
    var focusCount = 0

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        foundItem = appcastItem
        foundState = state
        updateReplies.append(reply)
        if let immediateChoice { reply(immediateChoice) }
    }

    func dismissUpdateInstallation() { dismissCount += 1; onDismiss?() }
    func show(
        _ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void
    ) {
        permissionRequest = request
        permissionReply = reply
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) { checkCancellation = cancellation }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { releaseNotes = downloadData }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { errors.append(error) }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        errors.append(error)
        acknowledgements.append(acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        errors.append(error)
        acknowledgements.append(acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) { downloadCancellation = cancellation }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        expectedLength = expectedContentLength
    }
    func showDownloadDidReceiveData(ofLength length: UInt64) { receivedLength = length }
    func showDownloadDidStartExtractingUpdate() { extractionCount += 1 }
    func showExtractionReceivedProgress(_ progress: Double) { self.progress = progress }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) { installReply = reply }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) {
        self.applicationTerminated = applicationTerminated
        retryTermination = retryTerminatingApplication
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        self.relaunched = relaunched
        acknowledgements.append(acknowledgement)
    }

    func showUpdateInFocus() { focusCount += 1 }
}
