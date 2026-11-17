import AppKit
import SwiftUI

extension View {
    /// 화면 공통 이름 변경 실패 안내 — 패널을 닫으며 실패하면 다음 열기에 표시.
    func accountRenameErrorAlert(renaming: AccountRenameStore, isPopoverShown: Bool) -> some View {
        alert(
            L10n.accounts("Couldn't Rename Account"),
            isPresented: Binding(
                get: { isPopoverShown && renaming.lastError != nil },
                set: { if !$0 && isPopoverShown { renaming.dismissError() } }
            ),
            presenting: renaming.lastError
        ) { _ in
            Button(L10n.dashboard("OK"), role: .cancel) { renaming.dismissError() }
        } message: { error in
            Text(error)
        }
    }
}

/// 제자리 이름 입력란 — 나타나면 바로 포커스, Return·바깥 클릭·포커스 이탈은 저장, Esc는 취소.
struct InlineRenameField: View {
    @Bindable var renaming: AccountRenameStore
    let edit: AccountRenameStore.Edit

    @FocusState private var isFocused: Bool

    private static let outset = CGSize(width: 4, height: 1)

    var body: some View {
        TextField(L10n.accounts("Account Name"), text: $renaming.draft)
            .textFieldStyle(.plain)
            .lineLimit(1)
            .focused($isFocused)
            .onSubmit { renaming.commit(edit) }
            .onExitCommand { renaming.cancel(edit) }
            .onChange(of: isFocused) { _, focused in
                if !focused { renaming.commit(edit) }
            }
            .onAppear { isFocused = true }
            .padding(.horizontal, Self.outset.width)
            .padding(.vertical, Self.outset.height)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .textBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.tint, lineWidth: 1)
                    }
            }
            .background(RenameWindowBridge { renaming.commit(edit) })
            .padding(.horizontal, -Self.outset.width)
            .padding(.vertical, -Self.outset.height)
            .accessibilityLabel(L10n.accounts("Account Name"))
    }
}

/// 입력란 표시 시 키 창으로 전환하여 텍스트 선택과 입력 포커스 확보.
/// 창 내부 클릭을 관찰하여 포커스를 받지 않는 영역의 클릭도 편집 종료에 반영 — 클릭 이벤트는 그대로 전달.
private struct RenameWindowBridge: NSViewRepresentable {
    let onClickOutside: @MainActor () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView()
        view.onClickOutside = onClickOutside
        return view
    }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onClickOutside = onClickOutside
    }

    final class MonitorView: NSView {
        var onClickOutside: (@MainActor () -> Void)?
        private var monitor: Any?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let window else { return }
            window.makeKey()
            monitor = NSEvent.addLocalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                let eventWindowID = event.window.map(ObjectIdentifier.init)
                let location = event.locationInWindow
                MainActor.assumeIsolated {
                    guard let self, let window = self.window,
                        eventWindowID == ObjectIdentifier(window),
                        !self.bounds.contains(self.convert(location, from: nil))
                    else { return }
                    self.onClickOutside?()
                }
                return event
            }
        }
    }
}
