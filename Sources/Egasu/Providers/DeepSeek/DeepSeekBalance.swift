import Foundation

enum DeepSeekCurrency: String, CaseIterable, Decodable {
    case usd = "USD"
    case cny = "CNY"

    var valueKind: MetricKind { self == .usd ? .dollars : .count }
    var resourceKey: String { "balance\(rawValue)" }
    var balanceLabel: String { "Balance (\(rawValue))" }
    var toppedUpLabel: String { "Topped Up (\(rawValue))" }
    var grantedLabel: String { "Granted (\(rawValue))" }
}

struct DeepSeekBalance: Decodable, Sendable {
    let isAvailable: Bool
    let balanceInfos: [Entry]

    struct Entry: Decodable, Sendable {
        let currency: DeepSeekCurrency
        let totalBalance: String
        let toppedUpBalance: String
        let grantedBalance: String
    }

    func snapshot(for provider: Provider) throws -> ProviderSnapshot {
        var lines: [MetricLine] = []
        var presentations: [String: LocalizedMessage] = [:]
        var seen: Set<DeepSeekCurrency> = []
        for entry in balanceInfos {
            let currency = entry.currency
            guard seen.insert(currency).inserted, let total = Double(entry.totalBalance), total.isFinite,
                [entry.totalBalance, entry.toppedUpBalance, entry.grantedBalance].allSatisfy({
                    $0.wholeMatch(of: /-?[0-9]+(?:\.[0-9]+)?/) != nil
                })
            else { throw DeepSeekError.invalidResponse }
            lines.append(
                .values(
                    label: currency.balanceLabel,
                    values: [
                        MetricValue(number: total, kind: currency.valueKind, label: currency.rawValue)
                    ]))
            presentations[currency.balanceLabel] = .verbatim("\(currency.rawValue) \(entry.totalBalance)")
            lines.append(.text(label: currency.toppedUpLabel, value: entry.toppedUpBalance))
            lines.append(.text(label: currency.grantedLabel, value: entry.grantedBalance))
        }
        lines.append(.badge(label: "API Access", text: isAvailable ? "Available" : "Insufficient Balance"))
        return .make(
            provider: provider, plan: nil, lines: lines, refreshedAt: Date(), metricPresentations: presentations)
    }
}
