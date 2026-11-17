import SwiftUI

/// 드래그 재정렬 손잡이 — `line.3.horizontal`.
struct ReorderGrip: View {
    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 16, height: 22)
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }
}
