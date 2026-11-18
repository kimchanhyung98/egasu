import AppKit
import SwiftUI

/// 켜진 프로바이더가 없을 때의 대시보드 — 앱 아이콘, 안내, 계정 추가 버튼.
struct EmptyDashboardView: View {
    let addAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 56, height: 56)
                .padding(.bottom, 14)
                .accessibilityHidden(true)

            Text(L10n.dashboard("Add an Account"))
                .font(.system(size: 19, weight: .semibold))
                .padding(.bottom, 7)
            Text(
                L10n.dashboard(
                    "egasu shows the AI tools you're signed in to on this Mac. Add an account to track more, even several of the same provider."
                )
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 230)
            .padding(.bottom, 20)

            Button(action: addAccount) {
                Label(L10n.accounts("Add Account"), systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 22)
        .padding(.bottom, 26)
        .fixedSize(horizontal: false, vertical: true)
    }
}
