import Foundation
import XCTest

@testable import Egasu

@MainActor
final class QwenCloudAccountIsolationTests: XCTestCase {
    func testCLIReadAfterExternalSignInDisplaysTheNewAccountsUsage() async throws {
        let fixture = try fixture()
        try fixture.signIn(as: "first")
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertEqual(fixture.card.used, 17)
        let reader = UsageReader(userDefaults: fixture.defaults, providers: [fixture.provider])
        let first = try await reader.read(providerID: "qwencloud")
        XCTAssertEqual(try weeklyUsage(in: first), 17)

        try fixture.signIn(as: "second")
        let second = try await reader.read(providerID: "qwencloud")
        XCTAssertEqual(try weeklyUsage(in: second), 81)
    }

    func testAppDropsThePreviousAccountsCardWhenNewLoginCannotFetch() async throws {
        let fixture = try fixture()
        try fixture.signIn(as: "first")
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertTrue(fixture.card.hasData)
        XCTAssertEqual(fixture.card.used, 17)

        try Data().write(to: fixture.folder.appendingPathComponent("offline"))
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertEqual(fixture.card.used, 17)

        try fixture.signIn(as: "second")
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertFalse(fixture.card.hasData, "새 로그인의 조회 실패 시 이전 계정의 주간 사용률이 표시됨")
    }

    func testWhileKeychainIsSelectedEveryCLIReadQueriesTheCurrentAccount() async throws {
        let fixture = try fixture(keychain: true)
        let cliAccount = fixture.folder.appendingPathComponent("fixture-keychain-account")
        try Data("first".utf8).write(to: cliAccount)
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertEqual(fixture.card.used, 17)
        let reader = UsageReader(userDefaults: fixture.defaults, providers: [fixture.provider])
        try Data("second".utf8).write(to: cliAccount)
        let second = try await reader.read(providerID: "qwencloud")
        XCTAssertEqual(try weeklyUsage(in: second), 81)
        try Data().write(to: fixture.folder.appendingPathComponent("offline"))
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertFalse(fixture.card.hasData)
    }

    func testAccountSwitchDuringCLICommandDiscardsThePreviousResult() async throws {
        let fixture = try fixture()
        try fixture.signIn(as: "second")
        try FileManager.default.moveItem(
            at: fixture.folder.appendingPathComponent("credentials"),
            to: fixture.folder.appendingPathComponent("next-login"))
        try fixture.signIn(as: "first")
        let interrupted = await fixture.provider.refresh()
        XCTAssertNotNil(interrupted.refreshFailure)
        _ = await fixture.store.refresh(providerID: "qwencloud", force: true)
        XCTAssertEqual(fixture.card.used, 81)
    }

    private func weeklyUsage(in result: UsageReadResult) throws -> Double? {
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: result.data) as? [String: Any])
        let providers = try XCTUnwrap(payload["providers"] as? [String: Any])
        let qwen = providers["qwencloud"] as? [String: Any]
        let resources = qwen?["resources"] as? [String: Any]
        return (resources?["weekly"] as? [String: Any])?["used"] as? Double
    }

    private struct Fixture {
        let folder: URL
        let defaults: UserDefaults
        let provider: QwenCloudProvider
        let store: WidgetDataStore

        @MainActor var card: WidgetData { store.data(for: provider.widgetDescriptors[0]) }

        func signIn(as account: String) throws {
            let envelope = #"{"version":1,"salt":"fixture","nonce":"fixture","ciphertext":"\#(account)"}"#
            try Data(envelope.utf8).write(to: folder.appendingPathComponent("credentials"), options: .atomic)
        }
    }

    private func fixture(keychain: Bool = false) throws -> Fixture {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: folder) }
        let suite = "QwenCloudAccountIsolationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let executable = folder.appendingPathComponent("qwencloud")
        let script = #"""
            #!/bin/sh
            test ! -f "$QWENCLOUD_CONFIG_DIR/offline" || exit 3
            account="$QWENCLOUD_CONFIG_DIR/credentials"
            if test "$QWENCLOUD_KEYRING" = "on"; then
                account="$QWENCLOUD_CONFIG_DIR/fixture-keychain-account"
            fi
            case "$(cat "$account")" in
                *first*) used=17 ;;
                *second*) used=81 ;;
                *) exit 3 ;;
            esac
            if test -f "$QWENCLOUD_CONFIG_DIR/next-login"; then
                mv "$QWENCLOUD_CONFIG_DIR/next-login" "$QWENCLOUD_CONFIG_DIR/credentials"
            fi
            printf '{"individual":{"edition":"individual","status":"active","weeklyCredits":{"usedPct":%s}}}\n' "$used"
            """#
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let cli = QwenCloudCLI(
            environment: {
                [
                    "HOME": folder.path, "PATH": folder.path + ":/usr/bin:/bin",
                    "QWENCLOUD_CONFIG_DIR": folder.path, "QWENCLOUD_KEYRING": keychain ? "on" : "off"
                ]
            },
            hasKeychainItem: { keychain }
        )
        let provider = QwenCloudProvider(cli: cli)
        let store = WidgetDataStore(
            registry: .from([provider]), providers: [provider], cache: .init(userDefaults: defaults), defaults: defaults
        )
        return Fixture(folder: folder, defaults: defaults, provider: provider, store: store)
    }
}
