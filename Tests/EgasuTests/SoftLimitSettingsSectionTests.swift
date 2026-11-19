import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class SoftLimitSettingsSectionTests: XCTestCase {
    func testQuotaStatusSeparatesConfirmedUnknownAndEstimatedReadings() {
        let cancellation = SoftLimitProviderStatus(phase: .unsupported, message: "")
        for language in LanguageSetting.allCases {
            L10n.withLanguage(language) {
                func label(_ state: SoftLimitQuotaState, used: Double?, estimate: Double? = nil) -> String {
                    SoftLimitAccountStatus(
                        id: "fixture", name: "Fixture", quota: state, usedFraction: used,
                        estimatedFraction: estimate, cancellation: cancellation
                    ).usageLabel
                }
                XCTAssertEqual(label(.belowLimit, used: 0.5), L10n.metrics("%@ used", "50%"))
                XCTAssertEqual(label(.belowLimit, used: 0.8999), L10n.metrics("%@ used", "89.9%"))
                XCTAssertEqual(label(.reached, used: 0.9), L10n.settings("%@ used · Soft limit reached", "90%"))
                XCTAssertEqual(label(.unknown, used: 0.8), L10n.settings("Quota not verified"))
                XCTAssertEqual(label(.unknown, used: nil, estimate: 0.95), L10n.settings("Estimated usage: %@", "95%"))
            }
        }
    }

    func testGroupedFormShowsThresholdOnlyOnce() async throws {
        let suite = "EgasuTests.SoftLimit.ThresholdLabel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        settings.enabled = true
        for language in LanguageSetting.allCases {
            let image = try L10n.withLanguage(language) {
                let form = Form { SoftLimitThresholdField(settings: settings) }
                    .formStyle(.grouped)
                    .frame(width: PanelMetrics.width, height: 110)
                    .environment(\.locale, language.locale)
                    .defaultAppStorage(defaults)
                let host = NSHostingView(rootView: form)
                let window = NSWindow(
                    contentRect: .init(origin: .zero, size: host.fittingSize),
                    styleMask: .borderless, backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                return try XCTUnwrap(settingsBitmap(in: host).cgImage)
            }
            let numbers = try await Task.detached {
                let request = VNRecognizeTextRequest()
                request.recognitionLanguages = [language.locale.identifier]
                try VNImageRequestHandler(cgImage: image).perform([request])
                return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .joined().filter(\.isNumber)
            }.value
            XCTAssertEqual(numbers, "90", language.rawValue)
        }
    }

    func testRendersEnabledAndDisabledSettingsAcrossAppearances() throws {
        let suite = "EgasuTests.SoftLimit.SettingsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SoftLimitSettingsStore(defaults: defaults, labsAvailable: true)
        let export = ProcessInfo.processInfo.environment["EGASU_SOFT_LIMIT_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        func render(enabled: Bool, appearance: ColorScheme) throws -> CGFloat {
            settings.enabled = enabled
            let view = SoftLimitSettingsSection(
                settings: settings, accounts: { [] }
            )
            .padding(12)
            .frame(width: 360)
            .background(appearance == .light ? Color.white : Color.black)
            .environment(\.colorScheme, appearance)
            .defaultAppStorage(defaults)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 360, height: 1000),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance == .light ? .aqua : .darkAqua)
            defer { window.close() }
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()

            let bounds = hosting.bounds
            let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: bounds))
            hosting.cacheDisplay(in: bounds, to: bitmap)
            XCTAssertEqual(bitmap.pixelsWide, Int(hosting.convertToBacking(bounds).width))
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)

            let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: 0))
            let hasForeground = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y) else { return false }
                    return color != background
                }
            }
            XCTAssertTrue(hasForeground, "enabled=\(enabled), appearance=\(appearance)")

            let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            if let export {
                try png.write(to: export.appendingPathComponent("soft-limit-\(enabled)-\(appearance).png"))
            }
            return bounds.height
        }

        for appearance in [ColorScheme.light, .dark] {
            let disabledHeight = try render(enabled: false, appearance: appearance)
            let enabledHeight = try render(enabled: true, appearance: appearance)
            XCTAssertGreaterThan(enabledHeight, disabledHeight, "appearance=\(appearance)")
        }
    }
}
