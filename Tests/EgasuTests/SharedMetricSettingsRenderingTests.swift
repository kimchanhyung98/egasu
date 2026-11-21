import SwiftUI
import Vision
import XCTest
@testable import Egasu

@MainActor
final class SharedMetricSettingsRenderingTests: XCTestCase {
    func testSettingsCardsKeepTitlesAndRowsInsideTheirGroupsInEveryLanguageAndAppearance() async throws {
        let suite = "EgasuTests.SharedMetricSettings.Rendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let scanner = CodexLogUsageScanner(incrementalScanner: IncrementalJSONLScanner())
        let primary = CodexProvider(logUsageScanner: scanner)
        let accountID = "codex@fixture"
        let additional = CodexProvider(
            provider: CodexProvider.makeProvider(id: accountID), logUsageScanner: scanner
        )
        let layout = LayoutStore(registry: .from([primary, additional]), defaults: defaults)
        let accountMetrics = layout.accountSettingsMetrics(for: accountID)
        let sharedMetrics = layout.sharedSettingsMetrics(for: accountID)
        XCTAssertEqual(
            accountMetrics.map(\.id),
            [
                "session", "weekly", "monthly", "individualCredits", "rateLimitResets", "spark", "sparkWeekly", "sparkMonthly", "credits"
            ].map { "\(accountID).\($0)" })
        XCTAssertEqual(
            sharedMetrics.map(\.id),
            [
                "codex.trend", "codex.resetWatch", "codex.today", "codex.yesterday", "codex.last30"
            ])

        for language in LanguageSetting.allCases {
            for appearance in [ColorScheme.light, .dark] {
                let frames = CapturedFrames()
                let (image, titles, size) = try L10n.withLanguage(language) {
                    let titles = [L10n.accounts("Account Settings"), L10n.accounts("Shared Settings")]
                    let space = "shared-metric-settings"
                    let view = VStack(spacing: PanelMetrics.sectionSpacing) {
                        AccountMetricSettingsCard(
                            title: titles[0], metrics: accountMetrics, reorderSpaceName: space,
                            reorderLift: .constant(nil), rowFrames: [:]
                        )
                        .reorderFrame(id: "account-card", in: .named(space))
                        AccountMetricSettingsCard(
                            title: titles[1], metrics: sharedMetrics, reorderSpaceName: space,
                            reorderLift: .constant(nil), rowFrames: [:]
                        )
                        .reorderFrame(id: "shared-card", in: .named(space))
                    }
                    .padding(PanelMetrics.margin)
                    .frame(width: PanelMetrics.width)
                    .fixedSize(horizontal: false, vertical: true)
                    .background(Theme.panelBody)
                    .coordinateSpace(name: space)
                    .onPreferenceChange(ReorderFramePreferenceKey.self) { frames.values = $0 }
                    .environment(layout)
                    .environment(\.colorScheme, appearance)
                    let host = NSHostingView(rootView: view)
                    let window = NSWindow(
                        contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 700),
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
                            bitmapDataPlanes: nil,
                            pixelsWide: Int(ceil(host.bounds.width * 2)),
                            pixelsHigh: Int(ceil(host.bounds.height * 2)),
                            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    bitmap.size = host.bounds.size
                    host.cacheDisplay(in: host.bounds, to: bitmap)
                    XCTAssertEqual(host.bounds.width, 340)
                    if let path = ProcessInfo.processInfo.environment["EGASU_SHARED_METRIC_SNAPSHOT_DIR"] {
                        let directory = URL(fileURLWithPath: path)
                        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                        try png.write(to: directory.appendingPathComponent("\(language.rawValue)-\(appearance).png"))
                    }
                    return (try XCTUnwrap(bitmap.cgImage), titles, host.bounds.size)
                }
                let context = "\(language.rawValue) \(appearance)"
                let cards = [try XCTUnwrap(frames.values["account-card"]), try XCTUnwrap(frames.values["shared-card"])]
                let titleRegions = try zip(cards, [accountMetrics, sharedMetrics]).map { card, metrics in
                    let firstRow = try XCTUnwrap(frames.values[try XCTUnwrap(metrics.first).id])
                    return CGRect(
                        x: card.minX / size.width, y: 1 - firstRow.minY / size.height,
                        width: card.width / size.width, height: (firstRow.minY - card.minY) / size.height
                    )
                }
                let labels = try await Task.detached {
                    let requests = titleRegions.map { region in
                        let request = VNRecognizeTextRequest()
                        request.recognitionLanguages = [language.locale.identifier]
                        request.regionOfInterest = region
                        return request
                    }
                    try VNImageRequestHandler(cgImage: image).perform(requests)
                    return requests.map { request in
                        (request.results ?? []).compactMap { observation in
                            observation.topCandidates(1).first?.string.filter { !$0.isWhitespace }
                        }
                    }
                }.value

                XCTAssertLessThan(cards[0].maxY, cards[1].minY, context)
                for (index, metrics) in [accountMetrics, sharedMetrics].enumerated() {
                    let title = titles[index].filter { !$0.isWhitespace }
                    XCTAssertTrue(
                        labels[index].contains(title),
                        "\(context): \(titles[index]); recognized in this card: \(labels[index])")
                    var previousBottom = cards[index].minY
                    for metric in metrics {
                        let row = try XCTUnwrap(frames.values[metric.id], "\(context): \(metric.id)")
                        XCTAssertTrue(cards[index].contains(row), "\(context): \(metric.id)")
                        XCTAssertLessThanOrEqual(previousBottom, row.minY, "\(context): \(metric.id)")
                        previousBottom = row.maxY
                    }
                }
            }
        }
    }

    private final class CapturedFrames {
        var values: [String: CGRect] = [:]
    }
}
