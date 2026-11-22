import XCTest
@testable import Egasu

@MainActor
final class CodexRecommendationUserBindingTests: XCTestCase {
    func testChangedMemberAfterRecommendationPreservesSharedLoginAndSavedProfiles() async throws {
        try await checkSwitch(.changedAfterObservation)
    }

    func testChangedMemberBeforeRecommendationPreservesSharedLoginAndSavedProfiles() async throws {
        try await checkSwitch(.changedBeforeObservation)
    }

    func testChangedTargetMemberPreservesBothProfilesAndSelection() async throws {
        try await checkSwitch(.changedTarget)
    }

    func testChangedSavedAndSharedMemberStillRejectsTheOriginalObservation() async throws {
        try await checkSwitch(.changedSavedAndShared)
    }

    func testNewerSavedSnapshotDuringValidationIsNotOverwritten() async throws {
        try await checkSwitch(.changedSnapshotDuringValidation)
    }

    func testTargetReplacementDuringCurrentReadStopsBeforeAnySwitchWrite() async throws {
        try await checkSwitch(.changedTargetDuringRead)
    }

    func testSharedReplacementDuringCurrentReadStopsBeforeAnySwitchWrite() async throws {
        try await checkSwitch(.changedSharedDuringRead)
    }

    func testUnverifiedCurrentSnapshotCannotBeReplacedBySharedLogin() async throws {
        try await checkSwitch(.unverifiedCurrent)
    }

    func testMissingCurrentSnapshotCannotBeCreatedFromSharedLogin() async throws {
        try await checkSwitch(.missingCurrent)
    }

    func testUnverifiedTargetCannotReplaceTheObservedTarget() async throws {
        try await checkSwitch(.unverifiedTarget)
    }

    func testCurrentTokenRotationForTheSameUserIsPreserved() async throws {
        try await checkSwitch(.rotatedCurrent)
    }

    func testTargetTokenRotationForTheSameUserUsesTheLatestSnapshot() async throws {
        try await checkSwitch(.rotatedTarget)
    }

    func testUnchangedUsersCanSwitch() async throws {
        try await checkSwitch(.unchanged)
    }

    func testRetiredSharedTokenDoesNotReplaceTheNewerSavedSignIn() async throws {
        try await checkSwitch(.retiredShared)
    }

    private enum Scenario {
        case changedAfterObservation, changedBeforeObservation, changedTarget, changedTargetDuringRead
        case changedSavedAndShared, changedSnapshotDuringValidation
        case changedSharedDuringRead, unverifiedCurrent, missingCurrent, unverifiedTarget
        case rotatedCurrent, rotatedTarget, unchanged, retiredShared

        var succeeds: Bool {
            switch self {
            case .rotatedCurrent, .rotatedTarget, .unchanged, .retiredShared: true
            default: false
            }
        }
    }

    private func checkSwitch(_ scenario: Scenario) async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let current = try fixture.store.add(family: "codex", label: "A", identityKey: "workspace-w", id: "codex-a")
        let target = try fixture.store.add(family: "codex", label: "C", identityKey: "workspace-c", id: "codex-c")
        let a = entry("user-a", workspace: current.identityKey)
        let b = entry("user-b", workspace: current.identityKey)
        let c = entry("user-c", workspace: target.identityKey)
        let d = entry("user-d", workspace: target.identityKey)
        let unknown = AccountCredentialVault.Entry(
            credential: #"{"tokens":{"access_token":"opaque","account_id":"workspace-w"}}"#,
            claudeOAuthAccount: nil)
        var expectedCurrent: AccountCredentialVault.Entry? = scenario == .unverifiedCurrent ? unknown : a
        if scenario == .retiredShared {
            var newer = entry("user-a", workspace: current.identityKey, generation: "newer")
            newer.codexStaleSharedCredentialFingerprints = [CodexAuthStore.credentialFingerprint(a.credential)]
            expectedCurrent = newer
        }
        if scenario == .missingCurrent { expectedCurrent = nil }
        if let expectedCurrent { try fixture.switcher.saveSnapshot(expectedCurrent, for: current) }
        try fixture.switcher.writeWorkspaceAuthentication(expectedCurrent ?? a, for: current)
        try fixture.switcher.saveSnapshot(c, for: target)
        try fixture.switcher.writeWorkspaceAuthentication(c, for: target)
        let observed = scenario == .changedBeforeObservation ? b : a
        try fixture.switcher.applySharedAuthentication(observed, family: "codex")

        let targetCard = AccountUsageCardPlanner.cardID(family: "codex", profileID: target.id)
        // 스토어 검증용 출처 라벨. 실제 인증 읽기는 가짜 홈 fixture.root로 제한.
        let sharedPath = AccountCredentialSwitcher().sharedHomePath(family: "codex") + "/auth.json"
        let now = Date()
        func runtime(_ profile: AccountProfile, cardID: String, auth: AccountCredentialVault.Entry, percent: Double)
            throws
            -> TestProviderRuntime
        {
            let provider = Provider(id: cardID, displayName: "Codex", icon: .providerMark("codex"))
            let source: CodexAuthState.Source =
                cardID == "codex" ? .file(path: sharedPath) : .accountSnapshot(profileID: profile.id)
            let binding = try XCTUnwrap(
                CodexResetClaimBinding(
                    authState: .init(
                        auth: XCTUnwrap(CodexAuthStore.parseAuth(auth.credential)), source: source)))
            var snapshot = ProviderSnapshot(
                providerID: cardID, displayName: "Codex", lines: [], refreshedAt: now,
                liveQuotaObservedAt: now, liveQuotaAccountKey: binding.verifiedAccountKey,
                codexResetClaimBinding: binding)
            snapshot.codexSwitchIdentity = profile.identityKey
            snapshot.codexSwitchQuota = .init(windows: [
                .session: .init(percent: percent, reset: now.addingTimeInterval(120))
            ])
            return TestProviderRuntime(provider: provider, descriptors: [], snapshot: snapshot)
        }
        let providers = try [
            runtime(current, cardID: "codex", auth: observed, percent: 96),
            runtime(target, cardID: targetCard, auth: c, percent: 10)
        ]
        let dataStore = WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: fixture.defaults), defaults: fixture.defaults, now: { now },
            providerIdentityKeys: ["codex": current.identityKey, targetCard: target.identityKey])
        await dataStore.refreshAll(force: true)
        func recommendation() -> AccountSwitchRecommendation? {
            AccountSwitchRecommendation.choose(current: current, profiles: [current, target], at: now) { profile in
                dataStore.recommendationQuota(
                    for: profile, cardID: profile.id == current.id ? "codex" : targetCard, at: now)
            }
        }
        let pending = try XCTUnwrap(recommendation())
        XCTAssertEqual(pending.target.id, target.id)
        XCTAssertNotEqual(
            CodexResetClaimBinding.verifiedAccountKey(for: a.credential),
            CodexResetClaimBinding.verifiedAccountKey(for: b.credential))

        var expectedShared = observed
        var expectedTarget = c
        switch scenario {
        case .changedAfterObservation:
            expectedShared = b
            try fixture.switcher.applySharedAuthentication(b, family: "codex")
        case .changedSavedAndShared:
            expectedCurrent = b
            expectedShared = b
            try fixture.switcher.saveSnapshot(b, for: current)
            try fixture.switcher.writeWorkspaceAuthentication(b, for: current)
            try fixture.switcher.applySharedAuthentication(b, family: "codex")
        case .changedTarget:
            expectedTarget = d
            try fixture.switcher.saveSnapshot(d, for: target)
            try fixture.switcher.writeWorkspaceAuthentication(d, for: target)
        case .unverifiedTarget:
            expectedTarget = .init(
                credential: #"{"tokens":{"access_token":"opaque","account_id":"workspace-c"}}"#,
                claudeOAuthAccount: nil)
            try fixture.switcher.saveSnapshot(expectedTarget, for: target)
            try fixture.switcher.writeWorkspaceAuthentication(expectedTarget, for: target)
        case .rotatedCurrent:
            expectedCurrent = entry("user-a", workspace: current.identityKey, generation: "rotated")
            try fixture.switcher.applySharedAuthentication(expectedCurrent!, family: "codex")
        case .rotatedTarget:
            expectedTarget = entry("user-c", workspace: target.identityKey, generation: "rotated")
            try fixture.switcher.saveSnapshot(expectedTarget, for: target)
            try fixture.switcher.writeWorkspaceAuthentication(expectedTarget, for: target)
        default: break
        }
        let writesBefore = fixture.keychain.writeCount
        if scenario == .changedTargetDuringRead || scenario == .changedSharedDuringRead {
            let currentService = AccountCredentialVault.service(family: "codex", profileID: current.id)
            let targetService = AccountCredentialVault.service(family: "codex", profileID: target.id)
            let replacement = String(decoding: try JSONEncoder().encode(d), as: UTF8.self)
            if scenario == .changedTargetDuringRead { expectedTarget = d } else { expectedShared = b }
            fixture.keychain.beforeRead = { service in
                guard service == currentService else { return }
                fixture.keychain.beforeRead = nil
                if scenario == .changedTargetDuringRead {
                    fixture.keychain.currentUserValues[targetService] = replacement
                    try fixture.switcher.writeWorkspaceAuthentication(d, for: target)
                } else {
                    try fixture.switcher.applySharedAuthentication(b, family: "codex")
                }
            }
        }
        if scenario == .changedSnapshotDuringValidation {
            var updated = entry("user-a", workspace: current.identityKey, generation: "newer")
            updated.codexStaleSharedCredentialFingerprints = [CodexAuthStore.credentialFingerprint(a.credential)]
            expectedCurrent = updated
            let replacement = updated
            let encoded = String(decoding: try JSONEncoder().encode(replacement), as: UTF8.self)
            let service = AccountCredentialVault.service(family: "codex", profileID: current.id)
            fixture.keychain.beforeRead = { name in
                guard name == service, fixture.keychain.nativeReads.filter({ $0.service == service }).count == 2 else {
                    return
                }
                fixture.keychain.beforeRead = nil
                fixture.keychain.currentUserValues[service] = encoded
                try fixture.switcher.writeWorkspaceAuthentication(replacement, for: current)
            }
        }
        do {
            try await fixture.selectionSwitcher.switchAuthentication(
                to: pending.target, in: fixture.store, validateTarget: pending.validateTarget,
                validateDeparture: { try pending.validate(departure: $0, latest: recommendation()) })
            if !scenario.succeeds { XCTFail("A changed or unverified user must preserve the existing accounts") }
        } catch is AccountSwitchRecommendation.NoLongerAvailable {
            XCTAssertFalse(scenario.succeeds)
        } catch CodexAuthError.credentialsChanged {
            XCTAssertFalse(scenario.succeeds)
        }
        fixture.keychain.beforeRead = nil
        if scenario.succeeds {
            expectedShared = expectedTarget
            XCTAssertGreaterThan(fixture.keychain.writeCount, writesBefore)
        } else {
            XCTAssertEqual(fixture.keychain.writeCount, writesBefore)
        }
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: current), expectedCurrent)
        XCTAssertEqual(try fixture.switcher.loadSnapshot(for: target), expectedTarget)
        let home = try fixture.workspace.directory(family: "codex", profileID: current.id).path
        var expectedWorkspace = expectedCurrent ?? a
        expectedWorkspace.codexStaleSharedCredentialFingerprints = nil
        XCTAssertEqual(try fixture.switcher.readAuthentication(family: "codex", home: home), expectedWorkspace)
        XCTAssertEqual(try fixture.switcher.readSharedAuthentication(family: "codex"), expectedShared)
        XCTAssertEqual(
            try fixture.freshStore().preferredProfileID(family: "codex"), scenario.succeeds ? target.id : current.id)
    }

    private func entry(_ user: String, workspace: String, generation: String = "original")
        -> AccountCredentialVault.Entry
    {
        let payload = Data(#"{"sub":"\#(user)","fixture":"\#(generation)"}"#.utf8).base64EncodedString()
        return .init(
            credential: #"{"tokens":{"access_token":"header.\#(payload).signature","account_id":"\#(workspace)"}}"#,
            claudeOAuthAccount: nil)
    }
}
