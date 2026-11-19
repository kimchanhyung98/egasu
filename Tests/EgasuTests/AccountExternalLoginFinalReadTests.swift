import XCTest
@testable import Egasu

@MainActor
final class AccountExternalLoginFinalReadTests: XCTestCase {
    func testLoginChangedAfterBackgroundTokenReadIsNotApplied() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        _ = try fixture.rotateDefaultCredentials()
        let external = AccountSwitchRecoveryFixture.entry("c")
        let keychain = fixture.keychain
        let baseService = fixture.baseService
        let rootState = fixture.root.appendingPathComponent(".claude.json")
        let files = FinalSharedReadFileManager(path: rootState.path) {
            keychain.currentUserValues[baseService] = external.credential
        }
        let http = ClaudeReconciliationHTTPClient()
        http.identities["rotated-access-a"] = "acct-a|org-a"
        http.beforeResponse = { files.arm() }
        let importer = AccountCredentialImporter(
            keychain: keychain, fileManager: files, environment: FakeEnvironment(),
            homeDirectory: fixture.root, workspace: fixture.workspace, httpClient: http
        )
        let cliFiles = [
            rootState, fixture.root.appendingPathComponent(".claude/.claude.json"),
            fixture.root.appendingPathComponent(".claude/.credentials.json")
        ]
        let beforeFiles = cliFiles.map { try? Data(contentsOf: $0) }
        let registry = fixture.defaults.data(forKey: AccountProfilesStore.storageKey)
        let writes = keychain.writeCount
        let scoped = keychain.currentUserValues[fixture.scopedService]

        let result = await claudeReconciliationResult(importer, in: fixture.store)

        XCTAssertTrue(files.didMutate)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertThrowsError(try result.get()) {
            XCTAssertEqual($0 as? ClaudeAuthError, .credentialsChanged)
        }
        XCTAssertEqual(keychain.currentUserValues[baseService], external.credential)
        XCTAssertEqual(keychain.currentUserValues[fixture.scopedService], scoped)
        XCTAssertEqual(keychain.writeCount, writes)
        XCTAssertEqual(cliFiles.map { try? Data(contentsOf: $0) }, beforeFiles)
        XCTAssertEqual(fixture.defaults.data(forKey: AccountProfilesStore.storageKey), registry)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        XCTAssertEqual(fixture.store.authenticationRevision, 0)
        XCTAssertNil(try fixture.store.pendingIdentityReplacement())
        try fixture.assertSavedAccountsUnchanged()
    }
}

private final class FinalSharedReadFileManager: FileManager, @unchecked Sendable {
    private let path: String
    private let mutation: @Sendable () -> Void
    private let lock = NSLock()
    private var armed = false
    private var mutated = false

    init(path: String, mutation: @escaping @Sendable () -> Void) {
        self.path = path
        self.mutation = mutation
        super.init()
    }

    func arm() { lock.withLock { armed = true } }
    var didMutate: Bool { lock.withLock { mutated } }

    override func fileExists(atPath path: String) -> Bool {
        let shouldMutate = lock.withLock {
            guard path == self.path, armed, !mutated else { return false }
            mutated = true
            return true
        }
        // 공유 토큰을 캡처한 뒤 상태 파일을 읽기 직전에 외부 로그인 변경.
        if shouldMutate { mutation() }
        return super.fileExists(atPath: path)
    }
}
