import XCTest
@testable import Egasu

final class AccountReadinessInteractionTests: XCTestCase {
    func testSelectedClaudeUsesTheRequestedInteractionPolicyForEverySharedKeychainRead() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("ReadinessInteraction-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let account = #"{"accountUuid":"account","organizationUuid":"organization"}"#
        try Data("{\"oauthAccount\":\(account)}".utf8).write(to: home.appendingPathComponent(".claude.json"))
        let environment = FakeEnvironment([:])
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: environment)
        let credential = #"{"claudeAiOauth":{"accessToken":"fixture-token"}}"#
        let profile = AccountProfile(
            id: "work", family: "claude", label: "Work", identityKey: "account|organization", createdAt: .distantPast)

        for allowInteraction in [false, true] {
            let keychain = PolicyRecordingKeychain(sharedService: service, sharedCredential: credential)
            try AccountCredentialVault(keychain: keychain).save(
                .init(credential: credential, claudeOAuthAccount: account), profile: profile)
            let probe = AccountSignInProbe(environment: environment, keychain: keychain, homeDirectory: { home })

            XCTAssertTrue(probe.state(for: profile, isSelected: true, allowInteraction: allowInteraction).isReady)

            let sharedReads = keychain.reads.filter { $0.service == service }
            XCTAssertEqual(sharedReads.map(\.forCurrentUser), [true, false], "사용자 범위와 서비스 범위 모두 확인")
            XCTAssertTrue(sharedReads.allSatisfy { $0.allowInteraction == allowInteraction })
            XCTAssertTrue(keychain.reads.allSatisfy { $0.allowInteraction == allowInteraction }, "저장 인증도 같은 정책 사용")
            XCTAssertEqual(keychain.legacyReads, allowInteraction ? 2 : 0, "자동 확인은 승인 가능한 CLI 읽기 진입 금지")
        }
    }
}

private final class PolicyRecordingKeychain: KeychainAccessing, @unchecked Sendable {
    struct Read {
        let service: String
        let forCurrentUser: Bool
        let allowInteraction: Bool
    }

    private let sharedService: String
    private let sharedCredential: String
    private var saved: [String: String] = [:]
    private(set) var reads: [Read] = []
    private(set) var legacyReads = 0

    init(sharedService: String, sharedCredential: String) {
        self.sharedService = sharedService
        self.sharedCredential = sharedCredential
    }

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        reads.append(Read(service: service, forCurrentUser: forCurrentUser, allowInteraction: allowInteraction))
        return saved[service]
    }

    func readGenericPasswordForCurrentUser(service: String, allowInteraction: Bool) throws -> String? {
        reads.append(Read(service: service, forCurrentUser: true, allowInteraction: allowInteraction))
        return nil
    }

    func readGenericPassword(service: String, allowInteraction: Bool) throws -> String? {
        reads.append(Read(service: service, forCurrentUser: false, allowInteraction: allowInteraction))
        return service == sharedService ? sharedCredential : saved[service]
    }

    func readGenericPassword(service: String) throws -> String? {
        legacyReads += 1
        reads.append(Read(service: service, forCurrentUser: false, allowInteraction: true))
        return service == sharedService ? sharedCredential : saved[service]
    }

    func readGenericPasswordForCurrentUser(service: String) throws -> String? {
        legacyReads += 1
        reads.append(Read(service: service, forCurrentUser: true, allowInteraction: true))
        return nil
    }

    func writeGenericPassword(service: String, value: String) throws { saved[service] = value }
    func deleteGenericPassword(service: String) throws { saved.removeValue(forKey: service) }
}
