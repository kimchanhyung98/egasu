import Foundation

extension WidgetDataStore {
    /// 첫 읽기를 아직 받지 못한 카드 — 실패 공지가 있으면 대기가 아님.
    func isWaitingForFirstReading(_ providerID: String) -> Bool {
        snapshots[providerID] == nil && headerNotice(for: providerID) == nil
    }

    /// Priority 보드 — 대시보드와 메뉴 막대가 같은 입력·규칙을 공유.
    /// `hidingEmails`는 공유 이미지용: 계정 공지에 계정 정보가 섞일 수 있어 상태 문구로 대체.
    func priorityBoard(
        accounts: [DashboardAccount], pinned: Set<String>, now: Date, hidingEmails: Bool = false,
        awaitingIdentity: Set<String> = []
    )
        -> PriorityBoard
    {
        PriorityBoard.make(
            accounts: hidingEmails ? accounts.map(\.hidingEmail) : accounts,
            pinned: pinned,
            visibleLevels: displaySettings.visiblePriorityLevels,
            burningFast: burningFast,
            useItOrLoseIt: displaySettings.showsUseItOrLoseIt,
            now: now
        ) { account in
            if let message = self.headerNotice(for: account.id) {
                return .unavailable(hidingEmails ? L10n.dashboard("Current usage unavailable.") : message)
            }
            if awaitingIdentity.contains(account.id) { return .waiting }
            return self.snapshots[account.id] == nil ? .waiting : .current
        }
    }
}
