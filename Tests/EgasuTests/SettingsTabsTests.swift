import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class SettingsTabsTests: XCTestCase {
    func testUpdatesRemainVisibleWithoutAnUpdateFeedInEveryLanguageAndAppearance() async throws {
        XCTAssertNil(Bundle.main.object(forInfoDictionaryKey: "SUFeedURL"))
        let updater = UpdaterController()
        updater.start()
        XCTAssertFalse(updater.isActive)
        XCTAssertFalse(updater.canCheckForUpdates)

        for language in LanguageSetting.allCases {
            for appearance in [ColorScheme.light, .dark] {
                let (image, title) = try L10n.withLanguage(language) {
                    let title = L10n.settings("Updates")
                    let view = Form {
                        SettingsUpdatesSection()
                    }
                    .formStyle(.grouped)
                    .scrollContentBackground(.hidden)
                    .frame(width: PanelMetrics.width, height: 220)
                    .background(Theme.panelBody)
                    .environment(updater)
                    .environment(\.colorScheme, appearance)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(
                        contentRect: .init(x: 0, y: 0, width: PanelMetrics.width, height: 220),
                        styleMask: .borderless, backing: .buffered, defer: false
                    )
                    window.isReleasedWhenClosed = false
                    window.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
                    window.contentView = host
                    defer { window.close() }
                    window.setContentSize(host.fittingSize)
                    host.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(
                        NSBitmapImageRep(
                            bitmapDataPlanes: nil, pixelsWide: Int(ceil(host.bounds.width * 2)),
                            pixelsHigh: Int(ceil(host.bounds.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
                            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
                        ))
                    bitmap.size = host.bounds.size
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    if let path = ProcessInfo.processInfo.environment["EGASU_UPDATES_RENDER_DIR"] {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: directory.appendingPathComponent("\(language.rawValue)-\(appearance).png"))
                    }
                    return (try XCTUnwrap(bitmap.cgImage), title)
                }
                let labels = try await Task.detached {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = [language.locale.identifier]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .map { $0.filter(\.isLetter).lowercased() }
                }.value
                let context = "\(language.rawValue) \(appearance): \(labels)"
                XCTAssertTrue(labels.contains(title.filter(\.isLetter).lowercased()), context)
                XCTAssertEqual(labels.count, 4, "업데이트 제목과 설정 행 3개 표시: \(context)")
            }
        }
        XCTAssertFalse(updater.isActive)
        XCTAssertFalse(updater.canCheckForUpdates)
    }

    func testMenuBarSelectionMigratesBothLegacyValuesAndSavesAnExplicitChoice() throws {
        let suite = "EgasuTests.MenuBarSelection.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarSelection, .runningOut)
        for legacy in [false, true] {
            defaults.set(legacy, forKey: "menuBarAlwaysShows")
            XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarSelection, legacy ? .priority : .runningOut)
        }
        let display = DisplaySettingsStore(defaults: defaults)
        for selection in MenuBarSelection.allCases {
            display.menuBarSelection = selection
            XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarSelection, selection)
        }
        defaults.set(false, forKey: "menuBarAlwaysShows")
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarSelection, .pinnedOnly, "이전 값은 명시적 선택을 덮어쓰지 않음")
    }

    func testMenuBarStyleRestoresLegacyChoiceAndPersistsBothDirections() throws {
        let suite = "EgasuTests.MenuBarStyle.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarStyle, .text)
        defaults.set("bars", forKey: "openusage.layout.v1.menuBarStyle")
        defaults.set(MenuBarLimit.upToTwo.rawValue, forKey: DisplaySettingsStore.menuBarLimitKey)
        let display = DisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(display.menuBarStyle, .bars)
        display.menuBarStyle = .text
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarStyle, .text)
        display.menuBarStyle = .bars
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarStyle, .bars)
        XCTAssertEqual(DisplaySettingsStore(defaults: defaults).menuBarLimit, .upToTwo)
    }

    func testExtraIndicatorsDefaultToShownAndPersistBothChoices() throws {
        let suite = "EgasuTests.MenuBarExtras.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let display = DisplaySettingsStore(defaults: defaults)
        XCTAssertTrue(display.showsMenuBarExtras)
        display.menuBarStyle = .bars
        display.menuBarLimit = .upToTwo
        for shown in [false, true] {
            display.showsMenuBarExtras = shown
            let restored = DisplaySettingsStore(defaults: defaults)
            XCTAssertEqual(restored.showsMenuBarExtras, shown)
            XCTAssertEqual(restored.menuBarStyle, .bars)
            XCTAssertEqual(restored.menuBarLimit, .upToTwo)
        }
    }

    func testMenuBarPreviewShowsTheChosenNumberOfSamples() {
        for limit in MenuBarLimit.allCases {
            let content = PriorityIconsPreview.sample(limit: limit)
            XCTAssertEqual(content.items.count, limit.count, "\(limit)")
            XCTAssertEqual(content.overflow, limit == .iconOnly ? 0 : 7 - limit.count, "\(limit): 넘친 샘플은 +N")
        }
        XCTAssertEqual(PriorityIconsPreview.sample(limit: .upToTwo).items.map(\.badge), ["P", "A1"], "계정 이니셜 배지 예시 포함")
    }

    func testMenuBarPreviewUsesLocalizedStripLabels() {
        let cases: [(LanguageSetting, [String])] = [
            (.english, ["Weekly", "Session", "Weekly", "Extra", "Session"]),
            (.korean, ["주간", "세션", "주간", "추가 사용량", "세션"]),
            (.japanese, ["週間", "セッション", "週間", "追加使用量", "セッション"])
        ]
        for (language, expected) in cases {
            L10n.withLanguage(language) {
                XCTAssertEqual(PriorityIconsPreview.sample(limit: .upToFive).items.map(\.shortLabel), expected)
            }
        }
    }

    func testPreviewStaysVisibleAtOneSizeAcrossStylesLimitsAndRowWidths() throws {
        let suite = "EgasuTests.MenuBarPreview.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = WidgetDataStore(registry: .mock, providers: [], defaults: defaults)
        for style in MenuBarStyle.allCases {
            store.displaySettings.menuBarStyle = style
            for limit in MenuBarLimit.allCases {
                store.displaySettings.menuBarLimit = limit
                for extras in [true, false] {
                    store.displaySettings.showsMenuBarExtras = extras
                    for appearance in [ColorScheme.light, .dark] {
                        let widths = try [CGFloat(296), 356].map { rowWidth in
                            let view = PriorityIconsPreview()
                                .environment(store)
                                .environment(\.colorScheme, appearance)
                                .frame(width: rowWidth)
                            let renderer = ImageRenderer(content: view)
                            renderer.scale = 2
                            let image = try XCTUnwrap(renderer.cgImage)
                            let bounds = try XCTUnwrap(MenuBarStripRenderer.visibleBounds(of: image))
                            XCTAssertLessThan(
                                bounds.width, rowWidth * renderer.scale, "\(style) \(limit) extras=\(extras)")
                            XCTAssertLessThan(bounds.height, CGFloat(image.height))
                            return bounds.width
                        }
                        XCTAssertEqual(widths[0], widths[1], "\(style) \(limit) extras=\(extras): 행 폭과 무관한 미리보기 크기")
                    }
                }
            }
        }
    }

    func testLaunchAtLoginRefreshReadsTheSystemState() {
        var systemEnabled = false
        let setting = LaunchAtLoginSetting(currentStatus: { systemEnabled }, setEnabled: { _ in })
        XCTAssertFalse(setting.isEnabled)
        systemEnabled = true
        setting.refreshStatus()
        XCTAssertTrue(setting.isEnabled, "시스템 설정에서 켠 상태를 Settings에 들어올 때 반영")
    }

}
