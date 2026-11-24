import AppIntents
import Foundation
import WidgetKit

enum UsageWidgetMode: String, AppEnum {
    case priority
    case allUsage

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Display Mode"
    static let caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .priority: "Priority",
        .allUsage: "All Usage"
    ]
}

struct UsageMetricEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Account Metric"
    static let defaultQuery = UsageMetricQuery()

    let id: String
    let label: String?

    var displayRepresentation: DisplayRepresentation {
        guard let label else { return DisplayRepresentation(title: "Unavailable Item") }
        return DisplayRepresentation(title: "\(label)")
    }
}

struct UsageMetricQuery: EntityQuery {
    func suggestedEntities() async throws -> [UsageMetricEntity] {
        guard case .snapshot(let snapshot) = DesktopWidgetStore().read() else { return [] }
        return snapshot.content.accounts.filter { $0.state != .unavailable }.flatMap { account in
            account.metrics.map { metric in
                let id = DesktopWidgetSelection(accountID: account.id, metricID: metric.id).id
                return UsageMetricEntity(id: id, label: "\(account.widgetName) · \(metric.name)")
            }
        }
    }

    func entities(for identifiers: [String]) async throws -> [UsageMetricEntity] {
        let available = try await suggestedEntities()
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        // 저장된 선택의 자리를 유지하되 사라진 계정의 이전 표시 이름은 재사용하지 않음.
        return identifiers.map { byID[$0] ?? UsageMetricEntity(id: $0, label: nil) }
    }
}

struct ConfigureUsageWidget: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Edit egasu"

    @Parameter(title: "Display Mode", default: .priority)
    var mode: UsageWidgetMode

    @Parameter(title: "Account Metrics", size: .init(min: 1, max: 9_223_372_036_854_775_807))
    var items: [UsageMetricEntity]?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$mode) {
            Case(UsageWidgetMode.allUsage) {
                Summary {
                    \.$mode
                    \.$items
                }
            }
            DefaultCase {
                Summary {
                    \.$mode
                }
            }
        }
    }
}
