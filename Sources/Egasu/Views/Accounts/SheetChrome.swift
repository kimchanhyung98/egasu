import SwiftUI

/// 계정 시트 머리 — 아이콘 32 · 제목 · 설명 · 선택 링크, 바깥 여백 위·좌우 20, 아래 14.
struct SheetHeader: View {
    var icon: IconSource?
    let title: String
    let message: String
    var link: (title: String, url: URL)?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let icon {
                ProviderIcon(source: icon, inset: 0.04)
                    .frame(width: 32, height: 32)
                    .padding(.bottom, 8)
            }
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let link {
                Link(link.title, destination: link.url)
                    .font(.subheadline)
                    .padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding([.horizontal, .top], 20)
        .padding(.bottom, 14)
    }
}

struct SheetAction {
    let title: String
    var isDisabled = false
    var shortcut: KeyboardShortcut?
    let action: () -> Void
}

/// 같은 폭의 bordered 보조 버튼과 borderedProminent 주 버튼 — 주 버튼 기본 단축키는 Return.
struct SheetButtons: View {
    let secondary: SheetAction
    let primary: SheetAction

    var body: some View {
        HStack {
            button(secondary, shortcut: secondary.shortcut)
                .buttonStyle(.bordered)
            button(primary, shortcut: primary.shortcut ?? .defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding([.horizontal, .top], 20)
    }

    private func button(_ action: SheetAction, shortcut: KeyboardShortcut?) -> some View {
        Button(action: action.action) {
            Text(action.title).frame(maxWidth: .infinity)
        }
        .keyboardShortcut(shortcut)
        .disabled(action.isDisabled)
    }
}

/// 선택 목록 — 화살표로 선택 이동, 클릭·Return으로 결정, 시트가 열리면 목록에 포커스.
struct SheetChoiceList<Item: Hashable, Label: View>: View {
    let items: [Item]
    @Binding var selection: Item?
    var isEnabled: (Item) -> Bool = { _ in true }
    let choose: (Item) -> Void
    @ViewBuilder let label: (Item) -> Label
    @FocusState private var isFocused: Bool

    var body: some View {
        List(items, id: \.self, selection: $selection) { item in
            HStack(spacing: 10) {
                label(item)
                Spacer()
                if isEnabled(item) {
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(.rect)
            .onTapGesture { if isEnabled(item) { choose(item) } }
            .listItemTint(.monochrome)
            .opacity(isEnabled(item) ? 1 : 0.5)
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .scrollDisabled(true)
        .background(Theme.cardFill, in: .rect(cornerRadius: 10))
        .frame(height: CGFloat(items.count) * 28 + 20)
        .padding(.horizontal, 20)
        .focused($isFocused)
        .contextMenu(
            forSelectionType: Item.self, menu: { _ in },
            primaryAction: { items in
                if let item = items.first, isEnabled(item) { choose(item) }
            }
        )
        .onAppear { isFocused = true }
    }
}

/// 첫 단계의 오른쪽 아래 Cancel(Esc).
struct SheetCancelRow: View {
    let cancel: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(L10n.accounts("Cancel"), action: cancel)
                .keyboardShortcut(.cancelAction)
        }
        .padding(20)
    }
}

/// 시트 아래 상태 문구 — 진행 중이면 진행 표시, 실패면 경고 색.
struct SheetStatus: View {
    let text: String?
    var isWorking = false
    var isError = false

    var body: some View {
        if let text {
            HStack(spacing: 8) {
                if isWorking {
                    ProgressView().controlSize(.small)
                }
                Text(text)
                    .font(.callout)
                    .foregroundStyle(isError ? AnyShapeStyle(Theme.notice) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
    }
}
