import SwiftUI

/// 모델별 내역·사용 추세 팝오버의 중앙 정렬 출처 안내.
struct PopoverSourceNote: View {
    let text: String

    var body: some View {
        Text(localizedText)
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
    }

    private var localizedText: String {
        let sharedHistoryPrefix = UsageHistorySnapshotRenderer.sharedHistoryPrefix
        guard text.hasPrefix(sharedHistoryPrefix) else { return L10n.metrics(text) }
        let source = String(text.dropFirst(sharedHistoryPrefix.count))
        return L10n.metrics("Across your Macs · %@", L10n.metrics(source))
    }
}
