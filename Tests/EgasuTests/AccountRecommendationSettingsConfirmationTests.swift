import XCTest
@testable import Egasu

@MainActor
final class AccountRecommendationSettingsConfirmationTests: XCTestCase {
    private enum Change {
        case disabled, betaDisabled, triggerIncreased, candidateLimitReduced, dismissed
        case unchanged, stillEligible

        var succeeds: Bool { self == .unchanged || self == .stillEligible }
    }

    func testChangedSettingsRejectThePendingRecommendationBeforeAuthenticationWrites() async throws {
        for family in ["claude", "codex"] {
            for change in [
                Change.disabled, .betaDisabled, .triggerIncreased, .candidateLimitReduced, .dismissed
            ] {
                try await check(change, family: family)
            }
        }
    }

    func testUnchangedOrStillEligibleSettingsPermitTheConfirmedSwitch() async throws {
        for family in ["claude", "codex"] {
            for change in [Change.unchanged, .stillEligible] { try await check(change, family: family) }
        }
    }

    private func check(_ change: Change, family: String) async throws {
        let fixture = try AccountSwitchRecoveryFixture(test: self)
        let current: AccountProfile
        let target: AccountProfile
        let currentEntry: AccountCredentialVault.Entry
        let targetEntry: AccountCredentialVault.Entry
        if family == "claude" {
            (current, target, currentEntry, targetEntry) = (fixture.a, fixture.b, fixture.entryA, fixture.entryB)
        } else {
            current = try fixture.store.add(family: "codex", label: "A", identityKey: "workspace-a", id: "codex-a")
            target = try fixture.store.add(family: "codex", label: "B", identityKey: "workspace-b", id: "codex-b")
            func entry(_ profile: AccountProfile) -> AccountCredentialVault.Entry {
                let payload = Data(#"{"sub":"\#(profile.id)"}"#.utf8).base64EncodedString()
                return .init(
                    credential:
                        #"{"tokens":{"access_token":"header.\#(payload).signature","account_id":"\#(profile.identityKey)"}}"#
                )
            }
            currentEntry = entry(current)
            targetEntry = entry(target)
            for (profile, entry) in [(current, currentEntry), (target, targetEntry)] {
                try fixture.switcher.saveSnapshot(entry, for: profile)
                try fixture.switcher.writeWorkspaceAuthentication(entry, for: profile)
            }
            try fixture.switcher.applySharedAuthentication(currentEntry, family: family)
        }
        let now = Date()
        let settings = AccountRecommendationSettingsStore(defaults: fixture.defaults, labsAvailable: true)
        settings.enabled = true
        func quota(_ profile: AccountProfile) -> AccountSwitchQuota? {
                .init(
                    windows: [
                        .weekly: .init(percent: profile.id == current.id ? 96 : 20, reset: now.addingTimeInterval(7200))
                    ],
                    codexAccountKey: family == "codex"
                        ? CodexResetClaimBinding.verifiedAccountKey(
                            for: profile.id == current.id ? currentEntry.credential : targetEntry.credential) : nil)
        }
        func recommendation() -> AccountSwitchRecommendation? {
            settings.recommendation(current: current, profiles: [current, target], at: now, quota: quota)
        }
        let pending = try XCTUnwrap(recommendation())
        switch change {
        case .disabled: settings.enabled = false
        case .betaDisabled: settings.setLabsAvailable(false)
        case .triggerIncreased: settings.triggerPercent = 100
        case .candidateLimitReduced: settings.candidateLimitPercent = 20
        case .dismissed: settings.dismiss(pending, at: now, quota: quota)
        case .stillEligible:
            settings.triggerPercent = 90
            settings.candidateLimitPercent = 30
        case .unchanged: break
        }
        let writes = fixture.keychain.writeCount
        do {
            try await fixture.selectionSwitcher.switchAuthentication(
                to: pending.target, in: fixture.store, validateTarget: pending.validateTarget,
                validateDeparture: { try pending.validate(departure: $0, latest: recommendation()) })
            XCTAssertTrue(change.succeeds, "Unavailable recommendation: \(family) \(change)")
        } catch is AccountSwitchRecommendation.NoLongerAvailable {
            XCTAssertFalse(change.succeeds, "Valid recommendation: \(family) \(change)")
        }
        if !change.succeeds { XCTAssertEqual(fixture.keychain.writeCount, writes) }
        XCTAssertNil(try fixture.journal.load())
        XCTAssertEqual(
            try fixture.switcher.readSharedAuthentication(family: family), change.succeeds ? targetEntry : currentEntry)
        for (profile, entry) in [(current, currentEntry), (target, targetEntry)] {
            XCTAssertEqual(try fixture.switcher.loadSnapshot(for: profile), entry)
            let home = try fixture.workspace.directory(family: family, profileID: profile.id).path
            XCTAssertEqual(try fixture.switcher.readAuthentication(family: family, home: home), entry)
        }
        XCTAssertEqual(
            try fixture.freshStore().preferredProfileID(family: family), change.succeeds ? target.id : current.id)
    }
}
