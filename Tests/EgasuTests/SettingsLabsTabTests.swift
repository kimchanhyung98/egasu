import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class SettingsLabsTabTests: XCTestCase {
    func testLabsFollowsBetaUpdatesAndResetsSelectionWhenDisabledOutsideSettings() async throws {
        let suite = "EgasuTests.LabsNavigation.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PopoverState(defaults: defaults)
        let updater = UpdaterController(defaults: defaults)
        let disabled = expectation(description: "external beta setting disables Labs")
        updater.onBetaChannelChange = { enabled in
            state.reconcileSettingsTab(betaUpdatesEnabled: enabled)
            if !enabled { disabled.fulfill() }
        }
        let stable: [SettingsTab] = [.general, .display, .alerts, .advanced]
        XCTAssertEqual(SettingsTab.visible(betaUpdatesEnabled: updater.betaChannelEnabled), stable)
        updater.betaChannelEnabled = true
        XCTAssertEqual(SettingsTab.visible(betaUpdatesEnabled: updater.betaChannelEnabled), stable + [.labs])
        XCTAssertEqual(SettingsTab.labs.symbol, "flask")
        XCTAssertNotNil(NSImage(systemSymbolName: SettingsTab.labs.symbol, accessibilityDescription: nil))

        state.screen = .settings
        state.settingsTab = .labs
        state.screen = .dashboard
        XCTAssertEqual(state.settingsTab, .labs)
        defaults.set(false, forKey: UpdaterController.betaChannelDefaultsKey)
        await fulfillment(of: [disabled], timeout: 3)
        XCTAssertFalse(updater.betaChannelEnabled)
        XCTAssertEqual(state.settingsTab, .general)
        updater.betaChannelEnabled = true
        state.screen = .settings
        XCTAssertEqual(state.settingsTab, .general)
    }

    func testFiveTabLabelsFitInThePanelInEveryLanguageAndAppearance() async throws {
        let titles: [(LanguageSetting, [String])] = [
            (.english, ["General", "Display", "Alerts", "Advanced", "Labs"]),
            (.korean, ["일반", "표시", "알림", "고급", "실험실"]),
            (.japanese, ["一般", "表示", "アラート", "詳細設定", "ラボ"])
        ]
        for (language, expected) in titles {
            for scheme in [ColorScheme.light, .dark] {
                let image = try L10n.withLanguage(language) {
                    let strip = SettingsTabBar(betaUpdatesEnabled: true)
                        .padding(.horizontal, PanelMetrics.margin)
                        .frame(width: PanelMetrics.width)
                        .background(Theme.panelBody)
                        .environment(PopoverState())
                        .environment(\.colorScheme, scheme)
                    let renderer = ImageRenderer(content: strip)
                    renderer.scale = 4
                    return try XCTUnwrap(renderer.cgImage)
                }
                let labelArea = CGRect(
                    x: 0, y: image.height / 2, width: image.width, height: image.height - image.height / 2)
                let labels = try await recognizedText(in: XCTUnwrap(image.cropping(to: labelArea)), language: language)
                for title in expected {
                    XCTAssertTrue(labels.contains(title.lowercased()), "\(language) \(scheme) \(title): \(labels)")
                }
            }
        }
    }

    func testExperimentalControlsAppearTogetherOnlyInLabs() async throws {
        let suite = "EgasuTests.LabsContent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = PopoverState(defaults: defaults)
        state.screen = .settings
        let updater = UpdaterController(defaults: defaults)
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let helper = CommandLineToolInstaller(
            sourcePath: temporary.appendingPathComponent("helper").path,
            destinationPath: temporary.appendingPathComponent("egasu").path)
        defaults.set(false, forKey: MenuBarPrivacyStore.key)
        let privacy = MenuBarPrivacyStore(defaults: defaults, probe: { false }, installChangeNotifications: { _ in })
        let telemetry = TelemetryRecorder(
            sink: DisabledSink(), store: TelemetryStore(defaults: defaults),
            snapshot: { .init(enabledProviders: [], enabledMetricIDs: [], pinnedMetricIDs: []) })
        let screens: [(SettingsTab, LanguageSetting, String)] = [
            (.advanced, .english, "settings-advanced-light.png"),
            (.labs, .english, "settings-labs-light.png"),
            (.labs, .korean, "settings-labs-ko-light.png")
        ]
        for (tab, language, fileName) in screens {
            updater.betaChannelEnabled = tab == .labs
            state.settingsTab = tab
            let bitmap = try L10n.withLanguage(language) {
                let view = VStack(spacing: 0) {
                    SettingsTopBar()
                    Form {
                        if tab == .labs {
                            SettingsLabsSections(
                                settings: settings, accounts: { [] }, commandLineTool: helper)
                        } else {
                            SettingsAdvancedSections(
                                privacy: privacy, telemetry: telemetry,
                                tokscaleSync: TokscaleSyncStore(defaults: defaults))
                        }
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .contentMargins(.horizontal, PanelMetrics.margin - 20, for: .scrollContent)
                    .contentMargins(.top, DashboardContentView.barGap - 20, for: .scrollContent)
                }
                .frame(width: PanelMetrics.width, height: tab == .labs ? 490 : 500)
                .background(Theme.panelBody)
                .environment(state)
                .environment(updater)
                .environment(\.colorScheme, .light)
                .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: view)
                let window = makeWindow(host, scheme: .light)
                defer { window.close() }
                return try settingsBitmap(in: host)
            }
            let image = try XCTUnwrap(bitmap.cgImage)
            let text = try await recognizedText(in: image, language: language)
            for key in [
                "General", "Display", "Alerts", "Advanced", "Labs", "Soft Limit", "Weekly and Monthly", "Quota Status",
                "Terminal Helper", "Privacy Mode"
            ] {
                let label = L10n.withLanguage(language) { L10n.settings(key).filter(\.isLetter).lowercased() }
                let expected =
                    switch key {
                    case "Labs", "Soft Limit", "Weekly and Monthly", "Quota Status", "Terminal Helper": tab == .labs
                    case "Privacy Mode": tab == .advanced
                    default: true
                    }
                XCTAssertEqual(text.contains(label), expected, "\(key): \(text)")
            }
            if let output = ProcessInfo.processInfo.environment["EGASU_LABS_RENDER_DIR"] {
                let directory = URL(fileURLWithPath: output)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: directory.appendingPathComponent(fileName))
            }
        }
    }

    private func makeWindow(_ host: NSView, scheme: ColorScheme) -> NSWindow {
        let window = NSWindow(
            contentRect: .init(origin: .zero, size: host.fittingSize),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        return window
    }

    private func recognizedText(in image: CGImage, language: LanguageSetting) async throws -> String {
        try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = [language.locale.identifier]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                .joined().filter(\.isLetter).lowercased()
        }.value
    }

    private final class DisabledSink: TelemetrySink {
        var isAvailable: Bool { false }
        func capture(_ event: String, _ properties: [String: Any]) {}
        func setEnabled(_ enabled: Bool) {}
        func flush() {}
    }
}
