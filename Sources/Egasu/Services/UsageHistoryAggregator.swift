import Foundation

enum UsageHistoryAggregator {
    /// machine-local로 명시 선언된 provider만 결합 — Cursor 등 account-wide history는 malformed/future 파일에 있어도 제외.
    static func merged(
        localSnapshots: [String: ProviderSnapshot],
        peerDocuments: [UsageHistoryDocument],
        descriptors: [String: UsageHistoryDescriptor],
        now: Date = Date()
    ) -> [String: ProviderUsageHistory] {
        var pairs: [(String, ProviderUsageHistory)] = []
        for document in UsageHistoryDocument.newestByDevice(peerDocuments) {
            for (providerID, history) in document.providers {
                pairs.append((providerID, history))
            }
        }
        return merged(localSnapshots: localSnapshots, peerHistories: pairs, descriptors: descriptors, now: now)
    }

    /// identity 재매핑 변형 — peer는 (로컬 카드 id, history) 쌍으로 도착(`PeerHistoryRemapper`).
    /// 같은 계정은 Mac별 default/추가 카드 구분과 무관하게 같은 카드로 merge.
    static func merged(
        localSnapshots: [String: ProviderSnapshot],
        peerHistories: [(String, ProviderUsageHistory)],
        descriptors: [String: UsageHistoryDescriptor],
        now: Date = Date()
    ) -> [String: ProviderUsageHistory] {
        var inputs: [String: [ProviderUsageHistory]] = [:]
        for (providerID, descriptor) in descriptors where descriptor.scope == .machineLocal {
            if let local = localSnapshots[providerID]?.usageHistory {
                inputs[providerID, default: []].append(local)
            }
            for (peerID, history) in peerHistories where peerID == providerID {
                inputs[providerID, default: []].append(history)
            }
        }
        let includedDays = UsageHistoryWindow.dayKeys(through: now)
        return inputs.mapValues { merge($0, includedDays: includedDays) }
    }

    /// 여러 history의 일 단위 합산 병합 — per-card 경로와 동일한 merge, 로컬 카드 없는 remote-only 계정용 노출.
    static func mergeHistories(_ histories: [ProviderUsageHistory], now: Date = Date()) -> ProviderUsageHistory {
        merge(histories, includedDays: UsageHistoryWindow.dayKeys(through: now))
    }

    private static func merge(
        _ histories: [ProviderUsageHistory],
        includedDays: Set<String>
    ) -> ProviderUsageHistory {
        var unknown: [String: Set<String>] = [:]
        var budget = TokenBudget()
        var rejected = false

        for history in histories {
            guard let nextBudget = budget.adding(history, includedDays: includedDays) else {
                rejected = true
                AppDiagnostics.record(
                    .historyScan, result: .degraded, category: .decoding,
                    localContext: "source=icloud; history contribution exceeds token range")
                continue
            }
            budget = nextBudget
            rejected = rejected || history.hasRejectedNumericContributions
            for (day, names) in history.unknownModelsByDay where includedDays.contains(day) {
                unknown[day, default: []].formUnion(names)
            }
        }

        let series = DailyUsageSeries(
            daily: budget.days.map { date, value in
                DailyUsageEntry(
                    date: date,
                    totalTokens: value.tokens,
                    costUSD: value.cost.value
                )
            }.sorted { $0.date > $1.date })

        let modelDays = budget.models.map { date, byName in
            DailyModelUsageEntry(
                date: date,
                models: byName.values.map(\.entry).sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            )
        }.sorted { $0.date > $1.date }

        var result = ProviderUsageHistory(
            series: series,
            modelUsage: modelDays.isEmpty ? nil : ModelUsageSeries(daily: modelDays),
            unknownModelsByDay: unknown
        )
        result.hasRejectedNumericContributions = rejected
        return result
    }

    /// 기여 전체를 적용하기 전에 일별 병합과 렌더러가 실제 합산하는 키별 범위 확인.
    private struct TokenBudget {
        var series = 0
        var days: [String: (tokens: Int, cost: UsageCostTotal)] = [:]
        var models: [String: [String: ModelAccumulator]] = [:]

        func adding(_ history: ProviderUsageHistory, includedDays: Set<String>) -> Self? {
            var next = self
            for day in history.series.daily where includedDays.contains(day.date) {
                guard let total = UsageLogNumbers.sum(next.series, day.totalTokens) else { return nil }
                next.series = total
                var value = next.days[day.date] ?? (0, UsageCostTotal())
                value.tokens += day.totalTokens
                if day.totalTokens != 0 || day.costUSD != nil { value.cost.add(day.costUSD) }
                next.days[day.date] = value
            }
            for day in history.modelUsage?.daily ?? [] where includedDays.contains(day.date) {
                for model in day.models {
                    let key = model.model.lowercased()
                    let previous = next.models[day.date]?[key] ?? ModelAccumulator()
                    guard let merged = previous.adding(model) else { return nil }
                    next.models[day.date, default: [:]][key] = merged
                }
            }
            return next.supportsModelBreakdown ? next : nil
        }

        private var supportsModelBreakdown: Bool {
            let cost = days.values.reduce(into: UsageCostTotal()) { total, day in
                if day.tokens != 0 || day.cost.value != nil { total.add(day.cost.value) }
            }.value
            // 비음수 토큰·비용에서 개별 spend 행이 있으면 전체 기간 행도 존재.
            guard series > 0 || (cost ?? 0) > 0 else { return true }
            var tokens: [String: Int] = [:]
            var variants: [String: [String: Int]] = [:]
            for (date, day) in models where days[date] != nil {
                for accumulator in day.values {
                    let model = accumulator.entry
                    guard model.totalTokens > 0 || (model.costUSD ?? 0) > 0 else { continue }
                    let trimmed = model.model.trimmingCharacters(in: .whitespacesAndNewlines)
                    let name = trimmed.isEmpty ? ModelUsageEntry.unattributedModelName : trimmed
                    let key = name.lowercased()
                    guard let total = UsageLogNumbers.sum(tokens[key, default: 0], model.totalTokens) else {
                        return false
                    }
                    tokens[key] = total
                    let displayedVariants =
                        model.variants ?? [
                            ModelUsageVariant(model: name, totalTokens: model.totalTokens, costUSD: model.costUSD)
                        ]
                    for variant in displayedVariants {
                        let slug = variant.model.lowercased()
                        guard
                            let total = UsageLogNumbers.sum(
                                variants[key]?[slug] ?? 0, variant.totalTokens
                            )
                        else { return false }
                        variants[key, default: [:]][slug] = total
                    }
                }
            }
            return true
        }
    }

    private struct ModelAccumulator {
        var displayName = ""
        var tokens = 0
        var cost = UsageCostTotal()
        var variants: [String: VariantAccumulator] = [:]

        func adding(_ model: ModelUsageEntry) -> Self? {
            guard let total = UsageLogNumbers.sum(tokens, model.totalTokens) else { return nil }
            var next = self
            if next.displayName.isEmpty { next.displayName = model.model }
            next.tokens = total
            if model.totalTokens != 0 || model.costUSD != nil { next.cost.add(model.costUSD) }
            for variant in model.variants ?? [] {
                let key = variant.model.lowercased()
                let previous = next.variants[key] ?? VariantAccumulator(name: variant.model)
                guard let merged = previous.adding(variant) else { return nil }
                next.variants[key] = merged
            }
            return next
        }

        var entry: ModelUsageEntry {
            let mergedVariants = variants.values.map(\.entry)
                .sorted { $0.model.localizedStandardCompare($1.model) == .orderedAscending }
            return ModelUsageEntry(
                model: displayName,
                totalTokens: tokens,
                costUSD: cost.value,
                variants: mergedVariants.isEmpty ? nil : mergedVariants
            )
        }
    }

    private struct VariantAccumulator {
        var name: String
        var tokens = 0
        var cost = UsageCostTotal()

        func adding(_ variant: ModelUsageVariant) -> Self? {
            guard let total = UsageLogNumbers.sum(tokens, variant.totalTokens) else { return nil }
            var next = self
            next.tokens = total
            if variant.totalTokens != 0 || variant.costUSD != nil { next.cost.add(variant.costUSD) }
            return next
        }

        var entry: ModelUsageVariant {
            ModelUsageVariant(model: name, totalTokens: tokens, costUSD: cost.value)
        }
    }
}

enum UsageHistorySnapshotRenderer {
    static let sharedHistoryPrefix = "Across your Macs · "
    private static let historyLabels: Set<String> = ["Today", "Yesterday", "Last 30 Days", "Usage Trend"]

    static func render(
        local snapshot: ProviderSnapshot,
        history: ProviderUsageHistory,
        descriptor: UsageHistoryDescriptor,
        now: Date = Date(),
        combined: Bool = true
    ) -> ProviderSnapshot {
        var result = snapshot
        result.lines.removeAll { historyLabels.contains($0.label) }
        let sourceNote = combined ? sharedHistoryPrefix + descriptor.sourceNote : descriptor.sourceNote
        SpendTileMapper.appendTokenUsage(
            history.series,
            to: &result.lines,
            now: now,
            estimated: history.estimatedCost ?? descriptor.estimatedCost,
            unknownModelsByDay: history.unknownModelsByDay,
            modelUsage: history.modelUsage,
            modelSourceNote: sourceNote
        )
        SpendTileMapper.appendUsageTrend(
            history.series,
            to: &result.lines,
            now: now,
            note: sourceNote
        )
        if history.hasRejectedNumericContributions {
            addInvalidHistoryWarning(to: &result)
        }
        return result
    }

    static func addInvalidHistoryWarning(to snapshot: inout ProviderSnapshot) {
        let previousFailure = snapshot.partialRefreshErrorCategory
        let warning = UsageHistoryDocumentError.invalidValue.localizedDescription
        let presentation = LocalizedMessage(warning)
        var presentations = snapshot.warningPresentation ?? snapshot.warning.map { [.verbatim($0)] } ?? []
        if snapshot.warning != warning && !presentations.contains(presentation) {
            snapshot.warning = [snapshot.warning, warning].compactMap { $0 }.joined(separator: " ")
            presentations.append(presentation)
        }
        snapshot.warningPresentation = presentations
        snapshot.isDegraded = true
        snapshot.reportedPartialFailure = previousFailure ?? .decoding
    }
}
