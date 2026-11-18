import SwiftUI

/// Usage Trend 상세 팝오버 — 확대 막대 차트, 최고값·호버한 날짜의 수치, 출처 안내.
struct UsageTrendDetail: View {
    let title: String
    let points: [MetricChartPoint]
    let note: String?
    /// 커서의 팝오버 내부 여부 보고 — 행에서 차트로 이동하는 동안 열림 유지용.
    var onHoverChange: (Bool) -> Void

    @State private var activeIndex: Int?

    private static let chartHeight: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            chart
            axis
            if let note, !note.isEmpty {
                PopoverSourceNote(text: note)
            }
        }
        .padding(UsageBreakdownDetail.padding)
        .frame(width: UsageBreakdownDetail.width)
        // 열린 상태에서 데이터가 바뀌면 선택을 해제하여 이전 강조 표시 제거.
        .onChange(of: points) { activeIndex = nil }
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false); activeIndex = nil
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(readout)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        let maxValue = max(1, points.map(\.value).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 2) {
            ForEach(points.indices, id: \.self) { index in
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: Self.chartHeight)
                    // 짧은 막대도 쉽게 선택하도록 열 전체를 호버 대상으로 사용.
                    .overlay(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(Theme.meterFill(.normal))
                            .frame(height: barHeight(points[index].value, max: maxValue))
                            .opacity(activeIndex == nil || activeIndex == index ? 1 : 0.35)
                    }
                    .contentShape(Rectangle())
                    .onContinuousHover { phase in
                        if case .active = phase { activeIndex = index }
                    }
            }
        }
        .frame(height: Self.chartHeight)
        // 막대 영역을 벗어나면 선택 해제 — 표시 수치를 최고값으로 복원.
        .onContinuousHover { phase in if case .ended = phase { activeIndex = nil } }
        .animation(.easeOut(duration: 0.12), value: activeIndex)
    }

    private var axis: some View {
        HStack {
            Text(points.first?.localizedLabel ?? "")
            Spacer()
            Text(points.last?.localizedLabel ?? "")
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }

    private var peakIndex: Int? { points.indices.max { points[$0].value < points[$1].value } }

    /// 포인터가 가리키는 날짜의 수치 — 선택이 없으면 최고값.
    private var readout: String {
        if let activeIndex, points.indices.contains(activeIndex) {
            return "\(points[activeIndex].localizedLabel) · \(points[activeIndex].localizedReadout)"
        }
        if let peakIndex { return L10n.dashboard("peak %@", points[peakIndex].localizedReadout) }
        return ""
    }

    private func barHeight(_ value: Double, max maxValue: Double) -> CGFloat {
        guard value > 0 else { return 2 }
        return max(Self.chartHeight * 0.06, Self.chartHeight * min(1, value / maxValue))
    }
}

// 호버 열기·닫기 상태는 모델별 내역 팝오버와 같은 HoverPopoverState 사용.
