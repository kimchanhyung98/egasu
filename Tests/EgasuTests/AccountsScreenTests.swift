import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class AccountsScreenTests: XCTestCase {
    // MARK: - Remove Account…

    func testProvidersMoveOnlyWhenBothHaveASingleAccount() {
        let ids = ["claude", "codex", "codex@ab12cd34", "cursor"]
        XCTAssertTrue(AccountListView.allowsProviderMove("cursor", onto: "claude", among: ids))
        XCTAssertFalse(
            AccountListView.allowsProviderMove("cursor", onto: "codex", among: ids), "계정이 여럿인 묶음은 다른 프로바이더와 섞이지 않음")
        XCTAssertFalse(AccountListView.allowsProviderMove("codex@ab12cd34", onto: "claude", among: ids))
    }

    func testRemovingADetectedProviderOnlyTurnsItOff() throws {
        var disabled: [String] = []
        try ProviderAccountRows.remove(providerID: "cursor", keyProvider: nil) { enabled, id in
            XCTAssertFalse(enabled)
            disabled.append(id)
        }
        XCTAssertEqual(disabled, ["cursor"], "로그인 파일은 건드리지 않고 추적만 끔")
    }

    func testRemovingAnAPIKeyProviderDeletesOnlyTheSavedKey() throws {
        for (status, deletes) in [
            (APIKeyStatus.saved, true), (.overrideActive, true), (.fromEnvironment, false), (.notSet, false)
        ] {
            let keys = FakeAPIKeyProvider(status: status)
            var disabled: [String] = []
            try ProviderAccountRows.remove(providerID: "openrouter", keyProvider: keys) { _, id in disabled.append(id) }
            XCTAssertEqual(keys.deleteCount, deletes ? 1 : 0, "\(status): 환경 변수 키는 그대로")
            XCTAssertEqual(disabled, ["openrouter"])
        }
    }

    func testAFailedKeyDeleteKeepsTheProviderOn() {
        let keys = FakeAPIKeyProvider(status: .saved, failsDelete: true)
        var disabled: [String] = []
        XCTAssertThrowsError(
            try ProviderAccountRows.remove(providerID: "zai", keyProvider: keys) { _, id in disabled.append(id) })
        XCTAssertTrue(disabled.isEmpty, "키 삭제가 실패하면 끄지 않음")
    }

    func testTheNewTerminalSessionAccountCannotBeRemovedWhileOthersExist() {
        let profile = AccountProfile(id: "a", family: "codex", label: "a", identityKey: "a", createdAt: Date())
        XCTAssertTrue(RegisteredAccountRows.blocksRemoval(of: profile, isSelected: true, familyCount: 2))
        XCTAssertFalse(
            RegisteredAccountRows.blocksRemoval(of: profile, isSelected: true, familyCount: 1), "마지막 계정은 삭제 가능")
        XCTAssertFalse(RegisteredAccountRows.blocksRemoval(of: profile, isSelected: false, familyCount: 3))
    }

    // MARK: - Use This Account

    func testTheSwitchIsOffLimitsForAccountsThatNeedSigningIn() {
        func blocks(_ status: AccountStatus, busy: Bool = false, unreadable: Bool = false) -> Bool {
            RegisteredAccountRows.blocksSelection(status: status, isBusy: busy, hasUnreadableRegistry: unreadable)
        }
        XCTAssertTrue(blocks(.sessionExpired("Sign in again")))
        XCTAssertTrue(blocks(.signInNeeded(nil)))
        XCTAssertFalse(blocks(.ready))
        XCTAssertFalse(blocks(.notChecked), "확인 전 상태만으로는 막지 않음")
        XCTAssertFalse(blocks(.refreshFailed("offline")), "일시적인 조회 실패는 전환 가능")
        XCTAssertTrue(blocks(.ready, busy: true))
        XCTAssertTrue(blocks(.ready, unreadable: true))
    }

    func testAFinishedRefreshRechecksASignInThatCouldNotBeRead() {
        let cards = ["claude": "work", "claude@profile-home": "home"]
        func recheck(_ state: AccountSignInProbe.State?, finished: Set<String>) -> Bool {
            RegisteredAccountRows.needsSignInRecheck(
                state: state, finishedCardIDs: finished, profileID: "work", profileIDForCard: { cards[$0] }
            )
        }
        XCTAssertTrue(recheck(.readFailed("Keychain locked"), finished: ["claude"]), "Keychain 승인 뒤 화면을 다시 열지 않아도 재확인")
        XCTAssertTrue(recheck(nil, finished: ["claude"]))
        XCTAssertFalse(recheck(.readFailed("Keychain locked"), finished: ["claude@profile-home"]), "다른 계정의 새로 고침")
        XCTAssertFalse(recheck(.readFailed("Keychain locked"), finished: []), "아직 새로 고침 중")
        XCTAssertFalse(recheck(.ready(identityKey: "id", label: nil), finished: ["claude"]))
        XCTAssertFalse(recheck(.needsSignIn, finished: ["claude"]))
    }

    // MARK: - Allow Keychain Access…

    func testKeychainApprovalReplacesSignInOnlyWhenTheSavedSignInCouldNotBeRead() {
        XCTAssertTrue(RegisteredAccountRows.offersKeychainApproval(.readFailed("Keychain locked")))
        XCTAssertFalse(RegisteredAccountRows.offersKeychainApproval(.needsSignIn), "저장 로그인이 없으면 다시 로그인")
        XCTAssertFalse(RegisteredAccountRows.offersKeychainApproval(.ready(identityKey: "id", label: nil)))
        XCTAssertFalse(RegisteredAccountRows.offersKeychainApproval(nil), "확인 전")
    }

    func testOnlyTheApprovalRequestReadsTheSavedSignInWithAPrompt() {
        let profile = AccountProfile(id: "work", family: "codex", label: "work", identityKey: "id", createdAt: Date())
        let background = InteractionRecordingKeychain()
        let approval = InteractionRecordingKeychain()

        _ = AccountSignInProbe(keychain: background).state(for: profile)
        _ = AccountSignInProbe(keychain: approval).state(for: profile, allowInteraction: true)

        XCTAssertFalse(background.interactions.isEmpty)
        XCTAssertFalse(background.interactions.contains(true), "화면을 열 때의 확인은 승인 창 없음")
        XCTAssertFalse(approval.interactions.isEmpty)
        XCTAssertTrue(approval.interactions.allSatisfy { $0 }, "승인 요청은 macOS 승인 창 허용")
    }

    // MARK: - Add Account

    func testAddingAClaudeOrCodexAccountWaitsForAReadableRegistry() {
        XCTAssertTrue(
            ManagedAccountSignInStep.blocksAdding(isSwitching: false, hasUnreadableRegistry: true),
            "공유 홈 로그인을 바꾼 뒤 등록이 실패하지 않게")
        XCTAssertTrue(ManagedAccountSignInStep.blocksAdding(isSwitching: true, hasUnreadableRegistry: false))
        XCTAssertFalse(ManagedAccountSignInStep.blocksAdding(isSwitching: false, hasUnreadableRegistry: false))
    }

    func testAnAPIKeyProviderCanUseAKeyAlreadyOnThisMac() {
        XCTAssertTrue(AddAccountSheet.canAddAPIKey("", hasExistingKey: true), "환경 변수 키만으로 켜기")
        XCTAssertFalse(AddAccountSheet.canAddAPIKey("   ", hasExistingKey: false), "키가 전혀 없으면 입력 필요")
        XCTAssertTrue(AddAccountSheet.canAddAPIKey(" sk-new ", hasExistingKey: false))
    }

    // MARK: - In Use

    func testInUseMarksOnlyTheNewTerminalSessionAccount() {
        let mapping = ["codex": "p1", "codex@profile-p2": "p2", "cursor": "p1"]
        let inUse = mapping.keys.sorted().filter {
            AccountCardPresentationPlanner.isInUse(cardID: $0, profileID: mapping[$0], preferredProfileID: "p1")
        }
        XCTAssertEqual(inUse, ["codex"], "Claude·Codex 등록 계정 한 곳에만, 다른 프로바이더는 대상 아님")
        XCTAssertFalse(
            AccountCardPresentationPlanner.isInUse(cardID: "codex", profileID: nil, preferredProfileID: "p1"),
            "미등록 공유 홈은 표시 안 함")
        let switched = mapping.keys.sorted().filter {
            AccountCardPresentationPlanner.isInUse(cardID: $0, profileID: mapping[$0], preferredProfileID: "p2")
        }
        XCTAssertEqual(switched, ["codex@profile-p2"])
        XCTAssertTrue(
            AccountCardPresentationPlanner.isInUse(cardID: "claude", profileID: "p3", preferredProfileID: "p3"))
        XCTAssertFalse(
            AccountCardPresentationPlanner.isInUse(cardID: "claude", profileID: "p3", preferredProfileID: nil))
    }

    // MARK: - VoiceOver Reorder

    func testVoiceOverMovesStayAmongTheSameProvidersAccounts() {
        let ids = ["claude", "cursor", "codex", "claude@profile-home", "codex@ab12cd34"]
        XCTAssertEqual(
            AccountListView.familySiblings(of: "claude@profile-home", among: ids), ["claude", "claude@profile-home"])
        XCTAssertEqual(AccountListView.familySiblings(of: "codex", among: ids), ["codex", "codex@ab12cd34"])
        XCTAssertEqual(AccountListView.familySiblings(of: "cursor", among: ids), ["cursor"], "계정이 1개면 이동 동작 없음")
    }

    // MARK: - Rename

    func testRenameCommitsTrimmedNameAndCancelKeepsTheOldOne() {
        var names = ["claude@profile-work": "Work"]
        let renaming = AccountRenameStore(label: { names[$0] }, rename: { names[$0] = $1 })

        renaming.begin("claude@profile-work")
        XCTAssertEqual(renaming.draft, "Work")
        renaming.draft = "  Office  "
        renaming.commit()
        XCTAssertEqual(names["claude@profile-work"], "Office")
        XCTAssertNil(renaming.edit)

        renaming.begin("claude@profile-work")
        renaming.draft = "Ignored"
        renaming.cancel()
        XCTAssertEqual(names["claude@profile-work"], "Office", "Esc는 저장하지 않음")

        renaming.begin("claude@profile-work")
        renaming.draft = "   "
        renaming.commit()
        XCTAssertEqual(names["claude@profile-work"], "Office", "로그인 이메일을 모르면 기존 이름 유지")
        XCTAssertNotNil(renaming.lastError, "빈 이름을 이메일로 바꿀 수 없는 이유를 안내")
    }

    func testClearingTheNameRemovesItInFavorOfTheSignInEmail() {
        var names = ["claude@profile-work": "Work"]
        let renaming = AccountRenameStore(
            label: { names[$0] }, email: { _ in "me@example.com" }, rename: { names[$0] = $1 }
        )

        renaming.begin("claude@profile-work")
        renaming.draft = "   "
        renaming.commit()

        XCTAssertEqual(names["claude@profile-work"], "me@example.com", "비운 이름은 별명 제거 — 로그인 이메일을 이름으로")
        XCTAssertNil(renaming.lastError)
        XCTAssertNil(renaming.edit)
    }

    func testClearingANameThatIsAlreadyTheSignInEmailSavesNothing() {
        var saves = 0
        let renaming = AccountRenameStore(
            label: { _ in "me@example.com" }, email: { _ in "me@example.com" }, rename: { _, _ in saves += 1 }
        )

        renaming.begin("claude@profile-work")
        renaming.draft = ""
        renaming.commit()

        XCTAssertEqual(saves, 0)
    }

    func testClearingTheNameReportsAFailedSave() {
        struct Failure: Error {}
        let renaming = AccountRenameStore(
            label: { _ in "Work" }, email: { _ in "me@example.com" }, rename: { _, _ in throw Failure() }
        )

        renaming.begin("claude@profile-work")
        renaming.draft = ""
        renaming.commit()

        XCTAssertNotNil(renaming.lastError, "이메일 이름이 다른 계정과 겹치는 등 저장 실패는 그대로 보고")
    }

    func testRenameIgnoresCardsWithoutANameAndStaleEdits() {
        var renamed: [String] = []
        let renaming = AccountRenameStore(
            label: { $0 == "cursor" ? nil : "Work" }, rename: { id, _ in renamed.append(id) })

        renaming.begin("cursor")
        XCTAssertNil(renaming.edit, "이름이 없는 카드는 편집 불가")

        renaming.begin("codex@profile-a")
        let stale = renaming.edit
        renaming.begin("codex@profile-b")
        renaming.draft = "New"
        renaming.commit(stale)
        XCTAssertEqual(renaming.edit?.cardID, "codex@profile-b", "늦게 온 포커스 이탈이 새 편집을 닫지 않음")
        XCTAssertTrue(renamed.isEmpty)
    }

    func testRenameFailureIsReported() {
        struct Failure: Error {}
        let renaming = AccountRenameStore(label: { _ in "Work" }, rename: { _, _ in throw Failure() })
        renaming.begin("claude@profile-work")
        renaming.draft = "Office"
        renaming.commit()
        XCTAssertNotNil(renaming.lastError)
    }

    func testSwitchingEditorsKeepsThePreviousFailureUntilAcknowledged() {
        let names = ["claude@profile-work": "Work", "claude@profile-home": "Home"]
        let renaming = AccountRenameStore(
            label: { names[$0] },
            rename: { _, name in
                throw AccountProfileError.duplicateLabel(name)
            })
        renaming.begin("claude@profile-work")
        renaming.draft = "Home"
        renaming.begin("claude@profile-home")

        XCTAssertNil(renaming.edit, "이전 편집 저장이 실패하면 새 편집으로 오류를 지우지 않음")
        XCTAssertNotNil(renaming.lastError)
        renaming.dismissError()
        renaming.begin("claude@profile-home")
        XCTAssertNil(renaming.lastError)
        XCTAssertEqual(renaming.edit?.cardID, "claude@profile-home")
        XCTAssertEqual(renaming.draft, "Home")
    }

    func testRenameFailureIsPresentedAfterOpeningAndDismissedByOK() async throws {
        let renaming = AccountRenameStore(
            label: { _ in "Work" },
            rename: { _, name in
                throw AccountProfileError.duplicateLabel(name)
            })
        func content(shown: Bool) -> some View {
            Color.clear
                .frame(width: 340, height: 100)
                .accountRenameErrorAlert(renaming: renaming, isPopoverShown: shown)
        }
        let host = NSHostingView(rootView: content(shown: false))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 100),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1_000, y: 0))
        window.orderFrontRegardless()
        defer {
            if let sheet = window.attachedSheet { window.endSheet(sheet) }
            window.close()
        }

        renaming.begin("claude@profile-work")
        renaming.draft = "Home"
        renaming.commit()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(window.attachedSheet, "닫힌 패널의 오류는 다음 열기까지 보존")
        XCTAssertNotNil(renaming.lastError)

        host.rootView = content(shown: true)
        for _ in 0..<50 where window.attachedSheet == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        let sheet = try XCTUnwrap(window.attachedSheet)
        let views = descendants(of: try XCTUnwrap(sheet.contentView))
        let messages = views.compactMap { ($0 as? NSTextField)?.stringValue }
        XCTAssertTrue(messages.contains(L10n.accounts("Couldn't Rename Account")))
        XCTAssertTrue(messages.contains(try XCTUnwrap(renaming.lastError)))
        let button = try XCTUnwrap(views.compactMap { $0 as? NSButton }.first { $0.title == L10n.dashboard("OK") })
        button.performClick(nil)
        for _ in 0..<50 where renaming.lastError != nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNil(renaming.lastError)
    }

    private func descendants(of view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(of: $0) }
    }
}

/// 저장 로그인 읽기마다 승인 창 허용 여부만 기록 — 항목은 없음.
private final class InteractionRecordingKeychain: KeychainAccessing, @unchecked Sendable {
    private(set) var interactions: [Bool] = []

    func readAppOwnedPassword(service: String, forCurrentUser: Bool, allowInteraction: Bool) throws -> String? {
        interactions.append(allowInteraction)
        return nil
    }

    func readGenericPassword(service: String) throws -> String? { nil }
    func writeGenericPassword(service: String, value: String) throws {}
    func deleteGenericPassword(service: String) throws {}
}

@MainActor
private final class FakeAPIKeyProvider: APIKeyManaging {
    let provider = Provider(id: "openrouter", displayName: "OpenRouter", icon: .providerMark("openrouter"))
    let widgetDescriptors: [WidgetDescriptor] = []
    let apiKeyStatus: APIKeyStatus
    let failsDelete: Bool
    private(set) var deleteCount = 0

    init(status: APIKeyStatus, failsDelete: Bool = false) {
        apiKeyStatus = status
        self.failsDelete = failsDelete
    }

    func refresh() async -> ProviderSnapshot {
        ProviderSnapshot(providerID: provider.id, displayName: provider.displayName, lines: [])
    }
    func hasLocalCredentials() async -> Bool { apiKeyStatus != .notSet }
    func currentAPIKey() -> String? { nil }
    func saveAPIKey(_ key: String) throws {}

    func deleteAPIKey() throws {
        struct DeleteFailed: Error {}
        if failsDelete { throw DeleteFailed() }
        deleteCount += 1
    }
}
