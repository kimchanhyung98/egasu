import DesktopWidgetSupport
import XCTest
@testable import Egasu

final class DesktopWidgetProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func profile(_ id: String, label: String = "Work", created: TimeInterval = 0) -> AccountProfile {
        AccountProfile(
            id: id, family: "codex", label: label, identityKey: "private-identity-\(id)",
            createdAt: Date(timeIntervalSince1970: created))
    }

    private func line(_ cardID: String, _ key: String, used: Double) -> DashboardLine {
        let name = key.capitalized
        var data = WidgetData(title: name, icon: .providerMark("codex"), kind: .percent, used: used, limit: 100)
        data.resetsAt = now.addingTimeInterval(2_000)
        let descriptor = WidgetDescriptor(id: "\(cardID).\(key)", providerID: cardID, metricLabel: name, sample: data)
        return DashboardLine(descriptor: descriptor, data: data)
    }

    private func card(_ id: String, _ lines: [DashboardLine] = []) -> DashboardAccount {
        let provider = Provider(id: id, displayName: "Codex", icon: .providerMark("codex"))
        return DashboardAccount(provider: provider, providerName: "Codex", name: nil, lines: lines)
    }

    func testSharedHistoryKeepsOneProviderKeyAndProfilesFollowLoginRotation() {
        let managed = profile("work")
        let weekly = line("codex", "weekly", used: 48), today = line("codex", "today", used: 33)
        let active = DesktopWidgetSource.make(
            card: card("codex"), profile: managed, descriptors: [today.descriptor, weekly.descriptor],
            hasSharedMetrics: true)
        XCTAssertEqual(active.map(\.id), ["codex/profile/work", "codex/shared"])
        XCTAssertEqual(active.map { $0.descriptors.map(\.id) }, [["codex.weekly"], ["codex.today"]])

        let otherCard = "codex@profile-work"
        let inactive = DesktopWidgetSource.make(
            card: card(otherCard), profile: managed, descriptors: [line(otherCard, "weekly", used: 48).descriptor],
            hasSharedMetrics: false)
        XCTAssertEqual(inactive.map(\.id), ["codex/profile/work"])
        XCTAssertEqual(inactive[0].descriptors.map { ProviderAccountID.canonicalMetricID($0.id) }, ["codex.weekly"])
        var archived = managed
        archived.isArchived = true
        XCTAssertTrue(
            DesktopWidgetSource.make(card: card(otherCard), profile: archived, descriptors: [], hasSharedMetrics: false)
                .isEmpty)
        XCTAssertTrue(
            DesktopWidgetSource.make(card: card(otherCard), profile: nil, descriptors: [], hasSharedMetrics: false)
                .isEmpty)
    }

    func testEmptyVisibleListKeepsIdentityAndDuplicateNamesStayDistinctInAnyDisplayOrder() {
        L10n.withLanguage(.english) {
            let work = DesktopWidgetSource.make(
                card: card("codex"), profile: profile("a"), descriptors: [], hasSharedMetrics: false)[0]
            let other = DesktopWidgetSource.make(
                card: card("codex@profile-b"), profile: profile("b", created: 2), descriptors: [],
                hasSharedMetrics: false)[0]
            let email = DesktopWidgetSource.make(
                card: card("codex@profile-c"), profile: profile("c", label: "fixture@example.invalid", created: 4),
                descriptors: [], hasSharedMetrics: false)[0]
            let sources = [other, work, email]
            XCTAssertEqual(other.displayName(in: sources, hidingNames: false), "Work · Account 2")
            XCTAssertEqual(other.displayName(in: sources.reversed(), hidingNames: true), "Account 2")
            XCTAssertEqual(email.displayName(in: sources, hidingNames: true), "Account 3")
            XCTAssertFalse(email.displayName(in: sources, hidingNames: false).contains("@"))
            XCTAssertEqual(email.id, "codex/profile/c")
            XCTAssertTrue(email.descriptors.isEmpty)
        }
    }

    func testMatchesDashboardUnitsAndSeparatesNoReadingFromMeasuredZero() {
        L10n.withLanguage(.english) {
            var weekly = line("codex@profile-work", "weekly", used: 0)
            let zero = DesktopWidgetProjection.metric(weekly.descriptor, line: weekly, now: now)
            XCTAssertEqual(zero.id, "codex.weekly")
            XCTAssertEqual(zero.value, "0%")
            XCTAssertEqual(zero.fill, 0)
            XCTAssertEqual(zero.resetsAt, now.addingTimeInterval(2_000))
            XCTAssertNil(zero.detail)
            let missing = DesktopWidgetProjection.metric(weekly.descriptor, line: nil, now: now)
            XCTAssertNil(missing.value)
            XCTAssertNil(missing.fill)
            var cost = weekly.data
            cost.limit = nil
            cost.values = [
                MetricValue(number: 4.08, kind: .dollars), MetricValue(number: 1_200_000, kind: .count, label: "tokens")
            ]
            weekly = DashboardLine(descriptor: weekly.descriptor, data: cost)
            let metric = DesktopWidgetProjection.metric(weekly.descriptor, line: weekly, now: now)
            XCTAssertEqual(metric.value, "$4.08")
            XCTAssertEqual(metric.detail, "1.2M tokens")
            XCTAssertNil(metric.fill)
        }
    }

    func testMeterFillFollowsUsedOrRemainingDisplayAndClampsOverLimit() {
        let weekly = line("codex", "weekly", used: 25)
        XCTAssertEqual(DesktopWidgetProjection.metric(weekly.descriptor, line: weekly, now: now).fill, 0.25)
        var remaining = weekly.data
        remaining.displayMode = .remaining
        let left = DashboardLine(descriptor: weekly.descriptor, data: remaining)
        XCTAssertEqual(DesktopWidgetProjection.metric(left.descriptor, line: left, now: now).fill, 0.75)
        let over = line("codex", "weekly", used: 150)
        XCTAssertEqual(DesktopWidgetProjection.metric(over.descriptor, line: over, now: now).fill, 1)
    }

    func testScheduledForecastUsesAdvertisedTimeAndPreservesFailedReading() {
        L10n.withLanguage(.english) {
            let line = line("codex", "resetWatch", used: 90)
            var data = line.data
            let deadline = now.addingTimeInterval(1_000)
            data.forecast = .init(deadline: deadline, isScheduled: true)
            func reading(at date: Date) -> DesktopWidgetMetric {
                let row = DashboardLine(descriptor: line.descriptor, data: data)
                return DesktopWidgetProjection.metric(row.descriptor, line: row, now: date)
            }
            XCTAssertEqual(reading(at: now).resetsAt, deadline)
            XCTAssertNil(reading(at: deadline.addingTimeInterval(CodexResetWatch.scheduledResetGracePeriod)).resetsAt)
            data.forecast?.refreshFailed = true
            XCTAssertNil(reading(at: now).resetsAt)
            XCTAssertEqual(reading(at: now).detail, "Failed")
        }
    }

    func testPriorityUsesBoardOrderingAndDiscardsUnderlyingErrors() throws {
        try L10n.withLanguage(.english) {
            let owned = [
                line("codex", "weekly", used: 92), line("codex", "session", used: 99), line("codex", "spark", used: 100)
            ]
            let account = card("codex", owned)
            let sources = DesktopWidgetSource.make(
                card: account, profile: profile("work"), descriptors: owned.map(\.descriptor),
                hasSharedMetrics: false)
            let board = PriorityBoard.make(accounts: [account], pinned: ["codex.weekly"], now: now) { _ in
                .unavailable("fixture@example.invalid /tmp/private-path")
            }
            let output = DesktopWidgetProjection.priority(board, enabled: true, sources: sources, now: now)
            XCTAssertEqual(output.rows.map(\.section), [.pinned, .runningOut, .notice, .usedUp])
            XCTAssertEqual(output.rows.map(\.metricID), ["codex.weekly", "codex.session", nil, "codex.spark"])
            XCTAssertEqual(output.rows.last?.value, "Used Up")
            XCTAssertTrue(output.rows.allSatisfy { $0.accountID == "codex/profile/work" })
            let json = String(decoding: try JSONEncoder().encode(output), as: UTF8.self)
            XCTAssertFalse(json.contains("fixture@example.invalid"))
            XCTAssertFalse(json.contains("private-path"))
            XCTAssertFalse(json.contains("private-identity"))
            let disabled = DesktopWidgetProjection.priority(board, enabled: false, sources: sources, now: now)
            XCTAssertEqual(disabled.state, .disabled)
            XCTAssertTrue(disabled.rows.isEmpty)
        }
    }

    @MainActor
    func testHostPublishesSuccessfulReadingWithTimerWarningAndRetainsItAfterARefreshFailure() async throws {
        let date = now
        let suite = "DesktopWidgetProjectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let weekly = line("codex", "weekly", used: 48)
        let account = card("codex", [weekly])
        let success = ProviderSnapshot(
            providerID: account.id, displayName: account.providerName,
            lines: [.progress(label: "Weekly", used: 48, limit: 100, format: .percent, resetsAt: nil)],
            refreshedAt: date)
        let runtime = SequenceProviderRuntime(
            provider: account.provider, descriptors: [weekly.descriptor],
            snapshots: [success, .error(provider: account.provider, error: URLError(.notConnectedToInternet))])
        let store = WidgetDataStore(
            registry: .from([runtime]), providers: [runtime], cache: ProviderSnapshotCache(userDefaults: defaults),
            defaults: defaults, now: { date })
        func published() -> DesktopWidgetContent {
            let dashboard = card(
                "codex", [DashboardLine(descriptor: weekly.descriptor, data: store.data(for: weekly.descriptor))])
            let sources = DesktopWidgetSource.make(
                card: dashboard, profile: nil, descriptors: [weekly.descriptor], hasSharedMetrics: false)
            return AppContainer.desktopWidgetContent(
                sources: sources, dashboard: [dashboard], dataStore: store, pinned: [], hidingNames: false, now: date)
        }

        _ = await store.refresh(providerID: account.id, force: true)
        let warning = "Timer warning for private@example.invalid"
        store.setAutomationWarning([warning], for: account.id)
        XCTAssertNotNil(store.headerNotice(for: account.id))
        let current = published()
        XCTAssertEqual(current.accounts.first?.state, .current)
        XCTAssertEqual(current.accounts.first?.metrics.first?.value, "48%")
        let appBoard = store.priorityBoard(accounts: [account], pinned: [], now: date)
        XCTAssertEqual(appBoard.summary, .unavailable)
        XCTAssertEqual(current.priority.state, .unavailable)
        XCTAssertEqual(appBoard.notices.map(\.id), [account.id])
        XCTAssertEqual(current.priority.rows.map(\.section), [.notice])
        XCTAssertEqual(current.priority.rows.first?.title, L10n.dashboard("Open egasu for details."))
        let json = String(decoding: try JSONEncoder().encode(current), as: UTF8.self)
        XCTAssertFalse(json.contains("Timer warning"))
        XCTAssertFalse(json.contains("private@example.invalid"))

        _ = await store.refresh(providerID: account.id, force: true)
        let failed = published()
        XCTAssertEqual(failed.accounts.first?.state, .failed)
        XCTAssertEqual(failed.accounts.first?.metrics.first?.value, "48%")
    }

    func testBurningFastWidgetSchedulesThePredictionAndKeepsTheObservedValueWhenItExpires() throws {
        let weekly = line("codex", "weekly", used: 95)
        var data = weekly.data
        data.periodDurationMs = 7 * 86_400_000
        data.resetsAt = now.addingTimeInterval(3.5 * 86_400)
        let fast = DashboardLine(descriptor: weekly.descriptor, data: data)
        let account = card("codex", [fast])
        let sources = DesktopWidgetSource.make(
            card: account, profile: nil, descriptors: [fast.descriptor], hasSharedMetrics: false)
        let board = PriorityBoard.make(
            accounts: [account], visibleLevels: [.warning], burningFast: BurningFast(), now: now)
        let priority = DesktopWidgetProjection.priority(board, enabled: true, sources: sources, now: now)
        let deadline = now.addingTimeInterval(try XCTUnwrap(data.runway(now: now)))
        let row = try XCTUnwrap(priority.rows.first)
        let reset = try XCTUnwrap(data.resetsAt)
        let stale = now.addingTimeInterval(600)
        let shared = DesktopWidgetAccount(
            id: row.accountID, providerID: "codex", name: "Work", state: .current, observedAt: now, staleAt: stale,
            metrics: [DesktopWidgetProjection.metric(fast.descriptor, line: fast, now: now)])
        let content = DesktopWidgetContent(accounts: [shared], priority: priority, language: "en")
        XCTAssertEqual(row.section, .runningOut)
        XCTAssertNil(row.detail)
        XCTAssertEqual(row.upcomingExhaustion(at: now), deadline)
        XCTAssertNil(row.upcomingExhaustion(at: deadline))
        XCTAssertNil(row.upcomingExhaustion(at: deadline.addingTimeInterval(1)))
        XCTAssertEqual(content.priorityTimelineDates(after: now), [stale, deadline, reset])
        XCTAssertEqual(content.priorityTimelineDates(after: deadline), [reset])
        XCTAssertEqual(content.timelineDates(after: now), [stale, reset])
        XCTAssertEqual(row.value, data.amountText)
    }

    func testAccountStateAtDeadlineAndPriorityOfFailures() {
        for (available, notice, deadline, expected) in [
            (false, false, nil, DesktopWidgetState.unavailable),
            (true, true, nil, .failed), (true, false, nil, .waiting),
            (true, false, now, .stale), (true, false, now.addingTimeInterval(1), .current),
            (true, true, now.addingTimeInterval(-1), .failed)
        ] {
            XCTAssertEqual(
                DesktopWidgetProjection.state(available: available, refreshFailed: notice, staleAt: deadline, now: now),
                expected)
        }
    }
}
