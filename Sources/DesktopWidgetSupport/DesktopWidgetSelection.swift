import Foundation

public struct DesktopWidgetSelection: Hashable, Sendable, Identifiable {
    public let accountID: String
    public let metricID: String

    public init(accountID: String, metricID: String) {
        self.accountID = accountID
        self.metricID = metricID
    }

    /// App Intents가 보관하는 식별자에 계정·지표의 구분 문자가 섞여도 선택 보존.
    public var id: String {
        Data(accountID.utf8).base64EncodedString() + "." + Data(metricID.utf8).base64EncodedString()
    }

    public init?(id: String) {
        let parts = id.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let account = Data(base64Encoded: String(parts[0])), !account.isEmpty,
            let accountID = String(data: account, encoding: .utf8),
            let metric = Data(base64Encoded: String(parts[1])), !metric.isEmpty,
            let metricID = String(data: metric, encoding: .utf8)
        else { return nil }
        self.init(accountID: accountID, metricID: metricID)
    }
}

public struct DesktopSelectedAccount: Identifiable, Sendable {
    public let id: String
    public let account: DesktopWidgetAccount?
    public let metrics: [DesktopWidgetMetric]
}

public struct DesktopWidgetPage: Sendable {
    public let accounts: [DesktopSelectedAccount]
    public let remainingAccounts: Int
    public let remainingMetrics: Int
}

extension DesktopWidgetContent {
    /// 계정 순서는 위젯 선택, 지표 순서는 앱 설정 기준. 누락된 계정도 원래 자리에 표시.
    public func selectedAccounts(
        _ selections: [DesktopWidgetSelection], maximumAccounts: Int, maximumMetrics: Int
    ) -> DesktopWidgetPage {
        var accountIDs = [String]()
        var metricsByAccount = [String: Set<String>]()
        for selection in selections {
            if metricsByAccount[selection.accountID] == nil { accountIDs.append(selection.accountID) }
            metricsByAccount[selection.accountID, default: []].insert(selection.metricID)
        }

        var remainingMetrics = 0
        let page = accountIDs.prefix(max(0, maximumAccounts)).map { id in
            let account = accounts.first { $0.id == id }
            let selected = metricsByAccount[id] ?? []
            let metrics = account?.metrics.filter { selected.contains($0.id) } ?? []
            let visible = Array(metrics.prefix(max(0, maximumMetrics)))
            remainingMetrics += metrics.count - visible.count
            return DesktopSelectedAccount(id: id, account: account, metrics: visible)
        }
        return DesktopWidgetPage(
            accounts: page, remainingAccounts: accountIDs.count - page.count, remainingMetrics: remainingMetrics
        )
    }
}
