import Foundation

/// 조직별 Copilot 크레딧 수와 순청구액을 Org Credits·Org Spend로 집계. 누락·잘못된 숫자·음수는 0으로 처리.
/// 개인 Credits와 별도인 조직 전체 합계. 할당량이 없어 사용 비율은 생성하지 않음.
enum CopilotOrgBillingMapper {
    /// `/user/orgs`의 조직 식별자를 응답 순서대로 반환. 해석 실패는 빈 배열.
    static func orgLogins(_ response: HTTPResponse) -> [String] {
        guard let array = try? JSONSerialization.jsonObject(with: response.body) as? [[String: Any]] else {
            return []
        }
        return array.compactMap { entry in
            (entry["login"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    /// 조직 청구 요약을 지표로 변환. Copilot AI 크레딧 항목이 없으면 nil로 다음 조직 조회 허용.
    /// `unitType`이 `ai-units`·`ai-credits`인 항목만 집계하여 좌석 요금 등 다른 단위 제외.
    static func usageLines(_ response: HTTPResponse) -> [MetricLine]? {
        guard let body = ProviderParse.jsonObject(response.body) else { return nil }
        return usageLines(body: body)
    }

    static func usageLines(body: [String: Any]) -> [MetricLine]? {
        guard let items = body["usageItems"] as? [[String: Any]] else { return nil }

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
