import SwiftUI

/// 등록 계정 상태 배지 — 확인 전은 중립색, 정상은 초록색, 실패는 주황색.
struct AccountStatusBadge: View {
    let state: AccountStatus

    private var color: AnyShapeStyle {
        switch state {
        case .ready: Theme.positive
        case .notChecked, .checking: AnyShapeStyle(.secondary)
        case .sessionExpired, .signInNeeded, .refreshFailed: Theme.notice
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(state.title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }
}
