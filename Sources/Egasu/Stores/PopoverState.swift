import Observation
import SwiftUI

/// 패널 안 화면 — Accounts·Settings는 대시보드를 제자리 교체, Esc는 한 단계씩 뒤로.
enum PopoverScreen: Hashable, Sendable {
    case dashboard
    case accounts
    case settings

    /// 화면 전환 방향 — 높은 순위는 trailing, 낮은 순위는 leading에서 진입.
    var slideRank: Int {
        switch self {
        case .dashboard: 0
        case .accounts: 1
        case .settings: 2
        }
    }
}

/// Settings 탭 — 탭 막대의 SF Symbol과 제목.
enum SettingsTab: Hashable, Sendable, CaseIterable {
    case general, display, alerts, advanced

    var title: String {
        switch self {
        case .general: L10n.settings("General")
        case .display: L10n.settings("Display")
        case .alerts: L10n.settings("Alerts")
        case .advanced: L10n.settings("Advanced")
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .display: "macwindow"
        case .alerts: "bell"
        case .advanced: "terminal"
        }
    }
}

/// 패널 탐색 상태 단일 출처 — 화면, 대시보드 탭, Settings 탭, 계정 상세·추가 시트, 표시 여부.
/// UI 전용이라 저장하지 않음.
@MainActor
@Observable
final class PopoverState {
    var screen = PopoverScreen.dashboard {
        didSet {
            guard screen != oldValue else { return }
            // onChange는 한 프레임 늦으므로 전환 이전 화면을 동기 기록하여 다음 렌더링부터 이동 효과 적용.
            screenSlideFrom = oldValue
            screenSlideID += 1
            if screen != .accounts {
                accountDetailID = nil
                isAddingAccount = false
            }
        }
    }
    private(set) var screenSlideFrom = PopoverScreen.dashboard
    private(set) var screenSlideID = 0
    /// Accounts 화면에서 상세를 연 계정(카드 ID) — nil이면 목록.
    var accountDetailID: String?
    var isAddingAccount = false
    /// 계정 추가 시트가 새 계정 대신 다시 로그인하는 계정(카드 ID).
    var signingInAgainAccountID: String?
    var dashboardTab: DashboardTab
    var settingsTab = SettingsTab.general
    /// 패널 표시 여부 — makeKeyAndOrderFront·orderOut과 동기 변경.
    /// 창 가림·키 창 상태로 추정하지 않음 — Space 전환 중 잠깐 가려지는 상태와 닫힘 구분.
    var popoverShown = false

    let shareNotice = TransientNotice<Bool>(clearedValue: false, timeout: .seconds(2.5))

    init(dashboardTab: DashboardTab = .allUsage) {
        self.dashboardTab = dashboardTab
    }

    /// 한 단계 뒤로 — 계정 상세 → 목록 → 대시보드. 대시보드면 false(패널 닫기).
    @discardableResult
    func back() -> Bool {
        if accountDetailID != nil {
            withAnimation(Motion.navigation) { accountDetailID = nil }
            return true
        }
        guard screen != .dashboard else { return false }
        withAnimation(Motion.modeSwitch) { screen = .dashboard }
        return true
    }

    func toggle(_ target: PopoverScreen) {
        withAnimation(Motion.modeSwitch) { screen = screen == target ? .dashboard : target }
    }

    func openAccounts(_ accountID: String?) {
        withAnimation(Motion.modeSwitch) {
            accountDetailID = accountID
            screen = .accounts
        }
    }

    /// 카드 ID가 바뀌거나 저장 로그인이 사라져도 같은 등록 계정의 상세 유지 — 등록 삭제 시 목록 복귀.
    func reconcileAccountDetail(
        in registry: WidgetRegistry,
        previousProfileIDsByCard: [String: String],
        nextProfileIDsByCard: [String: String],
        registeredProfiles: [AccountProfile]? = nil
    ) {
        guard let cardID = accountDetailID else { return }
        guard
            let profileID = previousProfileIDsByCard[cardID]
                ?? AccountCardPresentationPlanner.snapshotProfileID(for: cardID, profiles: registeredProfiles ?? [])
        else {
            if registry.provider(id: cardID) == nil { accountDetailID = nil }
            return
        }
        if let registeredProfiles, !registeredProfiles.contains(where: { $0.id == profileID && !$0.isArchived }) {
            accountDetailID = nil
            return
        }
        if nextProfileIDsByCard[cardID] == profileID, registry.provider(id: cardID) != nil { return }
        let family = ProviderAccountID.family(of: cardID)
        let snapshotID = AccountUsageCardPlanner.cardID(family: family, profileID: profileID)
        accountDetailID = [snapshotID, family].first {
            nextProfileIDsByCard[$0] == profileID && registry.provider(id: $0) != nil
        }
        if accountDetailID == nil, registry.provider(id: family) != nil,
            AccountCardPresentationPlanner.snapshotProfileID(for: snapshotID, profiles: registeredProfiles ?? [])
                == profileID
        {
            accountDetailID = snapshotID
        }
    }

    func showDashboard(on tab: DashboardTab) {
        dashboardTab = tab
        withAnimation(Motion.modeSwitch) { screen = .dashboard }
    }

    func show(dashboardTab: DashboardTab? = nil) {
        if let dashboardTab { self.dashboardTab = dashboardTab }
        popoverShown = true
    }

    /// 패널 닫힘 시 초기화 — 대시보드 탭 유지, 대시보드 화면·General 탭 복귀, 복사 알림 해제.
    func reset() {
        if screen != .dashboard { screen = .dashboard }
        settingsTab = .general
        shareNotice.clear()
    }
}
