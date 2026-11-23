import AppKit
import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class AccountRecommendationSettingsSectionTests: XCTestCase {
    func testControlsRenderInAllLanguagesAndAppearOnlyWhenEnabled() async throws {
        let suite = "EgasuTests.AccountRecommendations.Rendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AccountRecommendationSettingsStore(defaults: defaults, labsAvailable: true)
        let output = ProcessInfo.processInfo.environment["EGASU_RECOMMENDATIONS_RENDER_DIR"].map {
            URL(fileURLWithPath: $0)
        }
        if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
        let labels: [(LanguageSetting, String, [String])] = [
            (
                .english, "Account Recommendations",
                ["Recommend At", "Candidate Usage Below"]
            ),
            (.korean, "계정 전환 추천", ["추천 시작 사용률", "후보 사용률 제한"]),
            (.japanese, "アカウント切り替えの提案", ["提案開始使用率", "候補の使用率上限"])
        ]
        for (language, heading, controlLabels) in labels {
            for scheme in [ColorScheme.light, .dark] {
                for enabled in [false, true] {
                    settings.enabled = enabled
                    let bitmap = try L10n.withLanguage(language) {
                        let view = Form { AccountRecommendationSettingsSection(settings: settings) }
                            .formStyle(.grouped)
                            .frame(width: PanelMetrics.width, height: enabled ? 250 : 145)
                            .environment(\.locale, language.locale)
                            .environment(\.colorScheme, scheme)
                            .defaultAppStorage(defaults)
                        let host = NSHostingView(rootView: view)
                        let window = NSWindow(
                            contentRect: .init(origin: .zero, size: host.fittingSize),
                            styleMask: .borderless, backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                        window.contentView = host
                        window.setContentSize(host.fittingSize)
                        defer { window.close() }
                        return try settingsBitmap(in: host, scale: 4)
                    }
                    let image = try XCTUnwrap(bitmap.cgImage)
                    let text = try await Task.detached {
                        let request = VNRecognizeTextRequest()
                        request.recognitionLanguages = [language.locale.identifier]
                        try VNImageRequestHandler(cgImage: image).perform([request])
                        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                            .map { $0.filter(\.isLetter).lowercased() }
                    }.value
                    XCTAssertTrue(
                        text.contains { $0.hasPrefix(heading.filter(\.isLetter).lowercased()) },
                        "\(language) \(scheme) \(enabled): \(text)")
                    for label in controlLabels {
                        XCTAssertEqual(
                            text.contains { $0.hasPrefix(label.filter(\.isLetter).lowercased()) }, enabled,
                            "\(language) \(scheme) \(enabled) \(label): \(text)")
                    }
                    XCTAssertFalse(
                        text.contains {
                            $0.contains("showagainafter") || $0.contains("추천재표시대기") || $0.contains("再表示までの待機時間")
                        })
                    if let output {
                        let name = "account-recommendations-\(language.rawValue)-\(scheme)-\(enabled).png"
                        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                            .write(to: output.appendingPathComponent(name))
                    }
                }
            }
        }
    }

    func testPercentageEditsCommitOnReturnAndFocusLossAndRejectInvalidText() async throws {
        try await L10n.withLanguage(.english) {
            let suite = "EgasuTests.AccountRecommendations.Editing.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AccountRecommendationSettingsStore(defaults: defaults, labsAvailable: true)
            settings.enabled = true
            let host = NSHostingView(
                rootView: Form { AccountRecommendationSettingsSection(settings: settings) }
                    .formStyle(.grouped).frame(width: PanelMetrics.width, height: 360).defaultAppStorage(defaults))
            let window = NSWindow(
                contentRect: .init(origin: .zero, size: host.fittingSize),
                styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            defer { window.close() }
            host.layoutSubtreeIfNeeded()
            @MainActor func fields(_ view: NSView) -> [NSTextField] {
                ((view as? NSTextField).map { $0.isEditable ? [$0] : [] } ?? [])
                    + view.subviews.flatMap(fields)
            }
            let trigger = try XCTUnwrap(fields(host).first { $0.stringValue == "95" })
            let candidate = try XCTUnwrap(fields(host).first { $0.stringValue == "90" })
            @MainActor func edit(_ field: NSTextField, text: String, submit: Bool) async throws {
                XCTAssertTrue(window.makeFirstResponder(field))
                host.layoutSubtreeIfNeeded()
                let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
                editor.insertText(text, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
                await Task.yield()
                host.layoutSubtreeIfNeeded()
                if submit { editor.insertNewline(nil) } else { XCTAssertTrue(window.makeFirstResponder(nil)) }
                await Task.yield()
                host.layoutSubtreeIfNeeded()
            }
            @MainActor func waitUntil(_ condition: @MainActor () -> Bool) async throws {
                let deadline = Date().addingTimeInterval(2)
                while !condition() && Date() < deadline {
                    try await Task.sleep(for: .milliseconds(10))
                    host.layoutSubtreeIfNeeded()
                }
                XCTAssertTrue(condition())
            }
            try await edit(trigger, text: "81", submit: true)
            try await waitUntil { settings.triggerPercent == 81 }
            XCTAssertEqual(settings.candidateLimitPercent, 90)
            try await edit(candidate, text: "67", submit: false)
            try await waitUntil { settings.candidateLimitPercent == 67 }
            try await edit(trigger, text: "101", submit: true)
            XCTAssertEqual(settings.triggerPercent, 81)
            XCTAssertEqual(trigger.currentEditor()?.string ?? trigger.stringValue, "101")
            @MainActor func errorText() async throws -> String {
                let image = try XCTUnwrap(settingsBitmap(in: host, scale: 4).cgImage)
                return try await Task.detached {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLanguages = ["en-US"]
                    try VNImageRequestHandler(cgImage: image).perform([request])
                    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        .joined().filter { $0.isLetter || $0.isNumber }.lowercased()
                }.value
            }
            let triggerError = try await errorText()
            XCTAssertTrue(triggerError.contains("enterawholenumberfrom1to10081isstillapplied"), triggerError)
            try await edit(candidate, text: "90.5", submit: false)
            XCTAssertEqual(settings.candidateLimitPercent, 67)
            XCTAssertEqual(candidate.stringValue, "90.5")
            let candidateError = try await errorText()
            XCTAssertTrue(candidateError.contains("enterawholenumberfrom1to10067isstillapplied"), candidateError)
            let restored = AccountRecommendationSettingsStore(defaults: defaults, labsAvailable: true)
            XCTAssertEqual(restored.triggerPercent, 81)
            XCTAssertEqual(restored.candidateLimitPercent, 67)
        }
    }

}
