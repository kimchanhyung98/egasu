import AppKit
import SwiftUI

extension View {
    /// 호버 상세 팝오버 — Reduce Motion 활성화 시 animates가 false인 AppKit NSPopover 사용.
    /// SwiftUI가 `NSPopover.animates`를 노출하지 않아 표시 단계에서만 AppKit 경계를 넘음.
    func motionAwareHoverPopover<PopoverContent: View>(
        isPresented: Binding<Bool>,
        reduceAnimations: Bool,
        @ViewBuilder content: @escaping () -> PopoverContent
    ) -> some View {
        modifier(
            MotionAwareHoverPopoverModifier(
                isPresented: isPresented,
                reduceAnimations: reduceAnimations,
                popoverContent: content
            ))
    }
}

private struct MotionAwareHoverPopoverModifier<PopoverContent: View>: ViewModifier {
    @Binding var isPresented: Bool
    let reduceAnimations: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    @ViewBuilder
    func body(content: Content) -> some View {
        if reduceAnimations {
            content.background {
                ReducedMotionPopoverPresenter(isPresented: $isPresented, popoverContent: popoverContent)
            }
        } else {
            content.popover(isPresented: $isPresented, arrowEdge: .top, content: popoverContent)
        }
    }
}

private struct ReducedMotionPopoverPresenter<PopoverContent: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    @ViewBuilder let popoverContent: () -> PopoverContent

    func makeCoordinator() -> ReducedMotionPopoverController {
        ReducedMotionPopoverController(isPresented: $isPresented)
    }

    func makeNSView(context: Context) -> PopoverAnchorView {
        let view = PopoverAnchorView()
        view.onWindowChange = { [weak coordinator = context.coordinator, weak view] in
            guard let view else { return }
            coordinator?.synchronize(with: view)
        }
        return view
    }

    func updateNSView(_ nsView: PopoverAnchorView, context: Context) {
        context.coordinator.isPresented = $isPresented
        context.coordinator.update(content: AnyView(popoverContent()), anchor: nsView)
    }

    static func dismantleNSView(_ nsView: PopoverAnchorView, coordinator: ReducedMotionPopoverController) {
        nsView.onWindowChange = nil
        coordinator.dismissWithoutUpdatingBinding()
    }

    @MainActor
    final class PopoverAnchorView: NSView {
        var onWindowChange: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindowChange?()
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            nil
        }
    }
}

@MainActor
final class ReducedMotionPopoverController: NSObject, NSPopoverDelegate {
    private static let live = NSHashTable<ReducedMotionPopoverController>.weakObjects()

    var isPresented: Binding<Bool>
    let popover: NSPopover

    private let host = NSHostingController(rootView: AnyView(EmptyView()))
    private var ignoreNextClose = false

    init(isPresented: Binding<Bool>) {
        self.isPresented = isPresented
        self.popover = NSPopover()
        super.init()
        popover.animates = false
        popover.behavior = .transient
        popover.contentViewController = host
        popover.delegate = self
        Self.live.add(self)
    }

    func update(content: AnyView, anchor: NSView) {
        host.rootView = AnyView(content.animationReduction(true))
        guard isPresented.wrappedValue else {
            synchronize(with: anchor)
            return
        }
        host.view.layoutSubtreeIfNeeded()
        let size = host.view.fittingSize
        if size.width > 0, size.height > 0 {
            popover.contentSize = size
        }
        synchronize(with: anchor)
    }

    /// 패널 닫힘 시 AppKit 팝오버를 동기로 닫음 — 대시보드 트리는 `orderOut` 뒤에도 남아 다음 갱신을 기다리지 않음.
    static func dismissAll() {
        for controller in live.allObjects where controller.popover.isShown {
            controller.popover.performClose(nil)
        }
    }

    func synchronize(with anchor: NSView) {
        guard isPresented.wrappedValue else {
            if popover.isShown { popover.performClose(nil) }
            return
        }
        guard anchor.window != nil, !popover.isShown else { return }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
    }

    func dismissWithoutUpdatingBinding() {
        guard popover.isShown else { return }
        ignoreNextClose = true
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        if ignoreNextClose {
            ignoreNextClose = false
            return
        }
        if isPresented.wrappedValue {
            isPresented.wrappedValue = false
        }
    }
}
