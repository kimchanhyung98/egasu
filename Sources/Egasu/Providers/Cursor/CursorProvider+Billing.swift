import Foundation

extension CursorProvider {
    /// 통합 계정은 주간 공유 풀과 별도로 선불 잔액·월간 추가 사용을 조회.
    func mergedUsage(_ usage: [String: Any], planName: String?, token: String) async throws -> CursorMappedUsage {
        let facts = CursorPlanUsageFacts(usage: usage)
        guard facts.isEnabled else { throw CursorUsageError.noActiveSubscription }
        let cycle = CursorUsageMapper.billingCycle(from: usage)
        var mapped = CursorMappedUsage(plan: CursorUsageMapper.planLabel(planName), lines: [])
        if let percent = facts.totalPercentUsed {
            mapped.lines.append(
                .progress(
                    label: "Total usage", used: percent, limit: 100, format: .percent,
                    resetsAt: cycle.resetsAt, periodDurationMs: cycle.periodDurationMs))
        } else {
            mapped.incompleteQuotaWindows.insert(.weekly)
            noteDegraded(.cursorPlan, category: .decoding, localContext: "unified weekly usage missing")
        }
        if let balance = await fetchOptionalJSONObject(
            label: "unified-balance", operation: .cursorBalance,
            request: {
                try await self.usageClient.fetchUnifiedBalance(accessToken: token)
            })
        {
            // Connect 응답은 잔액이 0이면 필드 자체를 생략.
            let cents = balance["usdRemainingCents"].map(ProviderParse.number) ?? 0
            if let cents, cents >= 0 {
                mapped.lines.append(
                    .values(
                        label: "Credits",
                        values: [
                            MetricValue(number: ProviderParse.centsToDollars(cents), kind: .dollars)
                        ]))
            } else {
                noteDegraded(.cursorBalance, category: .decoding, localContext: "invalid unified credit balance")
            }
        }
        if let status = await fetchOptionalJSONObject(
            label: "usage-status", operation: .cursorFallback,
            request: {
                try await self.usageClient.fetchUsageStatus(accessToken: token)
            })
        {
            do {
                if let line = try Self.additionalUsage(status) { mapped.lines.append(line) }
            } catch {
                noteDegraded(.cursorFallback, category: .decoding, localContext: "invalid monthly additional usage")
            }
        }
        guard !mapped.lines.isEmpty else { throw CursorUsageError.invalidResponse }
        return mapped
    }

    static func additionalUsage(_ status: [String: Any]) throws -> MetricLine? {
        if let availability = status["availability"] as? String, availability != "available" { return nil }
        guard let monthly = status["monthlyUsage"] as? [String: Any] else { throw CursorUsageError.invalidResponse }
        if monthly["additionalUsageOff"] as? Bool == true { return nil }
        let rawLimit = monthly["limitCents"]
        let limit = ProviderParse.number(rawLimit)
        if limit == 0 { return nil }
        guard let used = ProviderParse.number(monthly["usedCents"]), used >= 0 else {
            throw CursorUsageError.invalidResponse
        }
        let dollars = ProviderParse.centsToDollars(used)
        guard let limit else {
            guard rawLimit == nil || rawLimit is NSNull else { throw CursorUsageError.invalidResponse }
            return .values(label: "On-demand", values: [MetricValue(number: dollars, kind: .dollars)])
        }
        guard limit > 0 else { throw CursorUsageError.invalidResponse }
        let reset = (monthly["resetsAt"] as? String).flatMap(EgasuISO8601.date(from:))
        let start = (monthly["periodStart"] as? String).flatMap(EgasuISO8601.date(from:))
        let duration = start.flatMap { start in
            reset.flatMap { Int(exactly: ($0.timeIntervalSince(start) * 1000).rounded()) }
        }
        return .progress(
            label: "On-demand", used: dollars, limit: ProviderParse.centsToDollars(limit), format: .dollars,
            resetsAt: reset, periodDurationMs: duration.flatMap { $0 > 0 ? $0 : nil })
    }

    func fetchCreditGrants(accessToken: String) async -> [String: Any]? {
        guard
            let body = await fetchOptionalJSONObject(
                label: "credit-grants", operation: .cursorCredits,
                request: {
                    try await self.usageClient.fetchCredits(accessToken: accessToken)
                })
        else {
            return nil
        }
        guard let hasCreditGrants = body["hasCreditGrants"] as? Bool else {
            noteDegraded(
                .cursorCredits, category: .decoding,
                localContext: "optional credit-grants response contained invalid grant metadata")
            return nil
        }
        if hasCreditGrants {
            guard let totalCents = ProviderParse.number(body["totalCents"]), totalCents > 0,
                let usedCents = ProviderParse.number(body["usedCents"]), usedCents >= 0
            else {
                noteDegraded(
                    .cursorCredits, category: .decoding,
                    localContext: "optional credit-grants response contained invalid grant metadata")
                return nil
            }
        }
        AppDiagnostics.record(.cursorCredits, result: .success, providerID: provider.id)
        return body
    }

    func fetchStripeBilling(accessToken: String) async -> (balanceCents: Double, isMerged: Bool) {
        guard
            let body = await fetchOptionalJSONObject(
                label: "prepaid-balance", operation: .cursorBalance,
                request: {
                    try await self.usageClient.fetchStripeBalance(accessToken: accessToken)
                })
        else {
            return (0, false)
        }
        let isMerged = (body["planAccess"] as? [String: Any])?["isMerged"] as? Bool == true
        guard ProviderParse.number(body["customerBalance"]) != nil else {
            noteDegraded(
                .cursorBalance, category: .decoding,
                localContext: "optional prepaid-balance response contained invalid balance metadata")
            return (0, isMerged)
        }
        AppDiagnostics.record(.cursorBalance, result: .success, providerID: provider.id)
        return (CursorUsageMapper.stripeBalanceCents(from: body), isMerged)
    }
}
