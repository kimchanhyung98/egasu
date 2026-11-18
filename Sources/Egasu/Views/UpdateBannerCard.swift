import SwiftUI

/// 예약 Sparkle 확인이 새 버전을 찾은 동안 대시보드 맨 위에 보이는 업데이트 카드.
/// 닫기는 일시 보류 — 자동 확인을 유지하고 다음 확인에도 업데이트가 있으면 다시 표시.
struct UpdateBannerCard: View {
    @Environment(UpdaterController.self) private var updater
    /// 발견된 업데이트의 표시 버전 (예: "0.8.1").
    let version: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.dashboard("Update Available"))
                    .font(.subheadline.weight(.semibold))
                Text(L10n.dashboard("egasu %@ is ready to download.", version))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(L10n.dashboard("Install Update")) { updater.installAvailableUpdate() }
                    .controlSize(.small)
                    .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(Motion.spring) { updater.dismissAvailableUpdate() }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L10n.dashboard("Dismiss"))
        }
        .padding(12)
        .cardSurface()
    }
}
