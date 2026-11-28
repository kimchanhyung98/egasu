import DesktopWidgetSupport
import Observation
import XCTest
@testable import Egasu

@MainActor
final class DesktopWidgetPublisherTests: XCTestCase {
    @Observable
    final class State {
        var names = ["Personal"]

        var content: DesktopWidgetContent {
            DesktopWidgetContent(
                accounts: names.map {
                    DesktopWidgetAccount(id: $0, providerID: "codex", name: $0, state: .waiting, metrics: [])
                },
                priority: DesktopWidgetPriority(state: .waitingForUsage, rows: []),
                language: "en")
        }
    }

    func testPublishesObservedChangesAndFlushesLatestRemovalOnQuit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DesktopWidgetStore(fileURL: directory.appendingPathComponent("widget.json"))
        let state = State()
        let started = expectation(description: "Initial snapshot")
        let renamed = expectation(description: "Renamed account")
        let publisher = DesktopWidgetPublisher(content: { state.content }) { content in
            do {
                try store.write(content)
                switch content.accounts.first?.name {
                case "Personal": started.fulfill()
                case "Work": renamed.fulfill()
                default: break
                }
            } catch {
                XCTFail("Snapshot write failed: \(error)")
            }
        }
        await fulfillment(of: [started], timeout: 5)
        state.names = ["Work"]
        await fulfillment(of: [renamed], timeout: 5)
        state.names = []
        publisher.finish()
        guard case .snapshot(let final) = store.read() else { return XCTFail("Missing final snapshot") }
        XCTAssertEqual(final.content.accounts, [])
    }
}
