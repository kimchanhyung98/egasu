import Foundation

/// 조직별 Copilot 크레딧 수와 순청구액을 Org Credits·Org Spend로 집계. 누락·잘못된 숫자·음수는 0으로 처리.
/// 개인 Credits와 별도인 조직 전체 합계. 할당량이 없어 사용 비율은 생성하지 않음.
enum CopilotOrgBillingMapper {
    /// 읽을 수 있는 조직은 순서대로 유지하고, 누락한 조직이 있으면 탐색 결과에 표시.
    static func orgLogins(_ response: HTTPResponse) throws -> (logins: [String], incomplete: Bool) {
        guard let entries = try? JSONSerialization.jsonObject(with: response.body) as? [Any] else {
            throw CopilotUsageError.invalidResponse
        }
        let logins = entries.compactMap { entry in
            ((entry as? [String: Any])?["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
        return (logins, logins.count != entries.count)
    }

    /// 정상 응답에 Copilot 크레딧 항목이 없으면 다음 조직 조회 허용.
    static func usageLines(_ response: HTTPResponse) throws -> [MetricLine]? {
        guard let body = ProviderParse.jsonObject(response.body) else { throw CopilotUsageError.invalidResponse }
        return try usageLines(body: body)
    }

    static func usageLines(body: [String: Any]) throws -> [MetricLine]? {
        guard let items = body["usageItems"] as? [[String: Any]] else { throw CopilotUsageError.invalidResponse }

        let creditItems = items.filter { item in
            isCopilot(item["product"]) && isCreditUnit(item["unitType"])
        }
        guard !creditItems.isEmpty else { return nil }

        let credits = creditItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["grossQuantity"]) ?? 0) }
        let spend = creditItems.reduce(0.0) { $0 + max(0, ProviderParse.number($1["netAmount"]) ?? 0) }

        return [
            .values(label: "Org Credits", values: [MetricValue(number: credits, kind: .count, label: "credits")]),
            .values(label: "Org Spend", values: [MetricValue(number: spend, kind: .dollars)])
        ]
    }

    private static func isCopilot(_ value: Any?) -> Bool {
        guard let product = value as? String else { return false }
        return product.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "copilot"
    }

    private static func isCreditUnit(_ value: Any?) -> Bool {
        guard let unit = value as? String else { return false }
        let normalized = unit.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return normalized == "ai-units" || normalized == "ai-credits"
    }
}
