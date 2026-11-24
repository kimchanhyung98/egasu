import DesktopWidgetSupport
import Foundation

/// 앱 실행 중 들어온 클릭은 패널 준비 후 처리하고 여러 번 누르면 마지막 유효 목적지로 이동.
struct DesktopWidgetNavigation {
    private var pending: DesktopWidgetDestination?

    mutating func receive(_ urls: [URL], scheme: String) {
        if let destination = urls.reversed().lazy.compactMap({ DesktopWidgetDestination(url: $0, scheme: scheme) })
            .first
        {
            pending = destination
        }
    }

    mutating func take() -> DesktopWidgetDestination? {
        defer { pending = nil }
        return pending
    }
}

extension PopoverState {
    func openFromWidget(_ destination: DesktopWidgetDestination, cardID: (String) -> String?) {
        switch destination {
        case .priority where showsDashboardTabs:
            showDashboard(on: .priority)
        case .priority, .alerts:
            settingsTab = .alerts
            screen = .settings
        case .allUsage:
            showDashboard(on: .allUsage)
        case .account(let id):
            isAddingAccount = false
            openAccounts(cardID(id))
        }
    }
}
