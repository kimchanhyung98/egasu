import SwiftUI
import XCTest

@testable import Egasu

@MainActor
final class QwenCloudProviderTests: XCTestCase {
    func testMonthlyCreditsUseTheCreditResetInsteadOfSubscriptionExpiry() throws {
        let usage = try QwenCloudUsage.parse(
            payload(#""monthlyCredits":{"usedPct":65.25,"remainingPct":34.75,"resetTime":"2027-01-01T00:00:00.000Z"}"#)
        )
        XCTAssertEqual(usage.plan, "Lite")
        XCTAssertEqual(
            usage.line,
            .progress(
                label: "Monthly", used: 65.25, limit: 100, format: .percent,
                resetsAt: EgasuISO8601.date(from: "2027-01-01T00:00:00Z")
            ))
    }

    func testWeekAndMonthBoundariesAndMissingReset() throws {
        let week = try QwenCloudUsage.parse(payload(#""weeklyCredits":{"usedPct":100,"remainingPct":0}"#))
        XCTAssertEqual(
            week.line,
            .progress(
                label: "Weekly", used: 100, limit: 100, format: .percent,
                periodDurationMs: MetricPeriod.weekMs))
        let month = try QwenCloudUsage.parse(payload(#""monthlyCredits":{"usedPct":0,"remainingPct":100}"#))
        XCTAssertEqual(month.line, .progress(label: "Monthly", used: 0, limit: 100, format: .percent))
        let remaining = try QwenCloudUsage.parse(payload(#""weeklyCredits":{"remainingPct":27.5}"#))
        XCTAssertEqual(
            remaining.line,
            .progress(
                label: "Weekly", used: 72.5, limit: 100, format: .percent,
                periodDurationMs: MetricPeriod.weekMs))
    }

    func testMissingAndInvalidUsageAreDistinctFromZero() {
        for fields in [#""weeklyCredits":{"usedPct":null,"remainingPct":null}"#, #""tiers":[]"#] {
            XCTAssertThrowsError(try QwenCloudUsage.parse(payload(fields))) {
                XCTAssertEqual($0 as? QwenCloudError, .noUsage)
            }
        }
        for fields in [
            #""monthlyCredits":{"usedPct":true}"#, #""weeklyCredits":{"usedPct":-1}"#,
            #""monthlyCredits":{"usedPct":101}"#, #""monthlyCredits":{"usedPct":22,"resetTime":"yesterday"}"#
        ] {
            XCTAssertThrowsError(try QwenCloudUsage.parse(payload(fields))) {
                XCTAssertEqual($0 as? QwenCloudError, .invalidResponse)
            }
        }
        XCTAssertThrowsError(try QwenCloudUsage.parse(Data(#"{"team":{"status":"active"}}"#.utf8))) {
            XCTAssertEqual($0 as? QwenCloudError, .invalidResponse)
        }
    }

    func testPublicCatalogAndStatusCommandUsingLocalExecutable() async throws {
        let folder = try fixtureDirectory()
        let executable = folder.appendingPathComponent("qwencloud")
        let marker = folder.appendingPathComponent("queried")
        let response = String(decoding: payload(#""weeklyCredits":{"usedPct":0,"remainingPct":100}"#), as: UTF8.self)
        let script = """
            #!/bin/sh
            test "$*" = "subscription tokenplan status --edition individual --format json" || exit 4
            touch "$HOME/queried"
            echo 'fixture stderr' >&2
            echo '\(response)'
            """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cli = fixtureCLI(folder, hasKeychainItem: { false })
        let runtime = QwenCloudProvider(cli: cli)
        let absent = await runtime.hasLocalCredentials()
        XCTAssertFalse(absent)
        try Data(#"{"version":1,"salt":"s","nonce":"n","ciphertext":"c"}"#.utf8)
            .write(to: folder.appendingPathComponent("credentials"))
        let present = await runtime.hasLocalCredentials()
        XCTAssertTrue(present)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        let snapshot = await runtime.refresh()
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertNil(snapshot.errorCategory)
        XCTAssertEqual(snapshot.liveQuotaObservedAt, snapshot.refreshedAt)
        XCTAssertEqual(
            snapshot.line(label: "Weekly"),
            .progress(
                label: "Weekly", used: 0, limit: 100, format: .percent, periodDurationMs: MetricPeriod.weekMs
            ))
        XCTAssertNotNil(ProviderCatalog.make().first { $0.provider.id == "qwencloud" })
        XCTAssertEqual(runtime.widgetDescriptors.map(\.metricLabel), ["Weekly", "Monthly"])
    }

    func testMissingCLIAndCredentialAndKeyringOptOut() async throws {
        let folder = try fixtureDirectory()
        let cli = fixtureCLI(folder, hasKeychainItem: { true })
        let missing = await QwenCloudProvider(cli: cli).refresh()
        XCTAssertEqual(missing.refreshFailure?.message, QwenCloudError.cliMissing.rawValue)
        let executable = folder.appendingPathComponent("qwencloud")
        try "#!/bin/sh\nexit 2".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let hasKeychain = await QwenCloudProvider(cli: cli).hasLocalCredentials()
        XCTAssertTrue(hasKeychain)
        let disabled = fixtureCLI(folder, keyring: "off", hasKeychainItem: { true })
        let hasDisabled = await QwenCloudProvider(cli: disabled).hasLocalCredentials()
        XCTAssertFalse(hasDisabled)
        let missingCredentials = await QwenCloudProvider(cli: disabled).refresh()
        XCTAssertEqual(missingCredentials.errorCategory, .notLoggedIn)
        let cliRefusedLogin = await QwenCloudProvider(cli: cli).refresh()
        XCTAssertEqual(cliRefusedLogin.errorCategory, .notLoggedIn)
    }

    func testLegacyFileRemainsIntactAcrossPlaintextAndKeychainFallbacks() async throws {
        let folder = try fixtureDirectory()
        let credential = folder.appendingPathComponent("credentials")
        let original = Data(#"{"access_token":"fixture","expires_at":"2025-01-01T00:00:00Z"}"#.utf8)
        try original.write(to: credential)
        let executable = folder.appendingPathComponent("qwencloud")
        try "#!/bin/sh\ntouch \"$HOME/queried\"".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        for (mode, keychain) in [("plaintext", false as Bool?), ("off", false), ("", nil), ("", true)] {
            let cli = fixtureCLI(folder, keyring: mode, hasKeychainItem: { keychain })
            let provider = QwenCloudProvider(cli: cli)
            let detectable = await provider.hasLocalCredentials()
            XCTAssertFalse(detectable)
            let snapshot = await provider.refresh()
            XCTAssertEqual(snapshot.refreshFailure?.message, QwenCloudError.unsafeCredentialFile.rawValue)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("queried").path))
            XCTAssertEqual(try Data(contentsOf: credential), original)
        }
    }

    func testFailedUsageLookupIsDistinguishedFromAMissingWindow() {
        for (code, error) in [
            ("MissingUsageWindow", QwenCloudError.noUsage), ("AUTH_REQUIRED", .notLoggedIn),
            ("NETWORK_ERROR", .network), ("PROTOCOL_ERROR", .invalidResponse), ("SERVICE_UNAVAILABLE", .commandFailed)
        ] {
            let fields =
                #""diagnostics":[{"api":"zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage","errorCode":"\#(code)"}]"#
            XCTAssertThrowsError(try QwenCloudUsage.parse(payload(fields))) {
                XCTAssertEqual($0 as? QwenCloudError, error)
            }
        }
    }

    func testNoPersonalPlanAndCLIFailureAreSeparateAndNeverExposeOutput() async throws {
        let folder = try fixtureDirectory()
        let executable = folder.appendingPathComponent("qwencloud")
        let cli = fixtureCLI(folder, hasKeychainItem: { true })
        for (exitCode, output, error) in [
            (0, #"{"individual":{"edition":"individual","status":"not_subscribed"}}"#, QwenCloudError.noSubscription),
            (0, "not JSON", .invalidResponse), (3, "sensitive fixture", .network),
            (4, "sensitive fixture", .commandFailed)
        ] {
            try "#!/bin/sh\necho '\(output)'\nexit \(exitCode)".write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            let snapshot = await QwenCloudProvider(cli: cli).refresh()
            XCTAssertEqual(snapshot.refreshFailure?.message, error.rawValue)
        }
    }

    private func fixtureDirectory() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func fixtureCLI(
        _ folder: URL, keyring: String = "", hasKeychainItem: @escaping @Sendable () -> Bool?
    ) -> QwenCloudCLI {
        QwenCloudCLI(
            environment: {
                [
                    "HOME": folder.path, "PATH": folder.path + ":/usr/bin:/bin",
                    "QWENCLOUD_CONFIG_DIR": folder.path, "QWENCLOUD_KEYRING": keyring
                ]
            },
            hasKeychainItem: hasKeychainItem
        )
    }
}

extension DashboardSnapshotTests {
    func testQwenCloudCardDisplaysOnlyTheReportedCreditWindow() throws {
        let runtime = QwenCloudProvider()
        let reset = EgasuISO8601.string(from: Date().addingTimeInterval(8 * 86_400))
        let samples = [
            ("Weekly", 0, #""weeklyCredits":{"usedPct":0}"#),
            ("Monthly", 100, #""monthlyCredits":{"usedPct":100,"resetTime":"\#(reset)"}"#)
        ]
        for (label, used, fields) in samples {
            let usage = try QwenCloudUsage.parse(payload(fields))
            let snapshot = ProviderSnapshot.make(
                provider: runtime.provider, plan: usage.plan, lines: [usage.line], refreshedAt: Date())
            let rows = runtime.widgetDescriptors.map { descriptor in
                let data = WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
                return DashboardLine(descriptor: descriptor, data: data)
            }.filter(\.isVisible)
            XCTAssertEqual(rows.map(\.descriptor.metricLabel), [label])
            XCTAssertEqual(rows.first?.data.used, Double(used))
            let account = DashboardAccount(
                provider: runtime.provider, providerName: "QwenCloud", name: nil, lines: rows)
            let family = DashboardFamily(
                id: "qwencloud", provider: runtime.provider, displayName: "QwenCloud", accounts: [account])
            let card = DashboardProviderSection(family: family) { DashboardAccountRows(account: $0, plan: usage.plan) }
            let image = try L10n.withLanguage(.korean) {
                try render(card, appearance: .dark, name: "qwencloud-\(label.lowercased())-\(used)")
            }
            XCTAssertGreaterThan(image.size.height, DashboardGrid.rowHeight)
        }
    }
}

private func payload(_ fields: String) -> Data {
    Data(
        #"{"individual":{"edition":"individual","status":"active","name":"Lite","endAt":"2035-06-01T00:00:00Z",\#(fields)}}"#
            .utf8)
}
