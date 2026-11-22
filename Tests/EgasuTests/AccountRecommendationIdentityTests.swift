import XCTest
@testable import Egasu

func recommendationCodexBinding(account: String, source: CodexAuthState.Source) -> CodexResetClaimBinding? {
    let payload = Data(#"{"sub":"fixture"}"#.utf8).base64EncodedString()
    let auth = CodexAuth(tokens: CodexTokens(accessToken: "header.\(payload).signature", accountID: account))
    return CodexResetClaimBinding(authState: CodexAuthState(auth: auth, source: source))
}

@MainActor
final class AccountRecommendationIdentityTests: XCTestCase {
    private func reading(_ snapshot: ProviderSnapshot, profile: AccountProfile) async -> AccountSwitchQuota? {
        let suite = UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = Provider(
            id: snapshot.providerID, displayName: profile.family, icon: .providerMark(profile.family))
        let runtime = TestProviderRuntime(provider: provider, descriptors: [], snapshot: snapshot)
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { snapshot.refreshedAt }, providerIdentityKeys: [provider.id: profile.identityKey])
        await store.refresh(providerID: provider.id, force: true)
        return store.recommendationQuota(for: profile, cardID: provider.id, at: snapshot.refreshedAt)
    }

    func testOnlySharedCodexFileCanSupplyCurrentAccountButSavedCardCanSupplyCandidate() async {
        let profile = AccountProfile(
            id: "saved", family: "codex", label: "Work", identityKey: "account", createdAt: .now)
        let shared = AccountCredentialSwitcher().sharedHomePath(family: "codex") + "/auth.json"
        let saved = AccountUsageCardPlanner.cardID(family: "codex", profileID: profile.id)
        let cases: [(String, CodexAuthState.Source, Bool)] = [
            ("codex", .file(path: shared), true), ("codex", .file(path: "/custom/codex/auth.json"), false),
            ("codex", .keychain, false), (saved, .accountSnapshot(profileID: profile.id), true)
        ]
        for (card, source, expected) in cases {
            let binding = recommendationCodexBinding(account: profile.identityKey, source: source)
            let now = Date()
            var snapshot = ProviderSnapshot(
                providerID: card, displayName: "Codex", lines: [], refreshedAt: now, liveQuotaObservedAt: now,
                liveQuotaAccountKey: binding?.verifiedAccountKey, codexResetClaimBinding: binding)
            snapshot.codexSwitchQuota = .init(windows: [.session: .init(percent: 20, reset: now.addingTimeInterval(30))]
            )
            snapshot.codexSwitchIdentity = profile.identityKey
            let quota = await reading(snapshot, profile: profile)
            XCTAssertEqual(quota != nil, expected, "\(card) \(source)")
        }
    }

    func testLegacyClaudeObservationBindsVerifiedOrganizationAndTokenInMemoryOnly() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let profile = try fixture.store.add(family: "claude", label: "Legacy", identityKey: "acct-a", id: "legacy")
        var entry = fixture.entryA
        entry.claudeOAuthAccount = #"{"accountUuid":"acct-a"}"#
        try fixture.switcher.saveSnapshot(entry, for: profile)
        let auth = ClaudeAuthStore(
            environment: FakeEnvironment(), files: FakeFiles([:]), keychain: fixture.keychain,
            scope: .accountSnapshot(profileID: profile.id), allowsDesktopFallback: false)
        let response = HTTPResponse(
            statusCode: 200, headers: [:],
            body: Data(
                #"{"account":{"uuid":"acct-a"},"organization":{"uuid":"org-a"},"five_hour":{"utilization":95}}"#.utf8))
        let http = FakeHTTPClient(response: response)
        let provider = ClaudeProvider(
            authStore: auth, usageClient: .init(httpClient: http), usageStateStore: isolatedClaudeUsageStore())
        let load = auth.loadCredentialSet()
        var credential = try XCTUnwrap(load.candidates.first)
        var generation = ClaudeCredentialGeneration(load.candidates)
        var rejectedGrant: ClaudeUsageStateStore.AuthenticationFailure?
        let mapped = try await provider.fetchLiveUsage(
            state: &credential, credentialGeneration: &generation, rejectedGrant: &rejectedGrant, requestedAt: .now)
        XCTAssertEqual(http.requests.map(\.url.path), ["/api/oauth/profile", "/api/oauth/usage"])
        let proof = try XCTUnwrap(mapped.legacySwitchIdentity)
        XCTAssertEqual(proof.identityKey, "acct-a|org-a")
        XCTAssertTrue(proof.matches(entry))
        XCTAssertNil(
            try JSONDecoder().decode(ClaudeMappedUsage.self, from: JSONEncoder().encode(mapped)).legacySwitchIdentity)

        let now = try XCTUnwrap(mapped.liveQuotaObservedAt)
        var snapshot = ProviderSnapshot(
            providerID: "claude", displayName: "Claude", lines: mapped.lines, refreshedAt: now,
            liveQuotaObservedAt: now, liveQuotaAccountKey: mapped.liveQuotaAccountKey)
        snapshot.legacyClaudeSwitchIdentity = proof
        let serialized = try JSONEncoder().encode(snapshot)
        XCTAssertFalse(String(decoding: serialized, as: UTF8.self).contains("org-a"))
        XCTAssertNil(try JSONDecoder().decode(ProviderSnapshot.self, from: serialized).legacyClaudeSwitchIdentity)
        let accepted = await reading(snapshot, profile: profile)
        XCTAssertEqual(accepted?.legacyClaudeIdentity, proof)
        var foreign = profile
        foreign.identityKey = "acct-b"
        let rejected = await reading(snapshot, profile: foreign)
        XCTAssertNil(rejected)
    }

    func testLegacyAliasExcludedAndSeparateOrganizationOfSameAccountEligible() throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let legacy = try fixture.store.add(family: "claude", label: "Legacy", identityKey: "acct-a", id: "legacy")
        let other = try fixture.store.add(family: "claude", label: "Other", identityKey: "acct-a", id: "other")
        let now = Date()
        let readings = [
            legacy.id: AccountSwitchQuota(
                windows: [.session: .init(percent: 95, reset: nil)],
                legacyClaudeIdentity: .init(identityKey: "acct-a|org-a", accessToken: "first")),
            fixture.a.id: AccountSwitchQuota(windows: [.session: .init(percent: 10, reset: now.addingTimeInterval(10))]
            ),
            other.id: AccountSwitchQuota(
                windows: [.session: .init(percent: 10, reset: now.addingTimeInterval(90))],
                legacyClaudeIdentity: .init(identityKey: "acct-a|org-b", accessToken: "second"))
        ]
        let recommendation = try XCTUnwrap(
            AccountSwitchRecommendation.choose(
                current: legacy, profiles: [fixture.a, other], at: now, quota: { readings[$0.id] }))
        XCTAssertEqual(recommendation.target, other)
        XCTAssertNoThrow(try recommendation.validate(departure: "acct-a|org-a", latest: recommendation))
        XCTAssertThrowsError(try recommendation.validate(departure: "acct-a|org-b", latest: recommendation))
    }

    func testChangedLegacyTargetTokenRejectsBeforeJournalAndSharedLoginWrite() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let target = try fixture.store.add(family: "claude", label: "Legacy", identityKey: "acct-b", id: "legacy")
        var entry = fixture.entryB
        entry.claudeOAuthAccount = #"{"accountUuid":"acct-b"}"#
        try fixture.switcher.saveSnapshot(entry, for: target)
        var pending = AccountSwitchRecommendation(current: fixture.a, target: target)
        pending.legacyTargetIdentity = .init(identityKey: "acct-b|other-org", accessToken: "old-token")
        do {
            try await fixture.selectionSwitcher.switchAuthentication(
                to: target, in: fixture.store, validateTarget: pending.validateTarget,
                validateDeparture: { try pending.validate(departure: $0, latest: pending) })
            XCTFail("The observed token changed")
        } catch is AccountSwitchRecommendation.NoLongerAvailable {}
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), fixture.a.id)
        pending.legacyTargetIdentity = .init(identityKey: "acct-b|org-b", accessToken: "token-b")
        try await fixture.selectionSwitcher.switchAuthentication(
            to: target, in: fixture.store, validateTarget: pending.validateTarget,
            validateDeparture: { try pending.validate(departure: $0, latest: pending) })
        XCTAssertEqual(fixture.store.preferredProfileID(family: "claude"), target.id)
    }

    func testTargetReplacementDuringDepartureVerificationDoesNotCreateRecoveryJournal() async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let pending = AccountSwitchRecommendation(current: fixture.a, target: fixture.b)
        let replacement = AccountSwitchRecoveryFixture.entry("b", token: "replacement")
        let currentService = AccountCredentialVault.service(family: "claude", profileID: fixture.a.id)
        let keychain = fixture.keychain
        let switcher = fixture.switcher
        let target = fixture.b
        keychain.beforeRead = { service in
            if service == currentService {
                keychain.beforeRead = nil
                try switcher.saveSnapshot(replacement, for: target)
            }
        }
        do {
            try await fixture.selectionSwitcher.switchAuthentication(
                to: fixture.b, in: fixture.store, validateTarget: pending.validateTarget,
                validateDeparture: { try pending.validate(departure: $0, latest: pending) })
            XCTFail("The target changed")
        } catch is AccountSwitchRecommendation.NoLongerAvailable {}
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "claude"), fixture.entryA)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: fixture.b), replacement)
    }
}
