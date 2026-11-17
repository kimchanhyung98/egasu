import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class AllUsageDisplaySettingsTests: XCTestCase {
    func testLayoutSelectionUpdatesTheExistingDashboardHost() async throws {
        let suite = "EgasuTests.DashboardLayout.Host.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplaySettingsStore(defaults: defaults)
        let provider = MockData.codex
        let data = WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 40, limit: 100)
        let descriptor = WidgetDescriptor(id: "codex.weekly", providerID: "codex", metricLabel: "Weekly", sample: data)
        let family = DashboardFamily(
            id: "codex", provider: provider, displayName: "Codex",
            accounts: [
                DashboardAccount(
                    provider: provider, providerName: "Codex", name: "Work",
                    lines: [.init(descriptor: descriptor, data: data)])
            ])
        let host = NSHostingView(rootView: LayoutPreview(display: display, family: family))
        host.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        let minimalHeight = host.fittingSize.height

        display.dashboardLayout = .cards
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, minimalHeight)

        display.dashboardLayout = .minimal
        try await Task.sleep(for: .milliseconds(100))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.height, minimalHeight, accuracy: 0.5)
    }

    func testDashboardLayoutSelectionSurvivesRelaunchInBothDirections() throws {
        let suite = "EgasuTests.DashboardLayout.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("remaining", forKey: "meterStyle")
        defaults.set(["codex.weekly", "claude.session"], forKey: "openusage.layout.v1.priorityPins")
        let existing = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        let display = DisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(display.dashboardLayout, .minimal, "기존 미니멀 화면 유지")

        display.dashboardLayout = .cards
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).dashboardLayout, .cards)
        display.dashboardLayout = .minimal
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).dashboardLayout, .minimal)

        var saved = try XCTUnwrap(defaults.persistentDomain(forName: suite))
        saved.removeValue(forKey: DisplaySettingsStore.dashboardLayoutKey)
        XCTAssertTrue(NSDictionary(dictionary: saved).isEqual(to: existing), "모양 전환으로 표시 지표·고정·사용량 설정을 바꾸지 않음")
    }

    func testAccountEmailChoicePersistsWithoutChangingProfilesOrLayout() throws {
        let name = "EgasuTests.AccountEmailChoice.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let profiles = AccountProfilesStore(defaults: defaults)
        let profile = try profiles.add(family: "codex", label: "Work", identityKey: "fixture-identity")
        profiles.setPreferred(family: "codex", profileID: profile.id)
        defaults.set(["codex.spark"], forKey: "openusage.layout.v1.disabledMetrics")
        defaults.set("remaining", forKey: "meterStyle")
        let before = try XCTUnwrap(defaults.persistentDomain(forName: name))
        let store = WidgetDataStore(registry: .mock, providers: [], defaults: defaults)
        XCTAssertFalse(store.showsAccountEmails)

        for shown in [true, false] {
            store.showsAccountEmails = shown
            let restored = WidgetDataStore(registry: .mock, providers: [], defaults: defaults)
            XCTAssertEqual(restored.showsAccountEmails, shown)
            var after = try XCTUnwrap(defaults.persistentDomain(forName: name))
            after.removeValue(forKey: "showsAccountEmails")
            XCTAssertEqual(before as NSDictionary, after as NSDictionary)
            XCTAssertEqual(AccountProfilesStore(defaults: defaults).preferredProfileID(family: "codex"), profile.id)
        }
    }

    private struct LayoutPreview: View {
        let display: DisplaySettingsStore
        let family: DashboardFamily

        var body: some View {
            DashboardProviderSection(family: family, layoutStyle: display.dashboardLayout) { account in
                DashboardAccountRows(account: account, layoutStyle: display.dashboardLayout)
            }
            .frame(width: PanelMetrics.width - PanelMetrics.margin * 2)
        }
    }
}
