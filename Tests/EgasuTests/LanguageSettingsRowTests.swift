import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class LanguageSettingsRowTests: XCTestCase {
    func testPendingLanguageOffersVisibleRestartButton() async throws {
        let text = try await recognizedText(selection: .korean, activeLanguage: .english)
        XCTAssertTrue(text.contains("Restart Now"), text)
    }

    func testActiveLanguageDoesNotOfferRestart() async throws {
        let text = try await recognizedText(selection: .english, activeLanguage: .english)
        XCTAssertTrue(text.contains("Language"), text)
        XCTAssertFalse(text.contains("Restart Now"), text)
        XCTAssertFalse(text.contains("Restart egasu"), text)
    }

    func testRestartButtonRendersInEveryLanguage() async throws {
        let labels: [LanguageSetting: String] = [.english: "Restart Now", .korean: "지금 다시 시작", .japanese: "今すぐ再起動"]
        for language in LanguageSetting.allCases {
            let selection: LanguageSetting = language == .english ? .korean : .english
            let text = try await recognizedText(selection: selection, activeLanguage: language)
            let expected = try XCTUnwrap(labels[language]).filter { !$0.isWhitespace }
            XCTAssertTrue(text.filter { !$0.isWhitespace }.contains(expected), "\(language): \(text)")
        }
    }

    func testFailedRestartSurvivesRowRemountAndClearsOnLanguageChange() async throws {
        var selection = LanguageSetting.korean
        var attempts = 0
        let relauncher = AppRelauncher(
            scheduleRelaunch: {
                attempts += 1
                throw CocoaError(.fileNoSuchFile)
            },
            terminate: { XCTFail("The application must stay open when scheduling fails.") }
        )
        L10n.withLanguage(.english) { relauncher.restart() }

        for _ in 0..<2 {
            let text = try await recognizedText(selection: selection, activeLanguage: .english, relauncher: relauncher)
            let letters = text.filter(\.isLetter).lowercased()
            XCTAssertTrue(letters.contains("couldntrestartegasuquitandreopentheapp"), text)
            XCTAssertTrue(text.contains("Restart Now"), text)
        }
        let row = LanguageSettingsRow(
            selection: Binding(get: { selection }, set: { selection = $0 }),
            activeLanguage: .english,
            relauncher: relauncher
        )
        row.pickerSelection.wrappedValue = .korean
        XCTAssertNotNil(relauncher.errorMessage)

        row.pickerSelection.wrappedValue = .english
        XCTAssertEqual(selection, .english)
        XCTAssertNil(relauncher.errorMessage)

        row.pickerSelection.wrappedValue = .japanese
        XCTAssertEqual(selection, .japanese)
        XCTAssertNil(relauncher.errorMessage)
        XCTAssertEqual(attempts, 1)
    }

    private func recognizedText(
        selection: LanguageSetting, activeLanguage: LanguageSetting,
        relauncher: AppRelauncher = AppRelauncher(scheduleRelaunch: {}, terminate: {})
    ) async throws -> String {
        let suite = "LanguageSettingsRowTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let image = try L10n.withLanguage(activeLanguage) {
            let view = LanguageSettingsRow(
                selection: .constant(selection), activeLanguage: activeLanguage, relauncher: relauncher
            )
            .frame(width: 292)
            .padding(14)
            .background(Color.white)
            .environment(\.colorScheme, .light)
            .defaultAppStorage(defaults)
            let hosting = NSHostingView(rootView: view)
            let window = NSWindow(
                contentRect: .init(x: 0, y: 0, width: 320, height: 300),
                styleMask: .borderless, backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = hosting
            window.setContentSize(hosting.fittingSize)
            hosting.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(
                NSBitmapImageRep(
                    bitmapDataPlanes: nil, pixelsWide: Int(ceil(hosting.bounds.width * 2)),
                    pixelsHigh: Int(ceil(hosting.bounds.height * 2)), bitsPerSample: 8, samplesPerPixel: 4,
                    hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            bitmap.size = hosting.bounds.size
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
            if relauncher.errorMessage == nil,
                let path = ProcessInfo.processInfo.environment["EGASU_LANGUAGE_RESTART_SCREENSHOTS"]
            {
                let directory = URL(fileURLWithPath: path)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let name = "\(activeLanguage.rawValue)-light-\(selection.rawValue).png"
                try png.write(to: directory.appendingPathComponent(name))
            }
            return try XCTUnwrap(bitmap.cgImage)
        }
        return try await Task.detached {
            let request = VNRecognizeTextRequest()
            request.recognitionLanguages = [activeLanguage.locale.identifier, "en-US"]
            try VNImageRequestHandler(cgImage: image).perform([request])
            return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        }.value
    }
}
