import Foundation
import XCTest
@testable import Egasu

final class StorageNamespaceTests: XCTestCase {
    func testProductionAndStandardDevelopmentNamesStayStable() {
        XCTAssertEqual(StorageNamespace(bundleIdentifier: nil).name, "egasu")
        XCTAssertEqual(StorageNamespace(bundleIdentifier: Self.production).name, "egasu")
        XCTAssertEqual(StorageNamespace(bundleIdentifier: Self.production + ".dev").name, "egasu.dev")
        XCTAssertEqual(
            AccountCredentialVault.service(
                family: "claude", profileID: "p1",
                namespace: StorageNamespace(bundleIdentifier: Self.production + ".dev")),
            "egasu.dev Account Authentication v1 claude p1"
        )
    }

    func testDistinctFullIdentifiersDoNotShareANamespace() {
        for (first, second) in Self.previouslyCollidingIdentifiers {
            XCTAssertNotEqual(
                StorageNamespace(bundleIdentifier: first).name,
                StorageNamespace(bundleIdentifier: second).name,
                "Different settings domains must keep separate storage: \(first), \(second)"
            )
        }
    }

    func testCustomIdentifierIsStableWithoutTrimmingOrCaseFolding() {
        let identifier = "com.example.fixture"
        let namespace = StorageNamespace(bundleIdentifier: identifier)

        XCTAssertEqual(namespace, StorageNamespace(bundleIdentifier: identifier))
        XCTAssertNotEqual(namespace, StorageNamespace(bundleIdentifier: identifier + " "))
        XCTAssertNotEqual(namespace, StorageNamespace(bundleIdentifier: identifier.uppercased()))
        XCTAssertFalse(namespace.isProduction)
    }

    func testArbitraryDomainsStayWithinTheSupportAndConfigRoots() {
        let files = NamespaceFixtureFileManager()
        let supportRoot = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let configRoot = URL(fileURLWithPath: "/namespace-fixture/.config", isDirectory: true)
        for identifier in [
            "../../../../../outside", "/../../outside", "x/../egasu", "..", "a/b", "한글",
            String(repeating: "x", count: 1_024)
        ] {
            let namespace = StorageNamespace(bundleIdentifier: identifier)
            let support = namespace.applicationSupportDirectory(fileManager: files).standardizedFileURL
            let config = URL(
                fileURLWithPath: String(namespace.configPath("zai.json").dropFirst(2)),
                relativeTo: URL(fileURLWithPath: "/namespace-fixture", isDirectory: true)
            ).standardizedFileURL

            XCTAssertEqual(support.deletingLastPathComponent(), supportRoot)
            XCTAssertEqual(config.deletingLastPathComponent().deletingLastPathComponent(), configRoot)
            XCTAssertEqual(support.lastPathComponent, namespace.name)
            XCTAssertLessThanOrEqual(namespace.name.utf8.count, 255)
        }
    }

    func testSeparateDomainsKeepConfigAndVaultServiceNamesSeparate() {
        for (first, second) in Self.previouslyCollidingIdentifiers {
            let firstNamespace = StorageNamespace(bundleIdentifier: first)
            let secondNamespace = StorageNamespace(bundleIdentifier: second)

            XCTAssertNotEqual(
                firstNamespace.configPath("openrouter.json"), secondNamespace.configPath("openrouter.json"))
            XCTAssertNotEqual(
                AccountCredentialVault.service(family: "claude", profileID: "same-profile", namespace: firstNamespace),
                AccountCredentialVault.service(family: "claude", profileID: "same-profile", namespace: secondNamespace)
            )
        }
    }

    func testSuiteOverrideRetainsItsRawValueAndExistingPrecedence() {
        let executable = URL(fileURLWithPath: "/namespace-fixture/egasu")
        let primary = "../custom/domain"
        let legacy = "dev"
        let selected = AppBundleLocator.locate(
            executableURL: executable,
            environment: ["EGASU_DEFAULTS_SUITE": primary, "OPENUSAGE_DEFAULTS_SUITE": legacy]
        )
        let fallback = AppBundleLocator.locate(
            executableURL: executable,
            environment: ["EGASU_DEFAULTS_SUITE": "", "OPENUSAGE_DEFAULTS_SUITE": legacy]
        )

        XCTAssertEqual(selected.bundleIdentifier, primary)
        XCTAssertEqual(fallback.bundleIdentifier, legacy)
        XCTAssertNotEqual(StorageNamespace(bundleIdentifier: selected.bundleIdentifier).name, "egasu")
        XCTAssertNotEqual(StorageNamespace(bundleIdentifier: fallback.bundleIdentifier).name, "egasu.dev")
    }

    private static let production = "com.kimchanhyung98.openusage"
    private static var previouslyCollidingIdentifiers: [(String, String)] {
        [
            ("dev", production + ".dev"),
            ("com.example", production + ".com.example"),
            ("com.example", "com.example "),
            ("Dev", "dev")
        ]
    }
}

private final class NamespaceFixtureFileManager: FileManager, @unchecked Sendable {
    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask)
        -> [URL]
    {
        [URL(fileURLWithPath: "/namespace-fixture/Application Support", isDirectory: true)]
    }
}
