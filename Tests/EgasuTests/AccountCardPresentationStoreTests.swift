import XCTest
@testable import Egasu

@MainActor
final class AccountCardPresentationStoreTests: XCTestCase {
    private var defaults: RecordingAccountPresentationDefaults!
    private var suiteName: String!
    private static let legacyDisplayModeKey = "openusage.accountCardDisplayMode.v1"

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "AccountCardPresentationStoreTests-\(UUID().uuidString)"
        defaults = RecordingAccountPresentationDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try await super.tearDown()
    }

    func testRegistrationOrderDoesNotWrite() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let older = profile("older", createdAt: 1)
        let newer = profile("newer", createdAt: 2)

        XCTAssertEqual(store.orderedProfiles([newer, older], family: "claude"), [older, newer])
        XCTAssertEqual(defaults.presentationWriteCount, 0)
        XCTAssertNil(defaults.object(forKey: AccountCardPresentationStore.storageKey))
    }

    func testFamilyOrdersPersistIndependentlyAcrossRelaunch() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let claude = [profile("a"), profile("b", createdAt: 1)]
        let codex = [profile("c", family: "codex"), profile("d", family: "codex", createdAt: 1)]

        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "claude", profiles: claude + codex))
        XCTAssertTrue(store.reorder(dragged: "d", target: "c", family: "codex", profiles: claude + codex))

        let reloaded = AccountCardPresentationStore(defaults: defaults)
        XCTAssertEqual(reloaded.orderedProfiles(claude + codex, family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(reloaded.orderedProfiles(claude + codex, family: "codex").map(\.id), ["d", "c"])
        XCTAssertEqual(defaults.presentationWriteCount, 2)
    }

    func testReorderUsesTargetPositionInBothDirections() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b", createdAt: 1), profile("c", createdAt: 2)]

        XCTAssertTrue(store.reorder(dragged: "a", target: "c", family: "claude", profiles: profiles))
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "c", "a"])
        XCTAssertTrue(store.reorder(dragged: "a", target: "b", family: "claude", profiles: profiles))
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["a", "b", "c"])
    }

    func testNoOpAndInvalidReorderNeverWrite() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b"), profile("other", family: "codex")]

        XCTAssertFalse(store.reorder(dragged: "a", target: "a", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "missing", target: "a", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "a", target: "missing", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "a", target: "other", family: "claude", profiles: profiles))
        XCTAssertFalse(store.reorder(dragged: "a", target: "b", family: "cursor", profiles: profiles))
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testReorderPersistsAdjacentAndDistantMovesAtTheTargetPosition() throws {
        let profiles = ["a", "b", "c", "d"].map { profile($0) }
        let cases: [(dragged: String, target: String, expected: [String])] = [
            ("a", "b", ["b", "a", "c", "d"]),
            ("b", "a", ["b", "a", "c", "d"]),
            ("b", "d", ["a", "c", "d", "b"]),
            ("d", "b", ["a", "d", "b", "c"]),
            ("a", "d", ["b", "c", "d", "a"]),
            ("d", "a", ["d", "a", "b", "c"]),
        ]
        for testCase in cases {
            try seed(modes: [:], orders: ["claude": ["a", "b", "c", "d"]])
            let store = AccountCardPresentationStore(defaults: defaults)

            XCTAssertTrue(store.reorder(
                dragged: testCase.dragged,
                target: testCase.target,
                family: "claude",
                profiles: profiles
            ))

            let reloaded = AccountCardPresentationStore(defaults: defaults)
            XCTAssertEqual(reloaded.orderedProfiles(profiles, family: "claude").map(\.id), testCase.expected)
            XCTAssertEqual(defaults.presentationWriteCount, 1)
        }
    }

    func testStaleForeignAndDuplicateSavedIDsAreIgnoredAndNewProfilesAppend() throws {
        try seed(modes: [:], orders: ["claude": ["missing", "c", "other", "c", "a", "archived"]])
        let store = AccountCardPresentationStore(defaults: defaults)
        var archived = profile("archived")
        archived.isArchived = true
        let profiles = [
            profile("a"), profile("b", createdAt: 1), profile("c", createdAt: 2),
            profile("new", createdAt: 3), profile("other", family: "codex"), archived,
        ]

        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["c", "a", "b", "new"])
        XCTAssertEqual(store.orderedProfiles(profiles, family: "codex").map(\.id), ["other"])
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testEqualRegistrationDatesRetainRegistryOrder() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("z"), profile("a"), profile("m")]

        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude"), profiles)
    }

    func testMissingProfilesDoNotEraseSavedRankOnRead() {
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b", createdAt: 1)]
        XCTAssertTrue(store.reorder(dragged: "b", target: "a", family: "claude", profiles: profiles))

        XCTAssertEqual(store.orderedProfiles([profiles[0]], family: "claude").map(\.id), ["a"])
        XCTAssertTrue(store.orderedProfiles([], family: "claude").isEmpty)
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(defaults.presentationWriteCount, 1)
    }

    func testRenameIdentityReplacementAndSelectionPreserveRank() throws {
        let profiles = AccountProfilesStore(defaults: defaults)
        let first = try profiles.add(family: "claude", label: "First", identityKey: "one")
        let second = try profiles.add(family: "claude", label: "Second", identityKey: "two")
        let store = AccountCardPresentationStore(defaults: defaults)
        XCTAssertTrue(store.reorder(dragged: second.id, target: first.id, family: "claude", profiles: profiles.profiles))

        try profiles.rename(profileID: second.id, to: "Renamed")
        _ = try profiles.replaceIdentity(profileID: second.id, with: "new-identity")
        profiles.setPreferred(family: "claude", profileID: second.id)

        XCTAssertEqual(store.orderedProfiles(profiles.profiles, family: "claude").map(\.id), [second.id, first.id])
        XCTAssertEqual(store.orderedProfiles(profiles.profiles, family: "claude").first?.label, "Renamed")
    }

    func testPresentationWritesLeaveAccountSelectionLayoutAndOtherDefaultsUntouched() throws {
        let registry = AccountProfilesStore(defaults: defaults)
        let first = try registry.add(family: "claude", label: "First", identityKey: "one")
        let second = try registry.add(family: "claude", label: "Second", identityKey: "two")
        registry.setPreferred(family: "claude", profileID: first.id)
        defaults.set("existing-layout", forKey: "openusage.layout.v1")
        defaults.set("claude", forKey: "openusage.dashboardUsageAccount.claude")
        let before = defaults.persistentDomain(forName: suiteName) ?? [:]
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertTrue(store.reorder(dragged: second.id, target: first.id, family: "claude", profiles: registry.profiles))

        var after = defaults.persistentDomain(forName: suiteName) ?? [:]
        after.removeValue(forKey: AccountCardPresentationStore.storageKey)
        XCTAssertEqual(before as NSDictionary, after as NSDictionary)
        XCTAssertEqual(registry.preferredProfileID(family: "claude"), first.id)
    }

    func testCorruptPreferencesAreReportedAndNeverOverwritten() {
        let raw = Data("not valid JSON".utf8)
        defaults.set(raw, forKey: AccountCardPresentationStore.storageKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)
        let profiles = [profile("a"), profile("b")]

        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(store.reorder(dragged: "b", target: "a", family: "claude", profiles: profiles))
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), raw)
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testWrongDefaultsTypeIsReportedAndPreserved() {
        defaults.set("unexpected type", forKey: AccountCardPresentationStore.storageKey)
        defaults.presentationWriteCount = 0
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertNotNil(store.errorMessage)
        XCTAssertFalse(
            store.reorder(dragged: "b", target: "a", family: "claude", profiles: [profile("a"), profile("b")]))
        XCTAssertEqual(defaults.string(forKey: AccountCardPresentationStore.storageKey), "unexpected type")
        XCTAssertEqual(defaults.presentationWriteCount, 0)
    }

    func testLegacyModeValuesDoNotWarnOrChangeAccountOrder() throws {
        let modes = ["claude": "separateCards", "codex": "futureMode", "future": "futureMode"]
        try seed(modes: modes, orders: ["claude": ["b", "a"], "future": ["future-profile"]])
        defaults.set("futureGlobalMode", forKey: Self.legacyDisplayModeKey)
        defaults.presentationWriteCount = 0
        let original = defaults.data(forKey: AccountCardPresentationStore.storageKey)
        let profiles = [profile("a"), profile("b"), profile("c", family: "codex"), profile("d", family: "codex")]
        let store = AccountCardPresentationStore(defaults: defaults)

        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "a"])
        XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), original)
        XCTAssertEqual(defaults.presentationWriteCount, 0)

        XCTAssertTrue(store.reorder(dragged: "d", target: "c", family: "codex", profiles: profiles))
        let stored = try storedObject()
        XCTAssertEqual(stored["modesByFamily"] as? [String: String], modes)
        XCTAssertEqual(
            stored["profileOrderByFamily"] as? [String: [String]],
            [
                "claude": ["b", "a"], "codex": ["d", "c"], "future": ["future-profile"]
            ])
        XCTAssertEqual(defaults.string(forKey: Self.legacyDisplayModeKey), "futureGlobalMode")
        XCTAssertEqual(defaults.presentationWriteCount, 1)
        XCTAssertNil(AccountCardPresentationStore(defaults: defaults).errorMessage)
    }

    func testMalformedOrMissingLegacyModesDoNotBlockOrderWrites() throws {
        let profiles = [profile("a"), profile("b")]
        let legacyBlobs = [
            #"{"profileOrderByFamily":{"claude":["b","a"]},"modesByFamily":{"claude":42}}"#,
            #"{"profileOrderByFamily":{"claude":["b","a"]},"modesByFamily":null}"#,
            #"{"profileOrderByFamily":{"claude":["b","a"]}}"#
        ]
        for json in legacyBlobs {
            let raw = Data(json.utf8)
            defaults.set(raw, forKey: AccountCardPresentationStore.storageKey)
            defaults.set(42, forKey: Self.legacyDisplayModeKey)
            defaults.presentationWriteCount = 0
            let store = AccountCardPresentationStore(defaults: defaults)

            XCTAssertNil(store.errorMessage)
            XCTAssertEqual(store.orderedProfiles(profiles, family: "claude").map(\.id), ["b", "a"])
            XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), raw)
            XCTAssertEqual(defaults.presentationWriteCount, 0)

            XCTAssertTrue(store.reorder(dragged: "a", target: "b", family: "claude", profiles: profiles))
            let saved = try XCTUnwrap(defaults.data(forKey: AccountCardPresentationStore.storageKey))
            let beta2 = try JSONDecoder().decode(Beta2Settings.self, from: saved)
            XCTAssertEqual(beta2.modesByFamily, [:])
            XCTAssertEqual(beta2.profileOrderByFamily, ["claude": ["a", "b"]])
            XCTAssertEqual(defaults.integer(forKey: Self.legacyDisplayModeKey), 42)
            XCTAssertEqual(defaults.presentationWriteCount, 1)
        }
    }

    func testMalformedOrMissingOrderStillBlocksWrites() {
        let profiles = [profile("a"), profile("b")]
        let invalidBlobs = [
            #"{"profileOrderByFamily":{"claude":[42]},"modesByFamily":{"claude":"separateCards"}}"#,
            #"{"profileOrderByFamily":null,"modesByFamily":{"claude":"separateCards"}}"#,
            #"{"modesByFamily":{"claude":"separateCards"}}"#
        ]
        for json in invalidBlobs {
            let raw = Data(json.utf8)
            defaults.set(raw, forKey: AccountCardPresentationStore.storageKey)
            defaults.presentationWriteCount = 0
            let store = AccountCardPresentationStore(defaults: defaults)

            XCTAssertNotNil(store.errorMessage)
            XCTAssertFalse(store.reorder(dragged: "b", target: "a", family: "claude", profiles: profiles))
            XCTAssertEqual(defaults.data(forKey: AccountCardPresentationStore.storageKey), raw)
            XCTAssertEqual(defaults.presentationWriteCount, 0)
        }
    }

    private struct Beta2Settings: Decodable {
        let modesByFamily: [String: String]
        let profileOrderByFamily: [String: [String]]
    }

    private func profile(_ id: String, family: String = "claude", createdAt: TimeInterval = 0) -> AccountProfile {
        AccountProfile(id: id, family: family, label: id, identityKey: "identity-\(id)", createdAt: Date(timeIntervalSince1970: createdAt))
    }

    private func seed(modes: [String: String], orders: [String: [String]]) throws {
        let data = try JSONSerialization.data(withJSONObject: ["modesByFamily": modes, "profileOrderByFamily": orders])
        defaults.set(data, forKey: AccountCardPresentationStore.storageKey)
        defaults.presentationWriteCount = 0
    }

    private func storedObject() throws -> [String: Any] {
        let data = try XCTUnwrap(defaults.data(forKey: AccountCardPresentationStore.storageKey))
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}

private final class RecordingAccountPresentationDefaults: UserDefaults {
    var presentationWriteCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        if ["openusage.accountCardPresentation.v1", "openusage.accountCardDisplayMode.v1"].contains(defaultName) {
            presentationWriteCount += 1
        }
        super.set(value, forKey: defaultName)
    }
}
