import SwiftUI

/// 대시보드 우클릭 명령.
enum DashboardCommand: Equatable {
    case refresh([String])
    case manageAccounts
    case shareScreenshot(String)
    case open(URL)
    case editAccount(String)
    case setPinned(String, Bool)
    /// 그 계정 카드에서만 지표 숨기기.
    case hide(String)
    /// 계정 줄 캡션에서 제자리 이름 변경 시작.
    case rename(String)
    /// 새 터미널 세션이 사용할 Claude·Codex 계정 전환 — 프로필 ID 기준.
    case switchAccount(String)
}

struct DashboardMenuItem: Equatable {
    let title: String
    var command: DashboardCommand?
    var systemImage: String?
    var isDisabled = false
}

/// 우클릭 메뉴 정의 — 구역 사이 구분선, 빈 구역 제거, 명령 없는 항목은 비활성 상태 문구.
enum DashboardMenus {
    typealias Sections = [[DashboardMenuItem]]

    static func provider(_ family: DashboardFamily, refreshDisabled: Bool = false) -> Sections {
        [
            [
                DashboardMenuItem(
                    title: L10n.dashboard("Refresh"), command: .refresh(family.accounts.map(\.id)),
                    isDisabled: refreshDisabled)
            ],
            [DashboardMenuItem(title: L10n.dashboard("Manage Accounts…"), command: .manageAccounts)],
            links(family.provider)
        ].filter { !$0.isEmpty }
    }

    private static func links(_ provider: Provider) -> [DashboardMenuItem] {
        provider.visibleLinks.compactMap { link in
            URL(string: link.url).map { DashboardMenuItem(title: L10n.dashboard(link.label), command: .open($0)) }
        }
    }

    /// 지표 행 메뉴 — 고정 가능한 지표만 Pin/Unpin, 모든 지표에 Hide.
    static func metric(_ metricID: String, pinnable: Bool, pinned: Bool) -> [DashboardMenuItem] {
        let pin =
            pinned
            ? DashboardMenuItem(
                title: L10n.dashboard("Unpin"), command: .setPinned(metricID, false), systemImage: "pin.slash")
            : DashboardMenuItem(title: L10n.dashboard("Pin"), command: .setPinned(metricID, true), systemImage: "pin")
        let hide = DashboardMenuItem(title: L10n.dashboard("Hide"), command: .hide(metricID), systemImage: "eye.slash")
        return pinnable ? [pin, hide] : [hide]
    }

    /// 현재 사용 중이 아닌 등록 계정에만 `switchTitle` 제공.
    /// `canRename`은 이름이 있는 Claude·Codex 등록 계정만.
    static func account(
        _ account: DashboardAccount, status: String?,
        switchTitle: (title: String, profileID: String, isDisabled: Bool)? = nil,
        canRename: Bool = false, renameDisabled: Bool = false, refreshDisabled: Bool = false
    ) -> Sections {
        [
            status.map { [DashboardMenuItem(title: $0)] } ?? [],
            switchTitle.map {
                [DashboardMenuItem(title: $0.title, command: .switchAccount($0.profileID), isDisabled: $0.isDisabled)]
            } ?? [],
            [
                DashboardMenuItem(
                    title: L10n.dashboard("Refresh"), command: .refresh([account.id]), isDisabled: refreshDisabled)
            ]
                + (canRename
                    ? [
                        DashboardMenuItem(
                            title: L10n.dashboard("Rename"), command: .rename(account.id), isDisabled: renameDisabled)
                    ] : []) + [
                    DashboardMenuItem(title: L10n.dashboard("Edit Account…"), command: .editAccount(account.id)),
                    DashboardMenuItem(title: L10n.dashboard("Share Screenshot"), command: .shareScreenshot(account.id))
                ]
        ].filter { !$0.isEmpty }
    }
}

struct DashboardMenu: View {
    let sections: DashboardMenus.Sections
    let perform: (DashboardCommand) -> Void

    var body: some View {
        ForEach(sections.indices, id: \.self) { index in
            if index > 0 { Divider() }
            ForEach(sections[index].indices, id: \.self) { item in
                let entry = sections[index][item]
                Button {
                    if let command = entry.command { perform(command) }
                } label: {
                    if let systemImage = entry.systemImage {
                        Label(entry.title, systemImage: systemImage)
                    } else {
                        Text(entry.title)
                    }
                }
                .disabled(entry.command == nil || entry.isDisabled)
            }
        }
    }
}
