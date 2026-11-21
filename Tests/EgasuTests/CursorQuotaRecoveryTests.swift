import XCTest
@testable import Egasu

private actor CursorRecoveryResponses {
    enum Scenario: Sendable {
        case enterprise
        case unified(hasWeekly: Bool)
    }

    let scenario: Scenario
    var refreshCount = 0

    init(_ scenario: Scenario) { self.scenario = scenario }

    func respond(_ request: HTTPRequest) -> HTTPResponse {
        let text: String
        var status = 200
        switch request.url.lastPathComponent {
        case "GetCurrentPeriodUsage":
            refreshCount += 1
            if case .unified(hasWeekly: true) = scenario {
                text =
                    #"{"enabled":true,"billingCycleStart":1799712000000,"billingCycleEnd":1800316800000,"planUsage":{"totalPercentUsed":20}}"#
            } else {
                text = #"{"enabled":true}"#
            }
        case "GetPlanInfo":
            switch scenario {
            case .enterprise: text = #"{"planInfo":{"planName":"enterprise"}}"#
            case .unified: text = #"{"isMerged":true,"planInfo":{"planName":"ultra"}}"#
            }
        case "usage-summary":
            status = refreshCount == 2 ? 503 : 200
            let percent = refreshCount == 1 ? 100 : 20
            text =
                #"{"billingCycleStart":"2027-01-12T00:00:00Z","billingCycleEnd":"2027-01-19T00:00:00Z","individualUsage":{"plan":{"totalPercentUsed":\#(percent)}}}"#
        case "usage":
            let used = refreshCount == 3 ? 10 : 2
            text = #"{"startOfMonth":"2027-01-01T00:00:00Z","gpt-4":{"numRequests":\#(used),"maxRequestUsage":10}}"#
        case "GetComplatCreditBalance":
            text = #"{"usdRemainingCents":"0"}"#
        case "usage-status":
            let cents = refreshCount == 1 ? 10000 : 2000
            text =
                #"{"availability":"available","monthlyUsage":{"periodStart":"2027-01-01T00:00:00Z","resetsAt":"2027-02-01T00:00:00Z","usedCents":\#(cents),"limitCents":10000}}"#
        case "get-filtered-usage-events":
            text = #"{"totalUsageEventsCount":0}"#
        default:
            status = 404
            text = "{}"
        }
        return HTTPResponse(statusCode: status, headers: [:], body: Data(text.utf8))
    }
}

extension CursorOptionalEndpointTests {
    private func makeRecoveryStore(
        _ scenario: CursorRecoveryResponses.Scenario, metrics: Set<String>,
        post: @escaping QuotaNotificationEvaluator.Post
    ) throws -> WidgetDataStore {
        let responses = CursorRecoveryResponses(scenario)
        let provider = makeProvider { await responses.respond($0) }
        let suite = "CursorQuotaRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        let settings = NotificationSettingsStore(defaults: defaults)
        settings.quotaRecovered = true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        return WidgetDataStore(
            registry: .from([provider]), providers: [provider],
            cache: ProviderSnapshotCache(userDefaults: defaults, now: { now }), defaults: defaults,
            orderedDescriptors: { provider.widgetDescriptors.filter { metrics.contains($0.id) } },
            now: { now }, notificationSettings: { settings }, postNotification: post)
    }

    func testRequestFallbackPreservesWeeklyRecoveryAndTracksRequestsSeparately() async throws {
        var posts: [String] = []
        let store = try makeRecoveryStore(.enterprise, metrics: ["cursor.usage", "cursor.requests"]) {
            id, _, _, _, current in
            guard current() else { return false }
            posts.append(id)
            return true
        }
        _ = await store.refresh(providerID: "cursor", force: true, trigger: .manual)
        let first = try XCTUnwrap(store.localSnapshots["cursor"])
        XCTAssertEqual(first.liveQuotaAccountKey, "user")
        XCTAssertEqual(progress(first.lines, "Total usage")?.used, 100)
        XCTAssertEqual(progress(first.lines, "Requests")?.used, 2)
        XCTAssertTrue(posts.isEmpty)

        _ = await store.refresh(providerID: "cursor", force: true, trigger: .manual)
        let second = try XCTUnwrap(store.localSnapshots["cursor"])
        XCTAssertEqual(second.liveQuotaAccountKey, first.liveQuotaAccountKey)
        XCTAssertEqual(second.isDegraded, true)
        guard case .progress(_, 2, 10, .count(suffix: "requests"), _, _, _) = second.line(label: "Total usage")
        else { return XCTFail("Expected the monthly request pool in Total usage after the summary failed") }
        XCTAssertTrue(posts.isEmpty)

        _ = await store.refresh(providerID: "cursor", force: true, trigger: .manual)
        let third = try XCTUnwrap(store.localSnapshots["cursor"])
        XCTAssertEqual(progress(third.lines, "Total usage")?.used, 20)
        XCTAssertEqual(progress(third.lines, "Requests")?.used, 10)
        XCTAssertEqual(posts, ["cursor.quotaRecovered"])

        _ = await store.refresh(providerID: "cursor", force: true, trigger: .manual)
        XCTAssertEqual(posts, ["cursor.quotaRecovered", "cursor.quotaRecovered"])
    }

    func testMonthlyExtraUsageRecoversWithOrWithoutWeeklyQuota() async throws {
        for hasWeekly in [false, true] {
            var posts: [String] = []
            let store = try makeRecoveryStore(.unified(hasWeekly: hasWeekly), metrics: ["cursor.onDemand"]) {
                id, _, _, _, current in
                guard current() else { return false }
                posts.append(id)
                return true
            }
            for expectedSpent in [100.0, 20.0] {
                _ = await store.refresh(providerID: "cursor", force: true, trigger: .manual)
                let snapshot = try XCTUnwrap(store.localSnapshots["cursor"])
                XCTAssertEqual(snapshot.liveQuotaAccountKey, "user")
                XCTAssertEqual(progress(snapshot.lines, "On-demand")?.used, expectedSpent)
                XCTAssertEqual(progress(snapshot.lines, "On-demand")?.limit, 100)
                XCTAssertEqual(snapshot.line(label: "Total usage") != nil, hasWeekly)
                let observed = try XCTUnwrap(snapshot.liveQuotaObservedAt)
                let softLimit = SoftLimitObservation.project(
                    snapshot: snapshot, descriptors: store.limitDescriptorsByProvider["cursor"] ?? [],
                    window: .all, now: observed)
                XCTAssertEqual(softLimit?.maximumUsedFraction(at: observed), hasWeekly ? 0.2 : nil)
                if expectedSpent == 100 { XCTAssertTrue(posts.isEmpty) }
            }
            XCTAssertEqual(posts, ["cursor.quotaRecovered"])
        }
    }
}
