import DesktopWidgetSupport
import XCTest

final class DesktopWidgetSupportTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let weekly = DesktopWidgetMetric(id: "codex.weekly", name: "Weekly", value: "0%")
    private let session = DesktopWidgetMetric(id: "codex.session", name: "Session", value: "18%")

    private func account(_ id: String, _ metrics: [DesktopWidgetMetric]) -> DesktopWidgetAccount {
        DesktopWidgetAccount(id: id, providerID: "codex", name: id, state: .current, metrics: metrics)
    }

    private func content(_ accounts: [DesktopWidgetAccount]) -> DesktopWidgetContent {
        DesktopWidgetContent(
            accounts: accounts, priority: DesktopWidgetPriority(state: .allClear, rows: []), language: "en")
    }

    private func selection(_ account: String, _ metric: String) -> DesktopWidgetSelection {
        DesktopWidgetSelection(accountID: account, metricID: metric)
    }

    func testSelectionPreservesWidgetAccountOrderAndDashboardMetricOrder() {
        let content = content([account("personal", [session, weekly]), account("work", [session, weekly])])
        let selections = [
            selection("work", weekly.id), selection("personal", weekly.id),
            selection("work", session.id), selection("work", weekly.id)
        ]
        let page = content.selectedAccounts(selections, maximumAccounts: 2, maximumMetrics: 2)
        XCTAssertEqual(page.accounts.map(\.id), ["work", "personal"])
        XCTAssertEqual(page.accounts.map { $0.metrics.map(\.id) }, [[session.id, weekly.id], [weekly.id]])
        XCTAssertEqual(page.accounts.last?.metrics.first?.value, "0%")
        XCTAssertEqual(page.remainingAccounts, 0)
        XCTAssertEqual(page.remainingMetrics, 0)
    }

    func testOnlySelectedVisibleMetricsOnVisibleAccountsCountTowardOverflow() {
        let content = content([
            account("a", [session, weekly]), account("b", [session, weekly]), account("c", [session, weekly])
        ])
        let selections = [
            selection("a", weekly.id), selection("a", session.id), selection("a", "hidden"),
            selection("b", weekly.id), selection("c", weekly.id), selection("c", session.id)
        ]
        let page = content.selectedAccounts(selections, maximumAccounts: 2, maximumMetrics: 1)
        XCTAssertEqual(page.accounts.map { $0.metrics.map(\.id) }, [[session.id], [weekly.id]])
        XCTAssertEqual(page.remainingAccounts, 1)
        XCTAssertEqual(page.remainingMetrics, 1)
    }

    func testRemovedAccountAndHiddenMetricRetainSlotsWithoutSubstitutingOtherValues() {
        let content = content([account("present", [session, weekly])])
        let selections = [selection("removed", weekly.id), selection("present", "hidden")]
        let page = content.selectedAccounts(selections, maximumAccounts: 2, maximumMetrics: 2)
        XCTAssertEqual(page.accounts.map(\.id), ["removed", "present"])
        XCTAssertNil(page.accounts.first?.account)
        XCTAssertEqual(page.accounts.last?.account?.id, "present")
        XCTAssertTrue(page.accounts.allSatisfy { $0.metrics.isEmpty })
        XCTAssertEqual(page.remainingMetrics, 0)
    }

    func testSelectionIdentifierPreservesBothComponentsAndAccountScopes() {
        let profile = DesktopWidgetAccountID.profile(providerID: "codex", profileID: "work")
        let current = DesktopWidgetAccountID.current(providerID: "codex")
        let shared = DesktopWidgetAccountID.shared(providerID: "codex")
        XCTAssertEqual(Set([profile, current, shared]).count, 3)
        let selected = selection(profile, weekly.id)
        XCTAssertEqual(DesktopWidgetSelection(id: selected.id)?.accountID, profile)
        XCTAssertEqual(DesktopWidgetSelection(id: selected.id)?.metricID, weekly.id)
        XCTAssertNotEqual(selected.id, selection(current, weekly.id).id)
        XCTAssertNotEqual(selected.id, selection(profile, session.id).id)
        XCTAssertNil(DesktopWidgetSelection(id: ""))
    }

    func testTimelineSchedulesFutureUniqueTransitionsAndPreservesTheLastObservedValue() {
        let staleAt = now.addingTimeInterval(120)
        let reset = now.addingTimeInterval(180)
        let unselectedReset = now.addingTimeInterval(240)
        let metrics = [
            DesktopWidgetMetric(id: "one", name: "One", value: "0%", resetsAt: reset),
            DesktopWidgetMetric(id: "two", name: "Two", value: "18%", resetsAt: reset),
            DesktopWidgetMetric(id: "three", name: "Three", resetsAt: unselectedReset),
            DesktopWidgetMetric(id: "past", name: "Past", resetsAt: now)
        ]
        let account = DesktopWidgetAccount(
            id: "work", providerID: "codex", name: "Work", state: .current, observedAt: now,
            staleAt: staleAt, metrics: metrics
        )
        let otherStaleAt = now.addingTimeInterval(360)
        let otherReset = now.addingTimeInterval(480)
        let other = DesktopWidgetAccount(
            id: "personal", providerID: "codex", name: "Personal", state: .current, observedAt: now,
            staleAt: otherStaleAt, metrics: [DesktopWidgetMetric(id: "one", name: "One", resetsAt: otherReset)]
        )
        let content = content([account, other])
        XCTAssertEqual(account.state(at: staleAt.addingTimeInterval(-1)), .current)
        XCTAssertEqual(account.state(at: staleAt), .stale)
        XCTAssertEqual(content.timelineDates(after: now), [staleAt, reset, unselectedReset, otherStaleAt, otherReset])
        XCTAssertEqual(content.timelineDates(after: now, including: [account.id: ["one"]]), [staleAt, reset])
        XCTAssertEqual(content.timelineDates(after: now, including: [account.id: ["hidden"]]), [staleAt])
        XCTAssertEqual(content.timelineDates(after: staleAt, including: [account.id: ["one"]]), [reset])
        XCTAssertEqual(content.timelineDates(after: reset, including: [account.id: ["one"]]), [])
        XCTAssertEqual(content.timelineDates(after: now, including: [:]), [])
        let page = content.selectedAccounts([selection(account.id, "one")], maximumAccounts: 1, maximumMetrics: 1)
        XCTAssertEqual(page.accounts.first?.metrics.first?.value, "0%")
    }

    func testSharedFileHandlesMissingUnsupportedAndUnreadableSnapshotsAndWritesOnlyChanges() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("snapshot.json")
        let store = DesktopWidgetStore(fileURL: url)
        guard case .missing = store.read() else { return XCTFail("Expected a missing snapshot") }
        try Data(#"{"schemaVersion":8192}"#.utf8).write(to: url)
        guard case .unsupportedVersion(8192) = store.read() else { return XCTFail("Expected an unsupported schema") }
        try Data("{".utf8).write(to: url)
        guard case .unreadable = store.read() else { return XCTFail("Expected an unreadable snapshot") }

        let first = content([account("work", [weekly])])
        let later = now.addingTimeInterval(120)
        XCTAssertTrue(try store.write(first, at: now))
        let originalBytes = try Data(contentsOf: url)
        XCTAssertFalse(try store.write(first, at: later))
        XCTAssertEqual(try Data(contentsOf: url), originalBytes)
        guard case .snapshot(let snapshot) = store.read() else { return XCTFail("Expected the first snapshot") }
        XCTAssertEqual(snapshot.content, first)
        XCTAssertEqual(snapshot.generatedAt, now)

        let changed = content([account("work", [session])])
        XCTAssertTrue(try store.write(changed, at: later))
        guard case .snapshot(let updated) = store.read() else { return XCTFail("Expected the changed snapshot") }
        XCTAssertEqual(updated.content, changed)
        XCTAssertEqual(updated.generatedAt, later)

        for invalid in [
            content([account("work", []), account("work", [])]),
            content([account("work", [weekly, weekly])])
        ] {
            XCTAssertThrowsError(try store.write(invalid, at: later))
            XCTAssertEqual(store.read(), .snapshot(updated))
            try JSONEncoder().encode(DesktopWidgetSnapshot(content: invalid, generatedAt: later)).write(to: url)
            XCTAssertEqual(store.read(), .unreadable)
            XCTAssertTrue(try store.write(changed, at: later))
        }
    }
}
