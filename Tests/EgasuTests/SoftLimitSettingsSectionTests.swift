import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class SoftLimitSettingsSectionTests: XCTestCase {
    func testRendersEnabledAndDisabledSettingsAcrossAppearances() throws {
        let suite = "EgasuTests.SoftLimit.SettingsRendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SoftLimitSettingsStore(defaults: defaults)
        let coordinator = SoftLimitCoordinator(settings: settings, adapters: [], isProviderEnabled: { _ in true })
        let export = ProcessInfo.processInfo.environment["EGASU_SOFT_LIMIT_RENDER_DIR"].map { URL(fileURLWithPath: $0) }
        if let export { try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true) }
        func render(enabled: Bool, appearance: ColorScheme) throws -> CGFloat {
            settings.enabled = enabled
            let view = SoftLimitSettingsSection(
                settings: settings, coordinator: coordinator, providers: [MockData.codex, MockData.claude]
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
