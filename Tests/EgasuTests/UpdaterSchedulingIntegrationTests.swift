import Foundation
import Network
import Sparkle
import XCTest
@testable import Egasu

@MainActor
final class UpdaterSchedulingIntegrationTests: XCTestCase {
    func testBannerDismissEndsTheRealSparkleSessionAndSchedulesAnotherCheck() async throws {
        for key in ["SUEnableDownloaderService", "SUEnableInstallerStatusService"] {
            let enabled = (Bundle.main.object(forInfoDictionaryKey: key) as? NSNumber)?.boolValue ?? false
            XCTAssertFalse(enabled, "The fixture requires in-process Sparkle services: \(key)")
            guard !enabled else { return }
        }

        let identifier = "EgasuTests.UpdaterScheduling.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = SchedulingUserDriver()
        let driver = BannerUpdateUserDriver(standardDriver: standard)
        let observer = SchedulingObserver()
        var updater: SPUUpdater?
        let server = try SchedulingAppcastServer()
        defer {
            driver.dismissPendingUpdate()
            updater?.automaticallyChecksForUpdates = false
            updater = nil
            server.stop()
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        server.start()
        try await waitUntil("loopback listener", state: { server.description }) { server.feedURL != nil }
        let feedURL = try XCTUnwrap(server.feedURL)
        let bundle = try makeBundle(root: root, identifier: identifier, feedURL: feedURL)
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(Date(), forKey: "SULastCheckTime")
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: observer)
        XCTAssertTrue(observer.responds(to: NSSelectorFromString("updater:willScheduleUpdateCheckAfterDelay:")))
        XCTAssertTrue(
            updater!.automaticallyChecksForUpdates, "Sparkle must read this fixture's automatic-check preference")
        try updater!.start()

        func state() -> String {
            "session=\(String(describing: updater?.sessionInProgress)), "
                + "automatic=\(String(describing: updater?.automaticallyChecksForUpdates)), "
                + "suiteAutomatic=\(defaults.bool(forKey: "SUEnableAutomaticChecks")), "
                + "lastCheck=\(String(describing: updater?.lastUpdateCheckDate)), "
                + "scheduled=\(observer.scheduledSessions), finished=\(observer.finishedSessions), "
                + "errors=\(observer.errors), found=\(String(describing: standard.foundVersion)), "
                + "requests=\(server.requests), server=\(server.description)"
        }

        try await waitUntil("initial schedule", state: state) {
            observer.scheduledSessions.count == 1 && updater?.sessionInProgress == false
        }
        XCTAssertTrue(server.requests.isEmpty, "첫 예약은 아직 앱캐스트를 읽지 않음")
        XCTAssertEqual(observer.finishedSessions.count, 0)
        updater!.checkForUpdatesInBackground()
        try await waitUntil("fixture update found", state: state) { standard.foundState != nil }
        XCTAssertEqual(standard.foundState?.stage, .notDownloaded)
        XCTAssertEqual(standard.foundState?.userInitiated, false)
        XCTAssertEqual(standard.foundVersion, "2")
        XCTAssertEqual(updater?.sessionInProgress, true)
        XCTAssertEqual(observer.scheduledSessions.count, 1, "선택 대기 중에는 다음 예약이 없어야 함")

        driver.dismissPendingUpdate()

        try await waitUntil("schedule after banner dismissal", state: state) {
            observer.finishedSessions.count == 1 && observer.scheduledSessions.count == 2
        }
        XCTAssertEqual(observer.finishedSessions, [false], "종료 callback에서 실제 세션 종료 확인")
        XCTAssertEqual(observer.scheduledSessions, [false, false], "초기 예약과 닫은 뒤 예약을 각각 확인")
        XCTAssertTrue(observer.delays.allSatisfy { $0 > 0 })
        XCTAssertTrue(observer.errors.isEmpty)
        XCTAssertEqual(standard.dismissCount, 1)
        XCTAssertEqual(updater?.sessionInProgress, false)
        XCTAssertEqual(server.requests, ["/appcast.xml"])
    }

    func testBetaChangeHonorsAutomaticCheckingAfterAManualCheck() async throws {
        enum AutomaticChecks: CaseIterable {
            case off, on, turnOffBeforeChannelChange, turnOnThenOffAfterChannelChange
        }
        for preference in AutomaticChecks.allCases {
            let initiallyAutomatic = preference == .on || preference == .turnOffBeforeChannelChange
            let identifier = "EgasuTests.ChannelPreference." + UUID().uuidString
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
            let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
            let server = try SchedulingAppcastServer(includeBeta: true)
            defer {
                server.stop()
                defaults.removePersistentDomain(forName: identifier)
                try? FileManager.default.removeItem(at: root)
            }
            server.start()
            try await waitUntil("listener", state: { server.description }) { server.feedURL != nil }
            let bundle = try makeBundle(root: root, identifier: identifier, feedURL: XCTUnwrap(server.feedURL))
            defaults.set(initiallyAutomatic, forKey: "SUEnableAutomaticChecks")
            defaults.set(Date(), forKey: "SULastCheckTime")
            let standard = SchedulingUserDriver()
            standard.dismissOffers = true
            standard.allowsManualCheck = true
            let observer = SchedulingObserver()
            let driver = BannerUpdateUserDriver(
                standardDriver: standard, isBetaChannelEnabled: { observer.betaEnabled })
            observer.betaEnabled = false
            observer.channelDelegate = UpdaterChannelDelegate(defaults: defaults)
            let updater = SPUUpdater(
                hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: observer)
            try updater.start()
            let controller = UpdaterController(defaults: defaults)
            controller.attachStartedUpdater(updater, userDriver: driver)
            controller.onBetaChannelChange = { observer.betaEnabled = $0 }
            try await waitUntil("startup schedule", state: { server.description }) {
                !updater.sessionInProgress && observer.scheduledSessions.count + observer.skippedSchedules == 1
            }
            updater.checkForUpdates()
            try await waitUntil("manual check and schedule", state: { server.description }) {
                !updater.sessionInProgress && observer.finishedSessions.count == 1
                    && observer.scheduledSessions.count + observer.skippedSchedules >= 2
            }
            XCTAssertEqual(server.requests, ["/appcast.xml"])

            let previousSkipped = observer.skippedSchedules
            if preference == .turnOffBeforeChannelChange { controller.automaticallyChecksForUpdates = false }
            controller.betaChannelEnabled = true
            if preference == .turnOnThenOffAfterChannelChange {
                controller.automaticallyChecksForUpdates = true
                controller.automaticallyChecksForUpdates = false
            }

            XCTAssertEqual(updater.sessionInProgress, preference == .on, "\(preference)")
            if preference == .turnOffBeforeChannelChange || preference == .turnOnThenOffAfterChannelChange {
                try await waitUntil("Sparkle preference reschedule", state: { server.description }) {
                    observer.skippedSchedules > previousSkipped || server.requests.count > 1
                }
                XCTAssertEqual(server.requests.count, 1)
                guard server.requests.count == 1 else { continue }
            }
            if preference == .on {
                try await waitUntil("automatic beta check", state: { server.description }) {
                    observer.finishedSessions.count == 2
                }
            } else {
                XCTAssertEqual(server.requests, ["/appcast.xml"])
                standard.dismissOffers = false
                updater.checkForUpdates()
                try await waitUntil("manual beta offer", state: { server.description }) { standard.foundVersion == "3" }
                controller.betaChannelEnabled = false
                try await waitUntil("withdrawn beta offer", state: { server.description }) {
                    observer.finishedSessions.count == 2
                }
                XCTAssertTrue(driver.requiresFreshUpdater)
                XCTAssertEqual(server.requests.count, 2)
            }
            XCTAssertEqual(observer.selectedVersions, ["2", "3"])
        }
    }

    func testDisablingBetaDismissesThePendingOfferAndAFreshCheckSelectsStable() async throws {
        try await verifyBetaChange(disableDuringDiscovery: false)
    }

    func testBetaSelectedBeforeDisablingIsDismissedWithoutReachingTheStandardUI() async throws {
        try await verifyBetaChange(disableDuringDiscovery: true)
    }

    func testFreshUpdaterDropsAnInformationalBetaThatTheOldUpdaterStillResumes() async throws {
        for key in ["SUEnableDownloaderService", "SUEnableInstallerStatusService"] {
            let enabled = (Bundle.main.object(forInfoDictionaryKey: key) as? NSNumber)?.boolValue ?? false
            XCTAssertFalse(enabled, "The fixture requires in-process Sparkle services: \(key)")
            guard !enabled else { return }
        }
        let identifier = "EgasuTests.UpdaterBetaResume.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = SchedulingUserDriver()
        let observer = SchedulingObserver()
        defaults.set(true, forKey: UpdaterController.betaChannelDefaultsKey)
        observer.channelDelegate = UpdaterChannelDelegate(defaults: defaults)
        var driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { observer.betaEnabled })
        let server = try SchedulingAppcastServer(includeBeta: true, informationalBeta: true)
        var updater: SPUUpdater?
        defer {
            driver.dismissPendingUpdate()
            updater?.automaticallyChecksForUpdates = false
            updater = nil
            server.stop()
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        server.start()
        try await waitUntil("informational beta listener", state: { server.description }) { server.feedURL != nil }
        let bundle = try makeBundle(
            root: root, identifier: identifier, feedURL: XCTUnwrap(server.feedURL), automaticallyDownloadsUpdates: true
        )
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(Date(), forKey: "SULastCheckTime")
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: observer)
        XCTAssertTrue(updater!.automaticallyDownloadsUpdates)
        try updater!.start()
        func state() -> String {
            "session=\(String(describing: updater?.sessionInProgress)), beta=\(observer.betaEnabled), "
                + "selected=\(observer.selectedVersions), shown=\(standard.foundVersions), "
                + "scheduled=\(observer.scheduledSessions), finished=\(observer.finishedSessions), "
                + "errors=\(observer.errors), requests=\(server.requests)"
        }
        try await waitUntil("initial informational beta schedule", state: state) {
            observer.scheduledSessions.count == 1
        }
        updater!.checkForUpdatesInBackground()
        try await waitUntil("informational beta resumed into the UI", state: state) { standard.foundVersions == ["3"] }
        XCTAssertEqual(observer.selectedVersions, ["3", "3"], "자동 확인의 정보 전용 제안을 즉시 재개")
        XCTAssertEqual(standard.foundInformationOnly, true)
        XCTAssertEqual(standard.foundState?.stage, .notDownloaded)
        XCTAssertEqual(standard.foundState?.userInitiated, false)
        XCTAssertTrue(observer.finishedSessions.isEmpty, "자동 확인에서 즉시 재개할 때 중간 종료 callback 생략")
        XCTAssertEqual(server.requests, ["/appcast.xml"])

        observer.betaEnabled = false
        defaults.set(false, forKey: UpdaterController.betaChannelDefaultsKey)
        XCTAssertTrue(driver.dismissDisallowedUpdate())
        try await waitUntil("informational beta dismissed", state: state) {
            observer.finishedSessions.count == 1 && observer.scheduledSessions.count == 2
        }
        XCTAssertTrue(driver.requiresFreshUpdater)
        updater!.checkForUpdatesInBackground()
        try await waitUntil("old updater resumed the disallowed beta", state: state) {
            observer.finishedSessions.count == 2 && observer.scheduledSessions.count == 3
        }
        XCTAssertEqual(observer.selectedVersions, ["3", "3", "3"])
        XCTAssertEqual(standard.foundVersions, ["3"], "재개된 베타는 표준 UI에 다시 전달하지 않음")
        XCTAssertEqual(server.requests, ["/appcast.xml"], "기존 엔진은 피드 조회 없이 보관된 제안 재개")

        updater!.automaticallyChecksForUpdates = false
        updater!.checkForUpdatesInBackground()
        try await waitUntil("resume with automatic checks off", state: state) { observer.finishedSessions.count == 3 }
        XCTAssertEqual(observer.selectedVersions, ["3", "3", "3", "3"])
        XCTAssertEqual(server.requests, ["/appcast.xml"])

        // 새 엔진의 안정 버전은 자동 다운로드하지 않고 선택 결과만 확인.
        updater!.automaticallyDownloadsUpdates = false
        updater = nil
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { observer.betaEnabled })
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: observer)
        XCTAssertFalse(updater!.automaticallyDownloadsUpdates)
        try updater!.start()
        try await waitUntil("fresh informational fixture updater scheduled", state: state) {
            observer.scheduledSessions.count == 4 && updater?.sessionInProgress == false
        }
        updater!.checkForUpdatesInBackground()
        try await waitUntil("fresh updater selected stable", state: state) { standard.foundVersion == "2" }
        XCTAssertEqual(observer.selectedVersions, ["3", "3", "3", "3", "2"])
        XCTAssertEqual(standard.foundVersions, ["3", "2"])
        XCTAssertEqual(standard.foundInformationOnly, false)
        XCTAssertEqual(standard.foundState?.stage, .notDownloaded)
        XCTAssertEqual(server.requests, ["/appcast.xml", "/appcast.xml"])
        driver.dismissPendingUpdate()
        try await waitUntil("fresh stable session finished", state: state) {
            observer.finishedSessions.count == 4 && observer.scheduledSessions.count == 5
        }
        XCTAssertEqual(observer.finishedSessions, [false, false, false, false])
        XCTAssertEqual(observer.scheduledSessions, [false, false, false, false, false])
        XCTAssertTrue(observer.errors.isEmpty)
    }

    private func verifyBetaChange(disableDuringDiscovery: Bool) async throws {
        for key in ["SUEnableDownloaderService", "SUEnableInstallerStatusService"] {
            let enabled = (Bundle.main.object(forInfoDictionaryKey: key) as? NSNumber)?.boolValue ?? false
            XCTAssertFalse(enabled, "The fixture requires in-process Sparkle services: \(key)")
            guard !enabled else { return }
        }
        let identifier = "EgasuTests.UpdaterBeta.\(UUID().uuidString)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: identifier))
        let standard = SchedulingUserDriver()
        let observer = SchedulingObserver()
        observer.disableBetaWhenFound = disableDuringDiscovery
        var driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { observer.betaEnabled })
        let server = try SchedulingAppcastServer(includeBeta: true)
        var updater: SPUUpdater?
        defer {
            driver.dismissPendingUpdate()
            updater?.automaticallyChecksForUpdates = false
            updater = nil
            server.stop()
            defaults.removePersistentDomain(forName: identifier)
            try? FileManager.default.removeItem(at: root)
        }
        server.start()
        try await waitUntil("beta fixture listener", state: { server.description }) { server.feedURL != nil }
        let bundle = try makeBundle(root: root, identifier: identifier, feedURL: XCTUnwrap(server.feedURL))
        defaults.set(true, forKey: "SUEnableAutomaticChecks")
        defaults.set(Date(), forKey: "SULastCheckTime")
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: observer)
        try updater!.start()
        func state() -> String {
            "session=\(String(describing: updater?.sessionInProgress)), beta=\(observer.betaEnabled), "
                + "selected=\(observer.selectedVersions), shown=\(standard.foundVersions), "
                + "scheduled=\(observer.scheduledSessions), finished=\(observer.finishedSessions), "
                + "errors=\(observer.errors), requests=\(server.requests)"
        }
        try await waitUntil("initial beta schedule", state: state) { observer.scheduledSessions.count == 1 }
        updater!.checkForUpdatesInBackground()
        if !disableDuringDiscovery {
            try await waitUntil("beta offer shown", state: state) { standard.foundVersions == ["3"] }
            XCTAssertTrue(observer.betaEnabled)
            XCTAssertEqual(updater?.sessionInProgress, true)
            observer.betaEnabled = false
            XCTAssertTrue(driver.dismissDisallowedUpdate())
        }
        try await waitUntil("beta offer withdrawn", state: state) {
            observer.finishedSessions.count == 1 && observer.scheduledSessions.count == 2
        }
        XCTAssertEqual(observer.selectedVersions, ["3"])
        XCTAssertFalse(observer.betaEnabled)
        XCTAssertEqual(standard.foundVersions, disableDuringDiscovery ? [] : ["3"])
        XCTAssertEqual(observer.finishedSessions, [false])
        XCTAssertEqual(observer.scheduledSessions, [false, false])
        XCTAssertEqual(standard.dismissCount, 1)
        XCTAssertTrue(observer.errors.isEmpty)
        XCTAssertTrue(driver.requiresFreshUpdater, "세션 정리 이후에도 베타 재개 대상 폐기 요청 유지")

        updater = nil
        driver = BannerUpdateUserDriver(standardDriver: standard, isBetaChannelEnabled: { observer.betaEnabled })
        XCTAssertFalse(driver.requiresFreshUpdater)
        updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: observer)
        try updater!.start()
        try await waitUntil("replacement updater scheduled", state: state) {
            observer.scheduledSessions.count == 3 && updater?.sessionInProgress == false
        }
        updater!.checkForUpdatesInBackground()
        try await waitUntil("fresh stable offer", state: state) { standard.foundVersion == "2" }
        XCTAssertEqual(observer.selectedVersions, ["3", "2"])
        XCTAssertEqual(standard.foundVersions, disableDuringDiscovery ? ["2"] : ["3", "2"])
        XCTAssertEqual(standard.foundState?.stage, .notDownloaded)
        XCTAssertEqual(server.requests, ["/appcast.xml", "/appcast.xml"])
        driver.dismissPendingUpdate()
        try await waitUntil("stable session finished", state: state) {
            observer.finishedSessions.count == 2 && observer.scheduledSessions.count == 4
        }
        XCTAssertEqual(observer.finishedSessions, [false, false])
        XCTAssertTrue(observer.errors.isEmpty)
    }

    private func makeBundle(
        root: URL, identifier: String, feedURL: URL, automaticallyDownloadsUpdates: Bool = false
    ) throws -> Bundle {
        let bundleURL = root.appendingPathComponent("Fixture.app")
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleName": "Updater Scheduling Fixture",
            "CFBundlePackageType": "APPL",
            "CFBundleVersion": "1",
            "CFBundleShortVersionString": "1.0",
            "SUFeedURL": feedURL.absoluteString,
            "SUEnableAutomaticChecks": false,
            "SUAllowsAutomaticUpdates": automaticallyDownloadsUpdates,
            "SUAutomaticallyUpdate": automaticallyDownloadsUpdates,
            "SURequireSignedFeed": false,
            "SUScheduledCheckInterval": 3600,
            "SUPublicEDKey": Data(repeating: 1, count: 32).base64EncodedString()
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        return try XCTUnwrap(Bundle(url: bundleURL))
    }

    private func waitUntil(
        _ phase: String, state: () -> String, file: StaticString = #filePath, line: UInt = #line,
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Sparkle timed out during \(phase): \(state())", file: file, line: line)
        throw URLError(.timedOut)
    }
}

@MainActor
private final class SchedulingObserver: NSObject, SPUUpdaterDelegate {
    var betaEnabled = true
    var channelDelegate: UpdaterChannelDelegate?
    var disableBetaWhenFound = false
    var selectedVersions: [String] = []
    var scheduledSessions: [Bool] = []
    var skippedSchedules = 0
    var finishedSessions: [Bool] = []
    var delays: [TimeInterval] = []
    var errors: [Error] = []

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        channelDelegate?.allowedChannels(for: updater) ?? (betaEnabled ? ["beta"] : [])
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try channelDelegate?.updater(updater, mayPerform: updateCheck)
    }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        selectedVersions.append(item.versionString)
        // 채널 필터 완료 뒤, user driver에 넘기기 직전의 설정 변경 재현.
        if disableBetaWhenFound, item.channel == "beta" { betaEnabled = false }
    }

    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {
        skippedSchedules += 1
    }

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {
        scheduledSessions.append(updater.sessionInProgress)
        delays.append(delay)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        finishedSessions.append(updater.sessionInProgress)
        if let error { errors.append(error) }
    }
}

private final class SchedulingAppcastServer: @unchecked Sendable {
    private let listener: NWListener
    private let includeBeta: Bool
    private let informationalBeta: Bool
    private let queue = DispatchQueue(label: "EgasuTests.UpdaterAppcast")
    private let lock = NSLock()
    private var port: UInt16?
    private var paths: [String] = []
    private var failure: String?
    private var connections: [NWConnection] = []
    var requests: [String] { lock.withLock { paths } }
    var description: String {
        lock.withLock { "port=\(String(describing: port)), failure=\(String(describing: failure))" }
    }
    var feedURL: URL? { lock.withLock { port.flatMap { URL(string: "http://127.0.0.1:\($0)/appcast.xml") } } }

    init(includeBeta: Bool = false, informationalBeta: Bool = false) throws {
        self.includeBeta = includeBeta
        self.informationalBeta = informationalBeta
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: lock.withLock { port = listener.port?.rawValue }
            case let .failed(error):
                lock.withLock { failure = error.localizedDescription }
                XCTFail("Loopback fixture failed: \(error)")
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            lock.withLock { connections.append(connection) }
            connection.start(queue: queue)
            receive(connection, data: Data())
        }
    }

    func start() { listener.start(queue: queue) }
    func stop() {
        listener.cancel()
        let active = lock.withLock {
            let active = connections; connections = []; return active
        }
        active.forEach { $0.cancel() }
    }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] chunk, _, complete, error in
            guard let self else { connection.cancel(); return }
            let received = data + (chunk ?? Data())
            guard let text = String(data: received, encoding: .utf8), text.contains("\r\n\r\n") else {
                if complete || error != nil { connection.cancel() } else { receive(connection, data: received) }
                return
            }
            let path =
                text.components(separatedBy: "\r\n")[0].split(separator: " ").dropFirst().first.map(String.init) ?? ""
            lock.withLock { paths.append(path) }
            guard path == "/appcast.xml", let feedURL else {
                XCTFail("Unexpected fixture request; update archives must never be downloaded: \(path)")
                connection.cancel()
                return
            }
            let body = appcast(feedURL: feedURL)
            let header =
                "HTTP/1.1 200 OK\r\nContent-Type: application/xml\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            connection.send(
                content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func appcast(feedURL: URL) -> Data {
        let archiveURL = feedURL.deletingLastPathComponent().appendingPathComponent("forbidden-update.zip")
            .absoluteString
        let betaContent =
            informationalBeta
            ? """
              <sparkle:version>3</sparkle:version><sparkle:shortVersionString>3.0-beta.1</sparkle:shortVersionString>
              <link>\(feedURL.deletingLastPathComponent().appendingPathComponent("beta-information").absoluteString)</link>
            """
            : """
              <enclosure url="\(archiveURL)" sparkle:version="3" sparkle:shortVersionString="3.0-beta.1"
                length="1" type="application/octet-stream" />
            """
        let betaItem =
            includeBeta
            ? """
            <item><title>Fixture Beta 3</title><sparkle:channel>beta</sparkle:channel>
              \(betaContent)
            </item>
            """ : ""
        let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
              <channel><title>Updater Scheduling Fixture</title><item>
                <title>Fixture 2</title>
                <enclosure url="\(archiveURL)" sparkle:version="2"
                  sparkle:shortVersionString="2.0" length="1" type="application/octet-stream" />
              </item>\(betaItem)</channel>
            </rss>
            """
        return Data(xml.utf8)
    }
}

@MainActor
private final class SchedulingUserDriver: NSObject, SPUUserDriver {
    var foundState: SPUUserUpdateState?
    var foundVersion: String?
    var foundInformationOnly: Bool?
    var foundVersions: [String] = []
    var dismissCount = 0
    var dismissOffers = false
    var allowsManualCheck = false

    func showUpdateFound(
        with appcastItem: SUAppcastItem, state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        foundState = state
        foundVersion = appcastItem.versionString
        foundInformationOnly = appcastItem.isInformationOnlyUpdate
        foundVersions.append(appcastItem.versionString)
        if dismissOffers { reply(.dismiss) }
    }

    func dismissUpdateInstallation() { dismissCount += 1 }
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        XCTFail("The isolated bundle already enables automatic checks")
    }
    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        if !allowsManualCheck { XCTFail("The fixture uses a scheduled check"); cancellation() }
    }
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) { XCTFail("No release notes in fixture") }
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) { XCTFail("Unexpected release notes request") }
    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        XCTFail("Fixture update not found: \(error)"); acknowledgement()
    }
    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        XCTFail("Unexpected updater error: \(error)"); acknowledgement()
    }
    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        XCTFail("Update archive downloads are forbidden"); cancellation()
    }
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) { XCTFail("Unexpected download") }
    func showDownloadDidReceiveData(ofLength length: UInt64) { XCTFail("Unexpected download") }
    func showDownloadDidStartExtractingUpdate() { XCTFail("Update extraction is forbidden") }
    func showExtractionReceivedProgress(_ progress: Double) { XCTFail("Update extraction is forbidden") }
    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        XCTFail("Update installation is forbidden"); reply(.dismiss)
    }
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool, retryTerminatingApplication: @escaping () -> Void
    ) { XCTFail("Update installation is forbidden") }
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        XCTFail("Update installation is forbidden"); acknowledgement()
    }
}
