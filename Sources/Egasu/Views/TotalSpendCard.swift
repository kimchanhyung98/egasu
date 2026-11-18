import AppKit
import SwiftUI

/// 여러 프로바이더의 Total Spend 카드 — 데이터 없는 조합은 빈 상태 표시.
struct TotalSpendCard: View {
    @Environment(LayoutStore.self) private var layout
    @Environment(WidgetDataStore.self) private var dataStore
    @Environment(AppContainer.self) private var container
    @Environment(PopoverState.self) private var popover
    @Environment(\.colorScheme) private var colorScheme
    @Namespace private var pickerNamespace

    /// 선택 기간 — 팝오버 닫힘·재실행에도 유지.
    @AppStorage("openusage.totalSpend.period") private var periodRawValue = TotalSpendPeriod.today.rawValue
    /// 선택 지표 — 팝오버 닫힘·재실행에도 유지.
    @AppStorage("openusage.totalSpend.metric") private var metricRawValue = TotalSpendMetric.cost.rawValue

    private var period: TotalSpendPeriod {
        TotalSpendPeriod(rawValue: periodRawValue) ?? .today
    }

    private var metric: TotalSpendMetric {
        TotalSpendMetric(rawValue: metricRawValue) ?? .cost
    }

    /// 기간별 지출 집계를 지원하는 프로바이더만 합산.
    /// 지표 행을 숨겨도 집계 대상에 포함, 달러 단위의 유사 지표만 있는 프로바이더는 제외.
    private var providers: [Provider] {
        layout.spendCapableProviders
    }

    private var total: TotalSpend {
        // 다른 Mac에만 있는 동기화 계정도 합계·범례에 포함 — 현재 기기의 로그인 여부와 무관.
        var aggregatedProviders = providers
        var aggregatedSnapshots = dataStore.snapshots
        for entry in dataStore.remoteOnlySpend {
            aggregatedProviders.append(entry.provider)
            aggregatedSnapshots[entry.provider.id] = entry.snapshot
        }
        // 현재 계정 목록에서 제목을 해석하여 범례·공유 이미지에도 이름 변경 즉시 반영.
        return TotalSpendAggregator.total(
            for: period,
            providers: aggregatedProviders,
            snapshots: aggregatedSnapshots,
            title: { container.displayName(for: $0) }
        )
    }

    private var projection: TotalSpendProjection {
        total.projection(for: metric)
    }

    var body: some View {
        card
            .contextMenu {
                Button {
                    guard ShareCardRenderer.shareTotalSpend(
                        total: total, metric: metric, appearance: colorScheme
                    ) else { return }
                    popover.shareNotice.present(true)
                } label: {
                    Label(L10n.dashboard("Share Screenshot"), systemImage: "square.and.arrow.up")
                }
                .disabled(projection.isEmpty)
            }
    }

    private func cycleMetric() {
        metricRawValue = metric.next.rawValue
    }

    // MARK: - Card

    private var card: some View {
        VStack(spacing: 14) {
            periodPicker
            if projection.isEmpty {
                emptyState
            } else {
                TotalSpendRingContent(projection: projection, onCycleMetric: cycleMetric)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity)
        .cardSurface()
        .animation(Motion.spring, value: periodRawValue)
        .animation(Motion.spring, value: metricRawValue)
    }

    private var periodPicker: some View {
        HStack(spacing: 2) {
            ForEach(TotalSpendPeriod.allCases) { candidate in
                periodSegment(candidate)
            }
        }
        .padding(3)
        .background(.quinary, in: Capsule())
        .frame(maxWidth: .infinity)
    }

    private func periodSegment(_ candidate: TotalSpendPeriod) -> some View {
        let isSelected = candidate == period
        return Button {
            periodRawValue = candidate.rawValue
        } label: {
            Text(candidate.shortLabel)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background {
            if isSelected {
                Capsule()
                    .fill(.background)
                    .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
                    .matchedGeometryEffect(id: "totalSpendPeriod", in: pickerNamespace)
            }
        }
        .animation(Motion.spring, value: periodRawValue)
    }

    /// 표시할 데이터가 없으면 빈 상태 표시 — 사용량 0의 링으로 대체하지 않음.
    private var emptyState: some View {
        Text(metric.emptyMessage)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .modifier(TotalSpendMetricSwitch(metric: metric, action: cycleMetric))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
    }
}

/// 대시보드와 공유 이미지가 사용하는 공통 링.
/// 프로바이더 ID로 조각을 식별하여 기간 전환 시 각도만 변경.
struct TotalSpendRingContent: View {
    let projection: TotalSpendProjection
    var onCycleMetric: (() -> Void)?

    private static let ringDiameter: CGFloat = 104
    private static let innerRadiusRatio: CGFloat = 0.618

    var body: some View {
        HStack(spacing: 18) {
            ring
            legend
        }
    }

    // MARK: - Ring

    /// 아주 작은 사용량도 보이도록 최소 조각 비율 적용 — 범례·중앙 수치는 실제 값 유지.
    private static let minimumSliceShare = 0.025

    private var ring: some View {
        ZStack {
            // 프로바이더 ID가 유지되면 각도만 변경 — 추가·제거는 불투명도로 전환.
            ForEach(arcs) { arc in
                RingSectorShape(startFraction: arc.start, endFraction: arc.end, innerRadiusRatio: Self.innerRadiusRatio)
                    .fill(TotalSpendPalette.color(for: arc.providerID))
                    .accessibilityHidden(true)
            }
            centerLabel
        }
        .frame(width: Self.ringDiameter, height: Self.ringDiameter)
    }

    private var accessibilityLabel: String {
        let center = formatValue(projection.centerValue, style: .full)
        switch projection.metric {
        case .cost:
            return L10n.dashboard("Total cost %@ across %d providers", center, projection.slices.count)
        case .tokens:
            return L10n.dashboard("Total tokens %@ across %d providers", center, projection.slices.count)
        case .costPerMtok:
            return L10n.dashboard("Blended cost per megatoken %@ across %d providers", center, projection.slices.count)
        }
    }

    private struct RingArc: Identifiable, Equatable {
        let providerID: String
        var start: Double
        var end: Double

        var id: String { providerID }
    }

    /// 최소 점유율 적용 후 합계가 1이 되도록 다시 정규화한 링 구간.
    private var arcs: [RingArc] {
        let totalDisplay = projection.slices.reduce(0) { $0 + $1.displayAmount }
        guard totalDisplay > 0 else { return [] }
        let floored = projection.slices.map { max($0.displayAmount / totalDisplay, Self.minimumSliceShare) }
        let sum = floored.reduce(0, +)
        guard sum > 0 else { return [] }

        var cursor = 0.0
        return zip(projection.slices, floored).map { slice, share in
            let width = share / sum
            defer { cursor += width }
            return RingArc(providerID: slice.provider.id, start: cursor, end: cursor + width)
        }
    }

    private var centerLabel: some View {
        let center = MetricFormatter.totalSpendRingCenter(projection.centerValue, metric: projection.metric)
        return VStack(spacing: 1) {
            Text(center.primary)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(center.unit)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .frame(width: Self.ringDiameter * Self.innerRadiusRatio, height: Self.ringDiameter * Self.innerRadiusRatio)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .modifier(TotalSpendMetricSwitch(metric: projection.metric, action: onCycleMetric, circular: true))
        .hoverTooltip(centerTooltip)
    }

    private var centerTooltip: String {
        let exact = formatValue(projection.centerValue, style: .full)
        if projection.isEstimated {
            return "\(exact) · \(L10n.metrics(WidgetData.localEstimateNote))"
        }
        return exact
    }

    // MARK: - Legend

    private var legend: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(projection.slices) { slice in
                legendRow(slice)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func legendRow(_ slice: TotalSpendProjectedSlice) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(TotalSpendPalette.color(for: slice.provider.id))
                .frame(width: 8, height: 8)
            Text(slice.title)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 8)
            // 토큰 범례는 자릿수 넘침을 피하도록 축약 — 비용은 센트 단위 유지.
            Text(formatValue(slice.displayAmount, style: legendValueStyle))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .accessibilityLabel("\(slice.title), \(formatValue(slice.displayAmount, style: legendValueStyle))")
                .modifier(TotalSpendMetricSwitch(metric: projection.metric, action: onCycleMetric))
        }
    }

    private var legendValueStyle: MetricFormatter.Style {
        switch projection.metric {
        case .tokens: .row
        case .cost, .costPerMtok: .full
        }
    }

    private func formatValue(_ value: Double, style: MetricFormatter.Style) -> String {
        switch projection.metric {
        case .cost:
            return MetricFormatter.number(value, kind: .dollars, style: style)
        case .tokens:
            return MetricFormatter.number(value, kind: .count, style: style)
        case .costPerMtok:
            return MetricFormatter.costPerMtok(value, style: style)
        }
    }
}

/// 클릭 가능한 통계 값 — 공유 이미지에서는 동작 없이 원래 내용만 표시.
private struct TotalSpendMetricSwitch: ViewModifier {
    let metric: TotalSpendMetric
    let action: (() -> Void)?
    var circular = false
    @State private var isHovered = false

    private var hitShape: AnyShape { circular ? AnyShape(Circle()) : AnyShape(Rectangle()) }

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            Button(action: action) {
                content.contentShape(hitShape)
            }
            .buttonStyle(.plain)
            .hoverHighlight(isHovered && !circular)
            .background {
                if circular {
                    Circle().fill(.quaternary)
                        .opacity(isHovered ? 1 : 0)
                        .animation(.easeOut(duration: 0.12), value: isHovered)
                }
            }
            .contentShape(hitShape)
            .onHover { isHovered = $0 }
            .accessibilityValue(metric.title)
            .accessibilityHint(L10n.dashboard("Switch to %@", metric.next.title))
        } else {
            content
        }
    }
}

/// 프로바이더 ID에 고정된 브랜드 색상 — 기간·순위 변화에도 색 유지.
/// 검정 브랜드는 밝은·어두운 모드 모두 읽을 수 있는 동적 색상 사용.
enum TotalSpendPalette {
    private static let byProviderID: [String: Color] = [
        "claude": hex(0xDE7356),
        "codex": hex(0x10A37F),
        "cursor": dynamic(light: 0x13120A, dark: 0xF5F5F7),  // 브랜드 블랙 (#13120A), 다크 모드에서 near-white 반전
        "grok": dynamic(light: 0x8E8E93, dark: 0x98989D),    // 브랜드 블랙, Cursor와 구분 위해 gray 오프셋
        "opencode": dynamic(light: 0x6E6E73, dark: 0xAEAEB2),  // OpenCode — grayscale 브랜드, medium gray
        "openrouter": hex(0x6467F2),
        "antigravity": hex(0x4285F4),
        "copilot": hex(0xA855F7),
        "amp": hex(0xF34E3F),
        "factory": dynamic(light: 0x48484A, dark: 0xC7C7CC),
        "kimi": hex(0x0A66FF),
        "minimax": hex(0xF5433C),
        "zai": dynamic(light: 0x2D2D2D, dark: 0xD1D1D6)
    ]

    /// 미등록 프로바이더의 대체 색상 — ID 기준으로 기간·재실행과 무관한 색 유지.
    private static let fallback: [Color] = [
        hex(0x34C759), hex(0x5856D6), hex(0xFF2D55), hex(0xA2845E)
    ]

    static func color(for providerID: String) -> Color {
        if let brand = byProviderID[providerID] { return brand }
        let stableHash = providerID.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        return fallback[stableHash % fallback.count]
    }

    private static func hex(_ value: UInt32) -> Color {
        Color(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }

    /// 검정 브랜드의 밝은·어두운 모드별 색상 — 어두운 카드에서도 식별 가능.
    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                red: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
