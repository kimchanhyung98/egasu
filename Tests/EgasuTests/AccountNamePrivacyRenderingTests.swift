import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class AccountNamePrivacyRenderingTests: XCTestCase {

    func testInlineEditorShowsAndCommitsTheUnmaskedAccountName() async throws {
        var savedName = "Private Alias"
        let renaming = AccountRenameStore(
            profileID: { $0 }, label: { _ in savedName }, rename: { _, name in savedName = name })
        renaming.begin("codex")
        let edit = try XCTUnwrap(renaming.edit)
        let view = InlineRenameField(renaming: renaming, edit: edit)
            .padding(16)
            .frame(width: 340, height: 80)
        let host = NSHostingView(rootView: view)
        let window = makeWindow(host: host)
        defer { window.close() }
        try await settle(host)

        let field = try XCTUnwrap(editableFields(in: host).first)
        XCTAssertEqual(field.stringValue, "Private Alias")
        renaming.draft = "Changed in Accounts"
        renaming.commit(edit)
        XCTAssertEqual(savedName, "Changed in Accounts")
        try export(host, name: "accounts-privacy-on")
    }

    func testEnablingPrivacyClosesTheDashboardEditorWithoutSavingItsDraft() async throws {
        var savedName = "Private Alias"
        let renaming = AccountRenameStore(profileID: { $0 }, label: { _ in savedName }, rename: { _, name in savedName = name })
        renaming.begin("codex")
        let host = NSHostingView(rootView: caption(renaming: renaming, concealed: false))
        let window = makeWindow(host: host)
        defer { window.close() }
        try await settle(host)
        XCTAssertFalse(editableFields(in: host).isEmpty)

        renaming.draft = "Uncommitted Name"
        host.rootView = caption(renaming: renaming, concealed: true)
        try await settle(host)

        XCTAssertNil(renaming.edit)
        XCTAssertEqual(savedName, "Private Alias")
        XCTAssertTrue(editableFields(in: host).isEmpty)
        try export(host, name: "dashboard-privacy-on", renderSwiftUIEffects: true)
    }

    func testDashboardDoesNotRenderAnEditorWhilePrivacyIsAlreadyEnabled() async throws {
        let renaming = AccountRenameStore(profileID: { $0 }, label: { _ in "Private Alias" }, rename: { _, _ in })
        renaming.begin("codex")
        let host = NSHostingView(rootView: caption(renaming: renaming, concealed: true))
        let window = makeWindow(host: host)
        defer { window.close() }
        try await settle(host)

        XCTAssertTrue(editableFields(in: host).isEmpty)
    }

    private func caption(renaming: AccountRenameStore, concealed: Bool) -> some View {
        DashboardAccountCaption(
            account: DashboardAccount(provider: MockData.codex, providerName: "Codex", name: "Private Alias", lines: []),
            plan: "Pro"
        )
        .environment(renaming)
        .environment(\.concealsAccountNames, concealed)
        .padding(16)
        .frame(width: 340, height: 80)
    }

    private func makeWindow<Content: View>(host: NSHostingView<Content>) -> NSWindow {
        host.sizingOptions = []
        host.frame = NSRect(x: 0, y: 0, width: 340, height: 80)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: (NSScreen.screens.map(\.frame.maxX).max() ?? 0) + 1_000, y: 0))
        window.orderFrontRegardless()
        return window
    }

    private func settle(_ view: NSView) async throws {
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(100))
        view.layoutSubtreeIfNeeded()
    }

    private func editableFields(in view: NSView) -> [NSTextField] {
        let current = (view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? []
        return current + view.subviews.flatMap { editableFields(in: $0) }
    }

    private func export<Content: View>(
        _ view: NSHostingView<Content>, name: String, renderSwiftUIEffects: Bool = false
    ) throws {
        guard let path = ProcessInfo.processInfo.environment["EGASU_PRIVACY_SNAPSHOTS"] else { return }
        let directory = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let bitmap: NSBitmapImageRep
        if renderSwiftUIEffects {
            let renderer = ImageRenderer(content: view.rootView.environment(\.colorScheme, .light).background(.white))
            renderer.scale = 2
            bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
        } else {
            bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent("\(name).png"))
    }
}
