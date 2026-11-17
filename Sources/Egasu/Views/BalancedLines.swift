import SwiftUI

/// `Text` 하나를 비슷한 폭의 줄로 나눠 배치 — 가운데 정렬 문장이 단어 하나로 끝나지 않게 함.
/// 한 줄에 맞으면 원래 크기 유지, 줄바꿈이 필요하면 제안 폭과 같은 줄 수를 유지하는 가장 좁은 폭을 이진 탐색.
struct BalancedLines: Layout {
    var maxWidth: CGFloat = .infinity

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let text = subviews.first else { return .zero }
        let natural = text.sizeThatFits(.unspecified)
        let offered = min(proposal.width ?? .infinity, maxWidth)
        guard offered.isFinite, natural.width > offered else { return natural }
        func height(_ width: CGFloat) -> CGFloat {
            text.sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        }
        let lines = height(offered)
        var tooNarrow: CGFloat = 0
        var fits = offered
        while fits - tooNarrow > 1 {
            let mid = (tooNarrow + fits) / 2
            if height(mid) > lines {
                tooNarrow = mid
            } else {
                fits = mid
            }
        }
        return text.sizeThatFits(ProposedViewSize(width: fits.rounded(.up), height: nil))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let size = sizeThatFits(proposal: ProposedViewSize(bounds.size), subviews: subviews, cache: &cache)
        subviews.first?.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(size))
    }
}
