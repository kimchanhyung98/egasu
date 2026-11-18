import SwiftUI

/// 기간 행의 호버 상세 — 요약·상위 모델·출처와 동일 내용 이미지 복사.
struct UsageBreakdownDetail: View {
    let usage: UsageBreakdown
    let providerName: String
    let icon: IconSource
    var onCopy: (ModelFigure) -> Bool
    var onHoverChange: (Bool) -> Void

    @AppStorage(ModelFigure.key) private var figure = ModelFigure.cost
    @Environment(\.reduceAnimations) private var reduceAnimations

    static let width: CGFloat = 288
    static let padding: CGFloat = 14

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            UsageBreakdownContent(
                usage: usage, providerName: providerName, icon: icon, figure: figure,
                figureSelection: $figure, animates: !reduceAnimations, now: context.date
            )
            .padding(Self.padding)
            .frame(width: Self.width, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .overlay(alignment: .topTrailing) {
                if !usage.isEmpty {
                    CopyFeedbackButton(
                        accessibilityLabel: L10n.metrics("Copy %@ Usage", usage.displayTitle(at: context.date))
                    ) { onCopy(figure) }
                    .padding(4)
                    .background(Theme.controlFill, in: Circle())
                    .padding(10)
                }
            }
        }
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }
}

/// 합계만 있고 모델 내역이 없는 기간 행의 상세 — 읽은 시각, 합계, 불러오는 중 또는 사유.
struct UsageBreakdownSavedDetail: View {
    let title: String
    let figures: [String]
    let savedAt: Date?
    let status: DashboardAccountStatus
    var onHoverChange: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    savedAt.map { "\(title) · \(L10n.metrics("Saved %@", Formatters.monthDayTimeLabel($0)))" } ?? title
                )
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                if let headline = figures.first {
                    Text(headline)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.5)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if figures.count > 1 {
                    Text(figures.dropFirst().joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if status.refreshing {
                HStack(spacing: 6) {
                    MotionAwareProgressView(controlSize: .small)
                    Text(L10n.metrics("Loading Breakdown…"))
                }
                .font(.callout)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.metrics("Breakdown Unavailable"))
                        .font(.callout.weight(.medium))
                    Text(UsageBreakdownSavedState.reason(notice: status.notice, staleness: status.staleness))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(UsageBreakdownDetail.padding)
        .frame(width: UsageBreakdownDetail.width, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .onContinuousHover { phase in
            switch phase {
            case .active: onHoverChange(true)
            case .ended: onHoverChange(false)
            }
        }
    }
}

/// 합계 패널의 사유 — 계정 공지 → 오래됨 안내 → 새로 고침 안내 중 하나.
enum UsageBreakdownSavedState {
    static func reason(notice: String?, staleness: StalenessHint?) -> String {
        notice ?? staleness?.tooltip ?? L10n.metrics("Refresh to load the details for this range.")
    }
}

/// 상세와 공유 이미지가 함께 쓰는 본문 — 수치 선택 바인딩이 있을 때 전환 표시.
struct UsageBreakdownContent: View {
    let usage: UsageBreakdown
    let providerName: String
    let icon: IconSource
    let figure: ModelFigure
    var figureSelection: Binding<ModelFigure>?
    var animates = false
    var now = Date()

    /// 저장된 선택, 이 기간에 없는 수치면 첫 수치.
    private var shownFigure: ModelFigure {
        usage.modelFigures.contains(figure) ? figure : usage.modelFigures.first ?? figure
    }

    var body: some View {
        if usage.isEmpty {
            nothingToShow
        } else {
            details
        }
    }

    private var title: some View {
        Text(usage.displayTitle(at: now))
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    private var nothingToShow: some View {
        VStack(alignment: .leading, spacing: 6) {
            title
            VStack(spacing: 0) {
                ProviderIcon(source: icon, inset: 0.04)
                    .frame(width: 24, height: 24)
                    .phaseAnimator(animates ? [0.5, 0.2] : [0.5]) { mark, opacity in
                        mark.opacity(opacity)
                    } animation: { _ in
                        .easeInOut(duration: 2.8)
                    }
                    .frame(height: 56)
                    .accessibilityHidden(true)
                    .padding(.bottom, 12)
                BalancedLines {
                    Text(L10n.metrics("%@ didn't report any data for this range.", providerName))
                        .font(.system(size: 13, weight: .semibold))
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 8)
            .padding(.bottom, 12)
            .accessibilityElement(children: .combine)
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                title
                if let headline = usage.figures.first {
                    Text(headline)
                        .font(.system(size: 26, weight: .semibold))
                        .tracking(-0.5)
                        .monospacedDigit()
                        .lineLimit(1)
                }
                if usage.figures.count > 1 {
                    Text(usage.figures.dropFirst().joined(separator: " · "))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                }
            }
            if !usage.modelFigures.isEmpty {
                topModels
            }
            if !usage.breakdown.sourceNote.isEmpty {
                PopoverSourceNote(text: usage.breakdown.sourceNote)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var topModels: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(L10n.metrics("Top Models"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let figureSelection, usage.modelFigures.count > 1 {
                    CapsuleSegments(
                        options: usage.modelFigures.map { ($0, $0.label) },
                        selection: figureSelection,
                        height: 22,
                        fontSize: 11,
                        segmentWidth: 52
                    )
                    .fixedSize()
                }
            }
            VStack(spacing: 2) {
                ForEach(Array(usage.rows(by: shownFigure).enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        Text(row.name)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                        Text(row.number.map(shownFigure.text) ?? "\u{2014}")
                            .foregroundStyle(row.number == nil ? .tertiary : .primary)
                            .monospacedDigit()
                            .lineLimit(1)
                            .fixedSize()
                    }
                    .font(.system(size: 12))
                    .frame(minHeight: 18)
                    .accessibilityElement(children: .combine)
                    .hoverTooltip(figureSelection == nil ? nil : row.variantTooltip)
                }
            }
        }
    }
}

/// 사용 내역 공유 이미지 — 프로바이더 이름만(계정명 없음), 공용 하단 띠.
struct UsageBreakdownShareCard: View {
    let usage: UsageBreakdown
    let providerName: String
    let icon: IconSource
    let figure: ModelFigure
    let appearance: ColorScheme

    var body: some View {
        ShareCardFrame(appearance: appearance) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    ProviderIcon(source: icon, inset: 0.04)
                        .frame(width: 18, height: 18)
                    Text(providerName)
                        .font(DashboardGrid.headerFont)
                }
                UsageBreakdownContent(usage: usage, providerName: providerName, icon: icon, figure: figure)
            }
        }
    }
}
