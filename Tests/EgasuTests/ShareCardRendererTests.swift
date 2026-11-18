import XCTest
import SwiftUI
@testable import Egasu

@MainActor
final class ShareCardRendererTests: XCTestCase {
    private func family(_ provider: Provider, rows: [WidgetData]) -> DashboardFamily {
        let lines = rows.enumerated().map { index, data in
            DashboardLine(
                descriptor: WidgetDescriptor(id: "\(provider.id).row\(index)", providerID: provider.id, metricLabel: data.title, sample: data),
                data: data
            )
        }
        let account = DashboardAccount(provider: provider, providerName: provider.displayName, name: nil, lines: lines)
        return DashboardFamily(id: provider.id, provider: provider, displayName: provider.displayName, accounts: [account])
    }

    private func sampleCard() -> ShareCardView {
        let provider = MockData.claude
        let rows = MockData.descriptors(for: provider.id).map { $0.sample }
        return ShareCardView(family: family(provider, rows: rows), plans: [provider.id: "Max"], appearance: .light)
    }

    func testImageRasterizesAtAuthoredWidthMultiple() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))

        // CI는 ×1, 로컬은 ×4로 rasterize되므로 정확한 곱 대신 배수로 검증
        let rep = try XCTUnwrap(image.representations.first)
        let width = Int(ShareCardView.width)
        XCTAssertGreaterThan(rep.pixelsWide, 0)
        XCTAssertEqual(rep.pixelsWide % width, 0, "bitmap width should be a whole multiple of the authored card width")
        XCTAssertGreaterThan(rep.pixelsHigh, 0, "flexible-height card should rasterize with a positive height")
    }

    func testPNGDataRoundTripsToValidPNG() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))

        XCTAssertFalse(png.isEmpty)
        // PNG 매직 바이트: 89 50 4E 47 0D 0A 1A 0A
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
        XCTAssertNotNil(NSImage(data: png))
    }

    func testEmptyProviderShareAddsAnEmptyMessage() throws {
        let fixture = family(MockData.cursor, rows: [])
        let blankCard = ShareCardFrame(appearance: .dark) {
            DashboardProviderSection(family: fixture) { account in
                DashboardAccountRows(account: account)
            }
        }
        let blankImage = try XCTUnwrap(ShareCardRenderer.image(for: blankCard))
        let card = ShareCardView(family: fixture, appearance: .dark)
        let image = try XCTUnwrap(ShareCardRenderer.image(for: card))
        let rep = try XCTUnwrap(image.representations.first)
        XCTAssertEqual(rep.pixelsWide % Int(ShareCardView.width), 0)
        XCTAssertGreaterThan(image.size.height, blankImage.size.height)
    }

    func testRendersSoftLimitAndResetWatchInBothDisplayModes() throws {
        let suite = "EgasuTests.SoftLimit.Rendering.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let provider = CodexProvider().provider
        let deadline = Date().addingTimeInterval(3600)
        do {
            for mode in [WidgetDisplayMode.used, .remaining] {
                var quota = WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 95, limit: 100)
                quota.softLimitUsedFraction = 0.95
                quota.displayMode = mode
                var watch = WidgetData(title: "Reset Watch", icon: provider.icon, kind: .percent, used: 75, limit: 100)
                watch.displayMode = mode
                watch.forecast = .init(deadline: deadline, communityYesPercent: 100)
                var unavailable = watch
                unavailable.forecast?.communityYesPercent = nil
                unavailable.forecast?.refreshFailed = true
                let rows = [quota, watch, unavailable, watch.presented(at: deadline)]
                for appearance in [ColorScheme.light, .dark] {
                    let dashboard = VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                            DashboardMetricRow(model: row.dashboardRow())
                        }
                    }
                    .padding(.horizontal, 14)
                    .frame(width: 320)
                    .background(appearance == .light ? Color.white : Color.black)
                    .environment(\.colorScheme, appearance)
                    .environment(\.hoverTooltipsDisabled, true)
                    .defaultAppStorage(defaults)
                    let card = ShareCardView(family: family(provider, rows: rows), appearance: appearance)
                        .defaultAppStorage(defaults)
                    for (name, image, width) in [
                        ("dashboard", ShareCardRenderer.image(for: dashboard), 320),
                        ("share", ShareCardRenderer.image(for: card), Int(ShareCardView.width))
                    ] {
                        let rendered = try XCTUnwrap(image, "\(name), \(mode), \(appearance)")
                        let rep = try XCTUnwrap(rendered.representations.first)
                        XCTAssertGreaterThan(rep.pixelsWide, 0)
                        XCTAssertEqual(rep.pixelsWide % width, 0)
                        XCTAssertGreaterThan(rep.pixelsHigh, 0)
                        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: rendered))
                        XCTAssertNotNil(NSImage(data: png))
                    }
                }
            }
        }
    }

    func testSoftLimitMarkerRendersAsOneThinWarningLine() throws {
        let suite = "EgasuTests.SoftLimit.YellowMarker.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for layoutStyle in DashboardLayoutStyle.allCases {
            for mode in [WidgetDisplayMode.used, .remaining] {
                for appearance in [ColorScheme.light, .dark] {
                    var row = WidgetData(title: "Weekly", icon: .providerMark("codex"), kind: .percent, used: 40, limit: 100)
                    row.displayMode = mode
                    for showsMarker in [false, true] {
                        row.softLimitUsedFraction = showsMarker ? 0.90 : nil
                        let view = DashboardMetricRow(model: row.dashboardRow(), layoutStyle: layoutStyle)
                            .environment(\.drawsLevelsAsShapes, true)
                            .padding(.horizontal, 14)
                            .frame(width: 320)
                            .background(appearance == .light ? Color.white : Color.black)
                            .environment(\.colorScheme, appearance)
                            .environment(\.hoverTooltipsDisabled, true)
                            .defaultAppStorage(defaults)
                        let image = try XCTUnwrap(ShareCardRenderer.image(for: view))
                        let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
                        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
                        let cgImage = try XCTUnwrap(bitmap.cgImage)
                        let raster = try XCTUnwrap(CGContext(
                            data: nil, width: cgImage.width, height: cgImage.height,
                            bitsPerComponent: 8, bytesPerRow: cgImage.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                        ))
                        raster.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
                        let pixels = try XCTUnwrap(raster.data).assumingMemoryBound(to: UInt8.self)
                        var yellowColumns: Set<Int> = []
                        for y in 0..<raster.height {
                            for x in 0..<raster.width {
                                let offset = y * raster.bytesPerRow + x * 4
                                let red = Double(pixels[offset]) / 255
                                let green = Double(pixels[offset + 1]) / 255
                                let blue = Double(pixels[offset + 2]) / 255
                                if red > 0.6, green > 0.4, blue < min(red, green) * 0.6 {
                                    yellowColumns.insert(x)
                                }
                            }
                        }
                        let context = "\(layoutStyle), \(mode), \(appearance), marker: \(showsMarker)"
                        if showsMarker {
                            XCTAssertFalse(yellowColumns.isEmpty, context)
                            XCTAssertLessThanOrEqual(yellowColumns.count, 2 * bitmap.pixelsWide / 320, context)
                        } else {
                            XCTAssertTrue(yellowColumns.isEmpty, context)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Clipboard write result

    func testCopyToPasteboardReturnsFalseForUnencodableImage() {
        // 빈 NSImage는 representation이 없어 tiffRepresentation nil → PNG encode 실패
        let empty = NSImage()
        XCTAssertFalse(ShareCardRenderer.copyToPasteboard(empty),
                       "a failed encode must report false, not silently return success")
    }

    func testCopyToPasteboardWritesPNGAndReturnsTrueForValidImage() throws {
        let image = try XCTUnwrap(ShareCardRenderer.image(for: sampleCard()))
        let pasteboard = NSPasteboard(name: .init("EgasuTests.ShareCard.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try requirePasteboardService(pasteboard)
        XCTAssertTrue(ShareCardRenderer.copyToPasteboard(image, pasteboard: pasteboard))

        let png = try XCTUnwrap(pasteboard.data(forType: .png))
        XCTAssertFalse(png.isEmpty)
        // 매직 바이트로 pasteboard 내용이 실제 PNG임을 확인
        let magic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        XCTAssertEqual(Array(png.prefix(magic.count)), magic)
    }
    func testCurrentAccountNameChangesTheSharedImagePixels() throws {
        let provider = MockData.claude
        func pixels(name: String) throws -> Data {
            let account = DashboardAccount(provider: provider, providerName: provider.displayName, name: name, lines: [])
            let family = DashboardFamily(
                id: provider.id, provider: provider, displayName: provider.displayName, accounts: [account])
            let view = ShareCardView(family: family, appearance: .light, blursAccountNames: false)
            let image = try XCTUnwrap(ShareCardRenderer.image(for: view))
            let png = try XCTUnwrap(ShareCardRenderer.pngData(from: image))
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
            let data = try XCTUnwrap(bitmap.bitmapData)
            return Data(bytes: data, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        }
        let current = try pixels(name: "Office")
        let repeated = try pixels(name: "Office")
        XCTAssertEqual(current.count, repeated.count)
        XCTAssertLessThanOrEqual(zip(current, repeated).map { abs(Int($0) - Int($1)) }.max() ?? 0, 1)
        XCTAssertNotEqual(current, try pixels(name: "Work"), "현재 계정 이름을 이미지에 반영")
    }

}

@MainActor
extension ShareCardRendererTests {
    func testFamilyShareCopiesVisibleAccountRowsInSavedOrder() throws {
        let provider = MockData.codex
        var today = WidgetData(title: "Today", icon: provider.icon, kind: .dollars, used: 3, limit: nil)
        today.isUsagePeriod = true
        let weekly = WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 42, limit: 100)
        var trend = WidgetData(title: "Usage Trend", icon: provider.icon, kind: .count, used: 0, limit: nil)
        trend.isChart = true
        trend.chartPoints = [MetricChartPoint(value: 120, label: "Monday", valueLabel: "120")]
        var unavailable = WidgetData(title: "Session", icon: provider.icon, kind: .percent, used: 17, limit: 100)
        unavailable.hasData = false

        let family = familyShareFixture(
            provider: provider, name: "Work", rows: [today, unavailable, weekly, trend]
        )
        let expected = familyShareFixture(provider: provider, name: "Work", rows: [today, weekly, trend])
        let reversed = familyShareFixture(provider: provider, name: "Work", rows: [trend, weekly, today])
        let collapsed = familyShareFixture(provider: provider, name: "Work", rows: [weekly])
        let pasteboard = NSPasteboard(name: .init("EgasuTests.FamilyShare.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try requirePasteboardService(pasteboard)

        for style in [DashboardLayoutStyle.minimal, .cards] {
            let expectedPixels = try familySharePixels(expected, style: style)
            let collapsedPixels = try familySharePixels(collapsed, style: style)
            XCTAssertGreaterThan(expectedPixels.count, collapsedPixels.count)
            let actual = try copiedFamilySharePixels(family, style: style, pasteboard: pasteboard)
            assertFamilySharePixels(actual, match: expectedPixels)
            XCTAssertNotEqual(actual, try familySharePixels(reversed, style: style))
        }
    }

    func testFamilyShareOmitsEmailAndOrganizationFromTheAccountCaption() throws {
        let provider = MockData.codex
        let weekly = WidgetData(title: "Weekly", icon: provider.icon, kind: .percent, used: 17, limit: 100)
        let emailFree = familyShareFixture(provider: provider, name: nil, rows: [weekly])
        let pasteboard = NSPasteboard(name: .init("EgasuTests.FamilyShareEmail.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try requirePasteboardService(pasteboard)

        for style in [DashboardLayoutStyle.minimal, .cards] {
            for privacyMode in [false, true] {
                let expected = try familySharePixels(emailFree, style: style, privacyMode: privacyMode)
                for name in ["work@example.com", "work@example.com (Example Org)"] {
                    let family = familyShareFixture(provider: provider, name: name, rows: [weekly])
                    let actual = try copiedFamilySharePixels(
                        family, style: style, pasteboard: pasteboard, privacyMode: privacyMode
                    )
                    assertFamilySharePixels(actual, match: expected)
                }
            }
        }
    }

    func testFamilyShareOmitsTheResetClaimAnchorWithoutRemovingTheAccount() throws {
        let provider = MockData.codex
        let descriptor = WidgetDescriptor.values(
            id: "codex.rateLimitResets", provider: provider, title: "Rate Limit Resets", showsResetExpiries: true
        )
        let auth = CodexAuth(tokens: CodexTokens(accessToken: "fixture-token"))
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: .init(auth: auth, source: .keychain)))
        var data = descriptor.sample
        data.hasData = true
        data.values = [.init(number: 0, kind: .count, label: "available")]
        data.codexResetClaimBinding = binding
        let retained = DashboardAccount(
            provider: provider, providerName: provider.displayName, name: "Work",
            lines: [DashboardLine(descriptor: descriptor, data: data)],
            retainingResetClaims: [descriptor.id: binding]
        )
        let retainedFamily = DashboardFamily(
            id: provider.id, provider: provider, displayName: provider.displayName, accounts: [retained]
        )
        let emptyFamily = familyShareFixture(provider: provider, name: "Work", rows: [])
        XCTAssertEqual(retained.lines.map(\.id), [descriptor.id])

        for style in DashboardLayoutStyle.allCases {
            let actual = try familySharePixels(retainedFamily, style: style)
            let expected = try familySharePixels(emptyFamily, style: style)
            assertFamilySharePixels(actual, match: expected)
        }
    }

    private func familyShareFixture(provider: Provider, name: String?, rows: [WidgetData]) -> DashboardFamily {
        let lines = rows.map { row in
            let descriptor = WidgetDescriptor(
                id: "\(provider.id).\(row.title)", providerID: provider.id, metricLabel: row.title, sample: row
            )
            return DashboardLine(descriptor: descriptor, data: row)
        }
        let account = DashboardAccount(
            provider: provider, providerName: provider.displayName, name: name, lines: lines
        )
        return DashboardFamily(id: provider.id, provider: provider, displayName: provider.displayName, accounts: [account])
    }

    private func requirePasteboardService(_ pasteboard: NSPasteboard) throws {
        let probe = "EgasuTests pasteboard probe"
        pasteboard.clearContents()
        guard pasteboard.setString(probe, forType: .string), pasteboard.string(forType: .string) == probe else {
            throw XCTSkip("The macOS pasteboard service is unavailable in this test host.")
        }
    }

    private func copiedFamilySharePixels(
        _ family: DashboardFamily, style: DashboardLayoutStyle, pasteboard: NSPasteboard,
        privacyMode: Bool = false
    ) throws -> Data {
        let copied = ShareCardRenderer.share(
            family: family, plans: [family.id: "Plus"], appearance: .light, blursAccountNames: privacyMode,
            layoutStyle: style, pasteboard: pasteboard
        )
        XCTAssertTrue(copied, "The share action must render, encode, and copy a PNG")
        return try familySharePixels(png: XCTUnwrap(pasteboard.data(forType: .png)))
    }

    private func familySharePixels(
        _ family: DashboardFamily, style: DashboardLayoutStyle, privacyMode: Bool = false
    ) throws -> Data {
        let view = ShareCardView(
            family: family, plans: [family.id: "Plus"], appearance: .light,
            blursAccountNames: privacyMode, layoutStyle: style
        )
        let image = try XCTUnwrap(ShareCardRenderer.image(for: view))
        return try familySharePixels(png: XCTUnwrap(ShareCardRenderer.pngData(from: image)))
    }

    private func familySharePixels(png: Data) throws -> Data {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: png))
        let pixels = try XCTUnwrap(bitmap.bitmapData)
        return Data(bytes: pixels, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
    }

    private func assertFamilySharePixels(
        _ actual: Data, match expected: Data, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        var largestDifference = 0
        for (actualByte, expectedByte) in zip(actual, expected) {
            largestDifference = max(largestDifference, abs(Int(actualByte) - Int(expectedByte)))
        }
        XCTAssertLessThanOrEqual(largestDifference, 1, file: file, line: line)
    }
}
