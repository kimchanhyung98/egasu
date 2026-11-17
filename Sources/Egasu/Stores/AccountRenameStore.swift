import Foundation
import Observation

/// 제자리 계정 이름 변경 — 한 번에 하나만 편집, Return·포커스 이탈은 저장, Esc는 취소.
/// 이름은 Claude·Codex 등록 계정에만 있음. 비운 이름은 별명 제거 — 로그인 이메일을 이름으로 저장.
/// 저장 실패는 로그와 `lastError`로 드러냄.
@MainActor
@Observable
final class AccountRenameStore {
    struct Edit: Equatable {
        let cardID: String
        fileprivate let serial: Int
    }

    private(set) var edit: Edit?
    private(set) var lastError: String?
    var draft = ""
    @ObservationIgnored private var serial = 0
    @ObservationIgnored private let label: @MainActor (String) -> String?
    @ObservationIgnored private let email: @MainActor (String) -> String?
    @ObservationIgnored private let rename: @MainActor (String, String) throws -> Void

    /// - Parameters:
    ///   - label: 카드의 현재 계정명, 이름이 없는 카드는 nil(편집 불가).
    ///   - email: 카드의 로그인 이메일 — 비운 이름을 대신함, 모르면 nil.
    ///   - rename: 카드의 계정명 저장.
    init(
        label: @escaping @MainActor (String) -> String?,
        email: @escaping @MainActor (String) -> String? = { _ in nil },
        rename: @escaping @MainActor (String, String) throws -> Void
    ) {
        self.label = label
        self.email = email
        self.rename = rename
    }

    func canRename(_ cardID: String) -> Bool { label(cardID) != nil }

    func begin(_ cardID: String) {
        guard let current = label(cardID) else { return }
        commit()
        guard lastError == nil else { return }
        serial += 1
        edit = Edit(cardID: cardID, serial: serial)
        draft = current
    }

    /// 열린 편집 저장 — `edit`을 주면 그 편집일 때만(늦게 온 포커스 이탈이 새 편집을 닫지 않게).
    func commit(_ edit: Edit? = nil) {
        guard let open = close(edit) else { return }
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        // 비운 이름은 별명 제거 — 로그인 이메일을 이름으로, 이메일을 모르면 기존 이름 유지.
        guard let name = typed.isEmpty ? email(open.cardID) : typed else {
            AppLog.error(.config, "account name was cleared but its sign-in email is unknown; keeping the name")
            lastError = L10n.accounts("The sign-in email is unavailable. Enter an account name.")
            return
        }
        guard name != label(open.cardID) else { return }
        do {
            try rename(open.cardID, name)
        } catch {
            AppLog.error(.config, "account rename failed: \(error.localizedDescription)")
            lastError = UserFacingErrors.message(error)
        }
    }

    func cancel(_ edit: Edit? = nil) {
        close(edit)
    }

    func dismissError() {
        lastError = nil
    }

    @discardableResult
    private func close(_ edit: Edit?) -> Edit? {
        guard let open = self.edit, edit == nil || edit == open else { return nil }
        self.edit = nil
        return open
    }
}
