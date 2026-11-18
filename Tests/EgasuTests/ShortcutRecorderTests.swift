import AppKit
import Carbon.HIToolbox
import SwiftUI
import XCTest
@testable import KeyboardShortcuts
@testable import Egasu

@MainActor
final class ShortcutRecorderTests: XCTestCase {
    func testLeavingSettingsCancelsInputWhileTheViewStaysMounted() async throws {
        try await withRecorder { popover, _, recorder, _ in
            popover.screen = .dashboard
            try await self.waitUntil { recorder.window == nil }
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
        }
    }

    func testClosingAndReopeningPanelDoesNotResumeRecording() async throws {
        try await withRecorder { popover, panel, recorder, _ in
            panel.clearStrayFocus()
            popover.popoverShown = false
            panel.orderOut(nil)
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
            try await self.waitUntil { recorder.window == nil }
            let hiddenRecorder = try XCTUnwrap(self.findRecorder(in: try XCTUnwrap(panel.contentView)))
            XCTAssertFalse(hiddenRecorder.isEnabled)
            XCTAssertFalse(panel.makeFirstResponder(hiddenRecorder))

            popover.popoverShown = true
            panel.orderFrontRegardless()
            panel.clearStrayFocus()
            try await self.waitUntil { hiddenRecorder.window == nil }
            let reopenedRecorder = try XCTUnwrap(self.findRecorder(in: try XCTUnwrap(panel.contentView)))
            XCTAssertTrue(reopenedRecorder.isEnabled)
            XCTAssertFalse(KeyboardShortcuts.isPaused)
            XCTAssertTrue(panel.makeFirstResponder(reopenedRecorder))
            try await self.waitUntil { KeyboardShortcuts.isPaused }
            panel.clearStrayFocus()
        }
    }

    func testLeavingGeneralEndsRecordingWhenTheControlIsRemoved() async throws {
        try await withRecorder { popover, _, recorder, _ in
            popover.settingsTab = .display
            try await self.waitUntil { recorder.window == nil }
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
        }
    }

    func testHostWindowLosingKeyCancelsInput() async throws {
        try await withRecorder { _, panel, _, _ in
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: panel)
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
        }
    }

    func testOtherWindowLosingKeyDoesNotCancelInput() async throws {
        try await withRecorder { _, panel, _, _ in
            let otherWindow = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: false)
            otherWindow.isReleasedWhenClosed = false
            defer { otherWindow.close() }
            NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: otherWindow)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(KeyboardShortcuts.isPaused)
            panel.clearStrayFocus()
        }
    }

    func testDisabledRecorderCannotTakeFocus() async throws {
        try await withRecorder { _, panel, recorder, _ in
            panel.clearStrayFocus()
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
            recorder.isEnabled = false
            XCTAssertFalse(panel.makeFirstResponder(recorder))
            XCTAssertFalse(KeyboardShortcuts.isPaused)
        }
    }

    func testClearingStrayFocusKeepsOrdinaryTextEditing() async throws {
        try await withRecorder { _, panel, _, _ in
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
            panel.contentView?.addSubview(textField)
            XCTAssertTrue(panel.makeFirstResponder(textField))
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
            let editor = try XCTUnwrap(textField.currentEditor())
            panel.clearStrayFocus()
            XCTAssertTrue(panel.firstResponder === editor)
        }
    }

    func testEscapeCancelsWithoutChangingShortcut() async throws {
        try await withRecorder { _, panel, _, _ in
            try self.sendKey(code: UInt16(kVK_Escape), characters: "\u{1b}", to: panel)
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
        }
    }

    func testPlaceholderUsesTheAppLanguageDuringAndAfterRecording() async throws {
        try await L10n.withLanguage(.japanese) {
            try await withRecorder { _, panel, recorder, _ in
                XCTAssertEqual(recorder.placeholderString, L10n.settings("Type Shortcut…"))
                try self.sendKey(code: UInt16(kVK_Escape), characters: "\u{1b}", to: panel)
                try await self.waitUntil { !KeyboardShortcuts.isPaused }
                XCTAssertEqual(recorder.placeholderString, L10n.settings("Record Shortcut"))
            }
        }
    }

    func testRecordingUsesTheExistingNamedShortcutStorage() async throws {
        let replacement = KeyboardShortcuts.Shortcut(.f19, modifiers: [.command, .option, .control, .shift])
        try await withRecorder(expected: replacement) { _, panel, _, _ in
            try self.sendKey(
                code: UInt16(kVK_F19), characters: String(UnicodeScalar(NSF19FunctionKey)!),
                modifiers: replacement.modifiers, to: panel
            )
            try await self.waitUntil { !KeyboardShortcuts.isPaused }
        }
    }

    private func withRecorder(
        expected: KeyboardShortcuts.Shortcut? = nil,
        perform: (PopoverState, MenuBarPanel, KeyboardShortcuts.RecorderCocoa, KeyboardShortcuts.Name) async throws ->
            Void
    ) async throws {
        let name = KeyboardShortcuts.Name("EgasuTests_ShortcutRecorder_\(UUID().uuidString)")
        let original = KeyboardShortcuts.Shortcut(.f20, modifiers: [.command, .option, .control, .shift])
        KeyboardShortcuts.setShortcut(original, for: name)
        KeyboardShortcuts.onKeyUp(for: name) {}
        defer {
            KeyboardShortcuts.disable(name)
            KeyboardShortcuts.setShortcut(nil, for: name)
            KeyboardShortcuts.removeHandler(for: name)
        }

        let popover = PopoverState()
        popover.screen = .settings
        popover.show()
        let host = NSHostingView(
            rootView: RecorderPreview(name: name).environment(popover).frame(width: 300, height: 60))
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        let panel = MenuBarPanel(contentRect: host.frame)
        panel.isReleasedWhenClosed = false
        panel.host(host)
        panel.alphaValue = 0
        panel.setFrameOrigin(NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1_000, y: 0))
        panel.orderFrontRegardless()
        defer {
            _ = panel.makeFirstResponder(nil)
            panel.contentView = nil
            panel.close()
        }
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        let recorder = try XCTUnwrap(findRecorder(in: host))
        XCTAssertTrue(recorder.isEnabled)
        XCTAssertEqual(recorder.shortcut, original)
        XCTAssertTrue(panel.makeFirstResponder(recorder))
        try await waitUntil { KeyboardShortcuts.isPaused }
        XCTAssertTrue((panel.firstResponder as? NSTextView)?.delegate === recorder)

        try await perform(popover, panel, recorder, name)
        try await waitUntil { !KeyboardShortcuts.isPaused }
        XCTAssertTrue(KeyboardShortcuts.isEnabled(for: name))
        XCTAssertEqual(KeyboardShortcuts.getShortcut(for: name), expected ?? original)
        XCTAssertTrue(host.window === panel, "입력기 수명과 패널 호스팅 수명 분리")
    }

    private struct RecorderPreview: View {
        let name: KeyboardShortcuts.Name
        @Environment(PopoverState.self) private var popover

        var body: some View {
            if popover.settingsTab == .general {
                SettingsShortcutRecorder(name: name)
                    .disabled(!popover.popoverShown || popover.screen != .settings)
                    .id(popover.popoverShown && popover.screen == .settings)
            } else {
                Text("Display")
            }
        }
    }

    private func findRecorder(in view: NSView) -> KeyboardShortcuts.RecorderCocoa? {
        if let recorder = view as? KeyboardShortcuts.RecorderCocoa { return recorder }
        return view.subviews.lazy.compactMap { self.findRecorder(in: $0) }.first
    }

    private func sendKey(
        code: UInt16, characters: String, modifiers: NSEvent.ModifierFlags = [], to panel: NSWindow
    ) throws {
        _ = NSApp.nextEvent(matching: .keyDown, until: nil, inMode: .default, dequeue: false)
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters,
                isARepeat: false, keyCode: code
            ))
        NSApp.postEvent(event, atStart: true)
        if let next = NSApp.nextEvent(
            matching: .keyDown, until: Date(timeIntervalSinceNow: 0.1), inMode: .default, dequeue: true)
        {
            NSApp.sendEvent(next)
        }
    }

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition() {
            guard ContinuousClock.now < deadline else {
                XCTFail("Timed out waiting", file: file, line: line)
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
