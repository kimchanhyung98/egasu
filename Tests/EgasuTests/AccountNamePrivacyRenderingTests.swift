import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class AccountNamePrivacyRenderingTests: XCTestCase {

    func testPrivacyBlursTheRenderedDashboardName() throws {
        let account = DashboardAccount(
            provider: MockData.codex, providerName: "Codex", name: "Private Alias", lines: [])
        func darkestPixel(concealed: Bool) throws -> CGFloat {
            let view = DashboardAccountCaption(account: account)
                .environment(\.concealsAccountNames, concealed)
                .environment(\.colorScheme, .light)
                .padding(8)
                .frame(width: 130)
                .background(.white)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let bitmap = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage))
            var minimum: CGFloat = 1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    let color = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceGray))
                    minimum = min(minimum, color.whiteComponent)
                }
            }
            return minimum
        }

        let visible = try darkestPixel(concealed: false)
        let blurred = try darkestPixel(concealed: true)
        XCTAssertLessThan(visible, 0.9)
        XCTAssertGreaterThan(blurred, visible + 0.05)
        XCTAssertLessThan(blurred, 0.99)
    }

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

    func testPresentedRecoveryAlertChangesPrivacyInPlaceAndRetriesTheSameProfile() async throws {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "Private Alias", identityKey: "workspace", createdAt: .distantPast)
        let path = "/fixture/private-account/auth.json"
        let mismatch = AccountCredentialImporter.ImportError.differentAccount
        let issue = AccountReSignInIssue.failed(AccountSignInWorkspace.WorkspaceError.outsideOwnedRoot(path))
        let alert = AccountActionAlert.signInFailed(profile, issues: [issue, .failed(mismatch)], allowsRetry: true)
        var dismissed: [String?] = []
        func content(_ concealed: Bool) -> some View {
            Color.clear.background {
                DashboardAccountAlertSheet(alert: alert, concealsAccountNames: concealed) { dismissed.append($0?.id) }
            }
        }
        let host = NSHostingView(rootView: content(false))
        let window = makeWindow(host: host)
        defer { window.close() }
        try await settle(host)
        let sheet = try XCTUnwrap(window.attachedSheet)
        for concealed in [false, true, false] {
            host.rootView = content(concealed)
            try await settle(host)
            XCTAssertIdentical(window.attachedSheet, sheet)
            let views = alertFields(in: try XCTUnwrap(sheet.contentView))
            let text = views.compactMap { ($0 as? NSTextField)?.stringValue }.joined(separator: "\n")
            XCTAssertEqual(text.contains(profile.label), !concealed)
            XCTAssertEqual(text.contains(path), !concealed)
            XCTAssertTrue(text.contains(UserFacingErrors.message(mismatch)))
            XCTAssertTrue(dismissed.isEmpty)
        }
        let buttons = alertFields(in: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
        let retry = try XCTUnwrap(buttons.first { $0.title == L10n.accounts("Sign In Again…") })
        XCTAssertTrue(retry.sendAction(try XCTUnwrap(retry.action), to: retry.target))
        for _ in 0..<50 where dismissed.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(dismissed, [profile.id])
    }

    func testAccountAlertOKDismissesWithoutRetrying() async throws {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "Work", identityKey: "workspace", createdAt: .distantPast)
        let alert = AccountActionAlert.signInRequired(profile, detail: "Expired", concealedDetail: "Expired")
        var dismissed: [String?] = []
        let host = NSHostingView(
            rootView: Color.clear.background {
                DashboardAccountAlertSheet(alert: alert, concealsAccountNames: false) { dismissed.append($0?.id) }
            })
        let window = makeWindow(host: host)
        defer { window.close() }
        try await settle(host)
        let sheet = try XCTUnwrap(window.attachedSheet)
        let buttons = alertFields(in: try XCTUnwrap(sheet.contentView)).compactMap { $0 as? NSButton }
        let ok = try XCTUnwrap(buttons.first { $0.title == L10n.dashboard("OK") })
        XCTAssertEqual(ok.keyEquivalent, "\u{1b}")
        XCTAssertTrue(ok.sendAction(try XCTUnwrap(ok.action), to: ok.target))
        for _ in 0..<50 where dismissed.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(dismissed, [nil])
    }

    func testDismantlingAnAccountAlertLeavesAnotherSheetOpen() async throws {
        let profile = AccountProfile(
            id: "c", family: "codex", label: "Work", identityKey: "workspace", createdAt: .distantPast)
        let alert = AccountActionAlert.signInRequired(profile, detail: "Expired", concealedDetail: "Expired")
        var dismissed = false
        func content(_ show: Bool) -> some View {
            Color.clear.background {
                if show {
                    DashboardAccountAlertSheet(alert: alert, concealsAccountNames: false) { _ in dismissed = true }
                }
            }
        }
        let host = NSHostingView(rootView: content(false))
        let window = makeWindow(host: host)
        defer { window.close() }
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 50),
            styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        window.beginSheet(other, completionHandler: nil)
        host.rootView = content(true)
        try await settle(host)
        XCTAssertIdentical(window.attachedSheet, other)
        XCTAssertEqual(window.sheets.count, 2)
        host.rootView = content(false)
        try await settle(host)
        XCTAssertIdentical(window.attachedSheet, other)
        XCTAssertEqual(window.sheets, [other])
        window.endSheet(other)
        for _ in 0..<50 where window.attachedSheet === other { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNil(window.attachedSheet)
        XCTAssertFalse(dismissed)
    }

    private func alertFields(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { alertFields(in: $0) }
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
