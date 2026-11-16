import XCTest
@testable import Egasu

@MainActor
final class ClaudePinnedUsageVerificationTests: XCTestCase {
    func testRejectedSharedLoginCannotStoreForeignUsageUnderSelectedAccount() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        fixture.keychain.currentUserValues[fixture.baseService] = fixture.entryB.credential
        try Data(#"{"oauthAccount":\#(fixture.entryB.claudeOAuthAccount!)}"#.utf8)
            .write(to: fixture.root.appendingPathComponent(".claude/.claude.json"))
        let reconciliation = await claudeReconciliationResult(fixture.importer, in: fixture.store)
        XCTAssertThrowsError(try reconciliation.get())
        let files = FakeFiles([
            sharedPath(".claude.json"): state("a"),
            sharedPath(".claude/.claude.json"): state("b")
        ])
        let auth = ClaudeAuthStore(
            environment: FakeEnvironment(), files: files, keychain: fixture.keychain,
            allowsDesktopFallback: false, pinsSharedHome: true
        )
        let http = PinnedUsageHTTP { request in
            request.url.path.hasSuffix("/profile") ? Self.profile("b") : Self.usage()
        }
        let store = isolatedClaudeUsageStore()

        await assertSwitchFails { _ = try await self.fetch(auth: auth, http: http, store: store) }

        XCTAssertEqual(http.paths, ["/api/oauth/profile"])
        for account in ["acct-a|org-a", "acct-b|org-b"] {
            let record = try await store.acquire(accountKey: account, usageURL: auth.oauthConfig().usageURL).read()
            XCTAssertNil(record.lastGood)
            XCTAssertNil(record.completedAt)
        }
        try fixture.assertSavedAccountsUnchanged()
    }

    func testPinnedKeychainAndFileCredentialsVerifyBeforeUsage() async throws {
        for source in ["keychain", "file"] {
            let auth = try auth(source: source)
            let http = PinnedUsageHTTP { request in
                request.url.path.hasSuffix("/profile") ? Self.profile("a") : Self.usage()
            }
            let store = isolatedClaudeUsageStore()

            let result = try await fetch(auth: auth, http: http, store: store)

            XCTAssertEqual(http.paths, ["/api/oauth/profile", "/api/oauth/usage"])
            let saved = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL)
                .read()
            XCTAssertEqual(saved.lastGood, result)
            XCTAssertNotNil(saved.lastGood?.quotaObservedAt)
        }
    }

    func testPinnedProfileFailuresKeepExistingQuotaAndCooldownWithoutUsageRequests() async throws {
        for failure in ["mismatch", "organization", "401", "429", "503", "malformed", "network"] {
            let auth = try auth()
            let store = isolatedClaudeUsageStore()
            let start = Date()
            let original = try await seedCooldown(store, auth: auth, at: start)
            let http = PinnedUsageHTTP { _ in
                switch failure {
                case "mismatch": Self.profile("b")
                case "organization": Self.profile("a", organization: "other")
                case "malformed": HTTPResponse(statusCode: 200, headers: [:], body: Data())
                case "network": throw URLError(.timedOut)
                default: HTTPResponse(statusCode: Int(failure)!, headers: [:], body: Data())
                }
            }

            await assertSwitchFails { _ = try await self.fetch(auth: auth, http: http, store: store) }

            XCTAssertEqual(http.paths, ["/api/oauth/profile"])
            let saved = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL)
                .read()
            XCTAssertEqual(saved.lastGood, original.lastGood)
            XCTAssertEqual(saved.retryAfter, original.retryAfter)
            XCTAssertEqual(saved.completedAt, original.completedAt)
            XCTAssertEqual(saved.consecutiveRateLimits, original.consecutiveRateLimits)
            XCTAssertNil(saved.lastFailure)
            XCTAssertNil(saved.authenticationFailure)
        }
    }

    func testPinnedCooldownVerifiesProfileButDoesNotRepeatUsageRequest() async throws {
        let auth = try auth()
        let store = isolatedClaudeUsageStore()
        let clock = PinnedUsageClock(Date())
        let http = PinnedUsageHTTP { request in
            request.url.path.hasSuffix("/profile")
                ? Self.profile("a") : HTTPResponse(statusCode: 429, headers: [:], body: Data())
        }
        let first = try await fetch(auth: auth, http: http, store: store, now: { clock.now })
        clock.advance()

        let second = try await fetch(auth: auth, http: http, store: store, now: { clock.now })

        XCTAssertEqual(http.paths, ["/api/oauth/profile", "/api/oauth/usage", "/api/oauth/profile"])
        XCTAssertEqual(second.retryAfter, first.retryAfter)
        XCTAssertNil(second.liveQuotaObservedAt)
        let saved = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL).read()
        XCTAssertEqual(saved.consecutiveRateLimits, 1)
        XCTAssertEqual(saved.retryAfter, first.retryAfter)
    }

    func testPinnedCooldownReturnsLastGoodWithoutReplacingItsTimestamp() async throws {
        let auth = try auth()
        let store = isolatedClaudeUsageStore()
        let original = try await seedCooldown(store, auth: auth, at: Date())
        let http = PinnedUsageHTTP { _ in Self.profile("a") }

        let result = try await fetch(auth: auth, http: http, store: store)

        XCTAssertEqual(http.paths, ["/api/oauth/profile"])
        XCTAssertEqual(result.quotaObservedAt, original.lastGood?.quotaObservedAt)
        XCTAssertEqual(result.retryAfter, original.retryAfter)
        XCTAssertNil(result.liveQuotaObservedAt)
        let saved = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL).read()
        XCTAssertEqual(saved.lastGood, original.lastGood)
        XCTAssertEqual(saved.completedAt, original.completedAt)
    }

    func testPinnedUsageGateRemembersOpeningBeforeWait() async {
        let gate = PinnedUsageGate()
        await gate.open()
        let resumed = expectation(description: "Preopened gate resumes its waiter")
        let waiter = Task {
            await gate.wait()
            resumed.fulfill()
        }

        await fulfillment(of: [resumed], timeout: 1)
        // timeout 실패 시에도 대기 중인 이전 구현의 continuation 해제.
        await gate.open()
        await waiter.value
    }

    func testConcurrentPinnedRequestsVerifySeparatelyAndShareUsage() async throws {
        let auth = try auth()
        let started = expectation(description: "First identity verification started")
        let contended = expectation(description: "Second identity verification waits")
        let store = isolatedClaudeUsageStore(onContention: { contended.fulfill() })
        let gate = PinnedUsageGate()
        let http = PinnedUsageHTTP { request in
            if request.url.path.hasSuffix("/profile") {
                if await gate.isFirst() {
                    started.fulfill()
                    await gate.wait()
                }
                return Self.profile("a")
            }
            return Self.usage()
        }
        let requestedAt = Date().addingTimeInterval(-1)
        let first = Task { try await self.fetch(auth: auth, http: http, store: store, requestedAt: requestedAt) }
        await fulfillment(of: [started], timeout: 3)
        let second = Task { try await self.fetch(auth: auth, http: http, store: store, requestedAt: requestedAt) }
        await fulfillment(of: [contended], timeout: 3)
        await gate.open()

        let firstResult = try await first.value
        let secondResult = try await second.value

        XCTAssertEqual(http.paths.filter { $0.hasSuffix("/profile") }.count, 2)
        XCTAssertEqual(http.paths.filter { $0.hasSuffix("/usage") }.count, 1)
        XCTAssertEqual(secondResult.quotaObservedAt, firstResult.quotaObservedAt)
        XCTAssertEqual([firstResult.liveQuotaObservedAt, secondResult.liveQuotaObservedAt].compactMap { $0 }.count, 1)
    }

    func testPinnedLoginChangeDuringProfileDoesNotSendUsageOrSaveQuota() async throws {
        let auth = try auth()
        let keychain = try XCTUnwrap(auth.keychain as? ServiceKeychain)
        let service = ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())
        let replacement = AccountSwitchRecoveryFixture.entry("b").credential
        let store = isolatedClaudeUsageStore()
        let http = PinnedUsageHTTP { _ in
            keychain.currentUserValues[service] = replacement
            return Self.profile("a")
        }

        await assertSwitchFails { _ = try await self.fetch(auth: auth, http: http, store: store) }

        XCTAssertEqual(http.paths, ["/api/oauth/profile"])
        XCTAssertEqual(keychain.currentUserValues[service], replacement)
        let saved = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL).read()
        XCTAssertNil(saved.lastGood)
        XCTAssertNil(saved.completedAt)
    }

    func testCancellationDuringPinnedProfileDoesNotSendUsageOrSaveQuota() async throws {
        let auth = try auth()
        let store = isolatedClaudeUsageStore()
        let started = expectation(description: "Pinned profile started")
        let gate = PinnedUsageGate()
        let http = PinnedUsageHTTP { _ in
            started.fulfill()
            await gate.wait()
            return Self.profile("a")
        }
        let task = Task { try await self.fetch(auth: auth, http: http, store: store) }
        await fulfillment(of: [started], timeout: 3)
        task.cancel()
        await gate.open()

        await assertSwitchFails { _ = try await task.value }

        XCTAssertEqual(http.paths, ["/api/oauth/profile"])
        let saved = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL).read()
        XCTAssertNil(saved.lastGood)
        XCTAssertNil(saved.completedAt)
    }

    func testUnpinnedScopedAndSnapshotCompoundIdentitiesKeepDirectUsagePath() async throws {
        for source in ["standard", "scoped", "snapshot"] {
            let auth = try auth(source: source)
            let http = PinnedUsageHTTP { _ in Self.usage() }

            _ = try await fetch(auth: auth, http: http, store: isolatedClaudeUsageStore())

            XCTAssertEqual(http.paths, ["/api/oauth/usage"])
        }
    }

    func testMalformedPinnedIdentityDoesNotSendProfileOrUsage() async throws {
        let auth = try auth(account: "a|invalid")
        let http = PinnedUsageHTTP { _ in Self.usage() }

        await assertSwitchFails {
            _ = try await self.fetch(auth: auth, http: http, store: self.isolatedClaudeUsageStore())
        }

        XCTAssertTrue(http.paths.isEmpty)
    }

    private func auth(source: String = "keychain", account: String = "a") throws -> ClaudeAuthStore {
        let keychain = ServiceKeychain()
        let files = FakeFiles([sharedPath(".claude.json"): state(account)])
        let credential = #"{"claudeAiOauth":{"accessToken":"token-\#(account)"}}"#
        let scope: ClaudeCredentialScope
        if source == "scoped" {
            let home = "/tmp/pinned-usage-scoped"
            scope = .configDir(path: home, keychainLiteral: home)
            files.files[home + "/.claude.json"] = state(account)
            files.files[home + "/.credentials.json"] = credential
        } else if source == "snapshot" {
            let profile = AccountProfile(
                id: "saved", family: "claude", label: "Saved", identityKey: "acct-\(account)|org-\(account)",
                createdAt: .distantPast
            )
            try AccountCredentialVault(keychain: keychain).save(
                AccountSwitchRecoveryFixture.entry(account), profile: profile)
            scope = .accountSnapshot(profileID: profile.id)
        } else {
            scope = .standard
            if source == "file" {
                files.files["~/.claude/.credentials.json"] = credential
            } else {
                keychain.currentUserValues[ClaudeAuthStore.baseKeychainServiceName(environment: FakeEnvironment())] =
                    credential
            }
        }
        return ClaudeAuthStore(
            environment: FakeEnvironment(), files: files, keychain: keychain, scope: scope,
            allowsDesktopFallback: false, pinsSharedHome: source != "standard"
        )
    }

    private func fetch(
        auth: ClaudeAuthStore, http: HTTPClient, store: ClaudeUsageStateStore,
        requestedAt: Date = Date(), now: @escaping @Sendable () -> Date = Date.init
    ) async throws -> ClaudeMappedUsage {
        let load = auth.loadCredentialSet()
        var credential = try XCTUnwrap(load.candidates.first)
        var generation = ClaudeCredentialGeneration(load.candidates)
        let provider = ClaudeProvider(
            authStore: auth, usageClient: ClaudeUsageClient(httpClient: http), usageStateStore: store, now: now
        )
        return try await provider.fetchLiveUsage(
            state: &credential, credentialGeneration: &generation, requestedAt: requestedAt)
    }

    private func seedCooldown(
        _ store: ClaudeUsageStateStore, auth: ClaudeAuthStore, at now: Date
    ) async throws -> ClaudeUsageStateStore.Record {
        let lease = try await store.acquire(accountKey: "acct-a|org-a", usageURL: auth.oauthConfig().usageURL)
        var record = ClaudeUsageStateStore.Record()
        record.succeeded(ClaudeMappedUsage(lines: [], quotaObservedAt: now.addingTimeInterval(-1)), at: now)
        record.rateLimited(now: now, retryAfterSeconds: nil)
        try lease.save(record)
        return record
    }

    private func sharedPath(_ path: String) -> String {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(path).path
    }

    private func state(_ account: String) -> String {
        #"{"oauthAccount":{"accountUuid":"acct-\#(account)","organizationUuid":"org-\#(account)"}}"#
    }

    nonisolated private static func profile(_ account: String, organization: String? = nil) -> HTTPResponse {
        HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(
                #"{"account":{"uuid":"acct-\#(account)"},"organization":{"uuid":"org-\#(organization ?? account)"}}"#
                    .utf8
            ))
    }

    nonisolated private static func usage() -> HTTPResponse {
        HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"five_hour":{"utilization":42}}"#.utf8))
    }
}

private final class PinnedUsageHTTP: HTTPClient, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [String] = []
    private let handler: @Sendable (HTTPRequest) async throws -> HTTPResponse
    init(_ handler: @escaping @Sendable (HTTPRequest) async throws -> HTTPResponse) { self.handler = handler }
    var paths: [String] { lock.withLock { requests } }
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        lock.withLock { requests.append(request.url.path) }
        return try await handler(request)
    }
}

private final class PinnedUsageClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.withLock { value } }
    func advance() { lock.withLock { value = value.addingTimeInterval(1) } }
}

private actor PinnedUsageGate {
    private var first = true
    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Never>?
    func isFirst() -> Bool {
        defer { first = false }
        return first
    }
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() {
        isOpen = true
        continuation?.resume()
        continuation = nil
    }
}
