import AppKit
import SwiftUI
import XCTest
@testable import Egasu

@MainActor
final class CodexResetDetailTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testGroupsCreditsWithTheSameExpiry() throws {
        let data = try codexResetData(
            """
            {
              "available_count": 2,
              "credits": [
                {"id":"first", "expires_at":1800086400},
                {"id":"second", "expires_at":1800086400}
              ]
            }
            """)

        XCTAssertEqual(data.expiriesAt.count, 2)
        let entries = RateLimitResetsDetail.entries(from: data.expiriesAt, now: now)
        XCTAssertEqual(entries.map(\.date), [now.addingTimeInterval(86_400)])
        XCTAssertEqual(entries.map(\.quantity), [2])
    }

    func testKeepsCreditsWithUnknownExpiryAlongsideTimeline() throws {
        let data = try codexResetData(
            """
            {
              "available_count": 3,
              "credits": [
                {"id":"known", "expires_at":1800086400},
                {"id":"missing"},
                {"id":"null", "expires_at":null}
              ]
            }
            """)

        XCTAssertEqual(data.resetCreditCount, 3)
        XCTAssertEqual(data.expiriesAt.count, 1)
        let content = RateLimitResetsDetail.content(count: data.resetCreditCount, expiries: data.expiriesAt, now: now)
        guard case .timeline(let entries, let unknownCount) = content else {
            return XCTFail("expected timeline alongside the count of unknown expiries")
        }
        XCTAssertEqual(entries.map(\.quantity), [1])
        XCTAssertEqual(unknownCount, 2)
    }

    func testDisplaysReportedCountWhenReplacementHasTheSameExpiry() throws {
        let expiry = now.addingTimeInterval(86_400)
        let previous = try codexResetData(
            #"{"available_count":1,"credits":[{"id":"first","expires_at":1800086400}]}"#)
        let refreshed = try codexResetData(
            #"{"available_count":1,"credits":[{"id":"replacement","expires_at":1800086400}]}"#)

        XCTAssertEqual(refreshed.resetCreditCount, previous.resetCreditCount)
        XCTAssertEqual(refreshed.expiriesAt, previous.expiriesAt)
        let content = RateLimitResetsDetail.content(
            count: refreshed.resetCreditCount, expiries: refreshed.expiriesAt, now: now)
        guard case .timeline(let entries, let unknownCount) = content else {
            return XCTFail("expected the timeline for the replacement credit")
        }
        XCTAssertEqual(entries.map(\.date), [expiry])
        XCTAssertEqual(entries.map(\.quantity), [1])
        XCTAssertEqual(unknownCount, 0)
    }

    func testRendersGroupedExpiryAndUnknownCreditCount() throws {
        let expiry = Date().addingTimeInterval(4 * 86_400 + 3_600)
        func render(count: Int) throws -> CGImage {
            let detail = RateLimitResetsDetail(count: count, expiries: [expiry, expiry], onHoverChange: { _ in })
            let renderer = ImageRenderer(content: detail.environment(\.colorScheme, .light).background(.white))
            renderer.scale = 2
            return try XCTUnwrap(renderer.cgImage)
        }

        let complete = try render(count: 2)
        let partial = try render(count: 4)
        XCTAssertEqual(partial.width, complete.width)
        XCTAssertGreaterThan(partial.height, complete.height)

        if let path = ProcessInfo.processInfo.environment["EGASU_RESET_DETAIL_TEST_SNAPSHOT"] {
            let bitmap = NSBitmapImageRep(cgImage: partial)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
        }
    }

    private func codexResetData(_ body: String) throws -> WidgetData {
        let usage = HTTPResponse(statusCode: 200, headers: [:], body: Data("{}".utf8))
        let credits = HTTPResponse(statusCode: 200, headers: [:], body: Data(body.utf8))
        let mapped = try CodexUsageMapper.mapUsageResponse(usage, resetCredits: credits, now: now)
        let codex = CodexProvider()
        let descriptor = try XCTUnwrap(codex.widgetDescriptors.first { $0.id == "codex.rateLimitResets" })
        let snapshot = ProviderSnapshot.make(provider: codex.provider, plan: nil, lines: mapped.lines, refreshedAt: now)
        return WidgetDataResolver.resolve(descriptor, snapshot: snapshot, codexResetWatch: .init())
    }
}
