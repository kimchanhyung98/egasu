import Foundation
import XCTest

@testable import Egasu

final class ClaudeRotationMetadataTests: XCTestCase {
    private let credential = """
        {"claudeAiOauth":{"accessToken":"a1","refreshToken":"r1","expiresAt":1,"extra":["active"]},
         "mcpOAuth":{"server":"mcp1"}}
        """

    func testRotationPreservesConcurrentMCPAndOAuthMetadataChanges() throws {
        let service = "Claude Code-credentials"
        let keychain = ServiceKeychain(currentUserValues: [service: credential])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain, allowsDesktopFallback: false)
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "a2"
        updated.oauth.refreshToken = "r2"
        updated.oauth.expiresAt = 2
        keychain.currentUserValues[service] =
            credential
            .replacingOccurrences(of: "mcp1", with: "mcp2")
            .replacingOccurrences(of: "active", with: "changed")

        XCTAssertTrue(try store.save(updated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let value = try XCTUnwrap(keychain.currentUserValues[service])
        let saved = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(value))
        XCTAssertEqual(saved["mcpOAuth"] as? [String: String], ["server": "mcp2"])
        let oauth = try XCTUnwrap(saved["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["extra"] as? [String], ["changed"])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(value)?.claudeAiOauth, updated.oauth)
    }

    func testHexFileRotationKeepsExtendedFieldsAndOtherScopesIntact() throws {
        let directory = "/fixture/claude"
        let path = directory + "/.credentials.json"
        let files = FakeFiles([path: "0x" + credential.utf8.map { String(format: "%02x", $0) }.joined()])
        let keychain = ServiceKeychain(currentUserValues: ["Claude Code-credentials": "other account"])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: files, keychain: keychain,
            scope: .configDir(path: directory, keychainLiteral: directory))
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "a2"

        XCTAssertTrue(try store.save(updated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let saved = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(try files.readText(path)))
        XCTAssertEqual(saved["mcpOAuth"] as? [String: String], ["server": "mcp1"])
        let oauth = try XCTUnwrap(saved["claudeAiOauth"] as? [String: Any])
        XCTAssertEqual(oauth["extra"] as? [String], ["active"])
        XCTAssertEqual(oauth["refreshToken"] as? String, "r1")
        XCTAssertEqual(keychain.currentUserValues, ["Claude Code-credentials": "other account"])
    }

    func testRefreshWaitsForAccountReplacementAndRejectsThePreviousGeneration() throws {
        let profile = AccountProfile(
            id: UUID().uuidString, family: "claude", label: "Test", identityKey: "account|org", createdAt: .distantPast)
        let keychain = ServiceKeychain()
        let vault = AccountCredentialVault(keychain: keychain)
        let original = AccountCredentialVault.Entry(credential: credential, claudeOAuthAccount: nil)
        let replacement = AccountCredentialVault.Entry(
            credential: credential.replacingOccurrences(of: "a1", with: "new-login"), claudeOAuthAccount: nil)
        try vault.save(original, profile: profile)
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profile.id))
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "old-account-rotation"
        let rotation = updated
        let generation = ClaudeCredentialGeneration(candidates)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchGroup()

        do {
            AccountCredentialMutationLock.acquire(family: "claude")
            defer { AccountCredentialMutationLock.release(family: "claude") }
            DispatchQueue.global().async(group: finished) {
                started.signal()
                do {
                    let applied = try store.save(rotation, ifUnchanged: generation)
                    XCTAssertFalse(applied)
                } catch {
                    XCTFail("Unexpected rotation failure: \(error)")
                }
            }
            XCTAssertEqual(started.wait(timeout: .now() + 5), .success)
            XCTAssertEqual(finished.wait(timeout: .now() + 0.2), .timedOut)
            try vault.save(replacement, profile: profile)
        }

        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(try vault.load(profile: profile), replacement)
    }

    func testSnapshotRotationPreservesAccountIdentityAndCredentialExtensions() throws {
        let profileID = UUID().uuidString
        let service = AccountCredentialVault.service(family: "claude", profileID: profileID)
        let account = #"{"accountUuid":"a","organizationUuid":"org"}"#
        let entry = AccountCredentialVault.Entry(credential: credential, claudeOAuthAccount: account)
        let keychain = ServiceKeychain(currentUserValues: [
            service: String(decoding: try JSONEncoder().encode(entry), as: UTF8.self)
        ])
        let store = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles(), keychain: keychain,
            scope: .accountSnapshot(profileID: profileID))
        let candidates = store.loadCredentialSet().candidates
        var updated = try XCTUnwrap(candidates.first)
        updated.oauth.accessToken = "a2"

        XCTAssertTrue(try store.save(updated, ifUnchanged: ClaudeCredentialGeneration(candidates)))

        let saved = try XCTUnwrap(
            AccountCredentialVault(keychain: keychain).load(family: "claude", profileID: profileID))
        XCTAssertEqual(saved.claudeOAuthAccount, account)
        let document = try XCTUnwrap(ProviderParse.jsonObjectWithHexFallback(saved.credential))
        XCTAssertEqual(document["mcpOAuth"] as? [String: String], ["server": "mcp1"])
        XCTAssertEqual(ClaudeAuthStore.parseCredentials(saved.credential)?.claudeAiOauth, updated.oauth)
        XCTAssertEqual(Set(keychain.currentUserValues.keys), [service])
    }
}
