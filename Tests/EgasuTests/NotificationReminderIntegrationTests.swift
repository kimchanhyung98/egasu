import Foundation
import XCTest
@testable import Egasu

@MainActor
final class NotificationReminderIntegrationTests: XCTestCase {
    @MainActor
    private final class Center {
        var requests: [String: ScheduledReminder] = [:]
        var reads: [String: Int] = [:]
        var writes: [String: Int] = [:]
        let now = Date(timeIntervalSince1970: floor(Date.now.timeIntervalSince1970))

        func scheduler(prefix: String) -> ScheduledReminders {
            ScheduledReminders(
                prefix: prefix, now: { self.now },
                pending: {
                    self.reads[prefix, default: 0] += 1
                    return Array(self.requests.values)
                },
                schedule: { item, isCurrent in
                    guard isCurrent() else { return }
                    self.writes[prefix, default: 0] += 1
                    self.requests[item.id] = item
                },
                remove: { ids in ids.forEach { self.requests[$0] = nil } })
        }

        func pending(prefix: String) -> [String: ScheduledReminder] {
            requests.filter { $0.key.hasPrefix(prefix) }
        }
    }

    private let quotaPrefix = QuotaResetReminders.prefix
    private let creditPrefix = CodexCreditExpiryReminders.prefix

    func testBothTogglesReconcileIndependentlyAcrossAllRestartConfigurations() async throws {
        for quota in [false, true] {
            for credit in [false, true] {
                try await checkRestart(quota: quota, credit: credit)
            }
        }
    }

    func testConfirmedCreditCancellationPreservesActualQuotaReservations() async throws {
        let center = Center()
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = try reading(at: center.now)
        let (store, settings) = launch(reading: reading, defaults: defaults, suite: suite, center: center)
        settings.weeklyMonthlyResetReminders = true
        settings.codexCreditExpiry = true
        let outcome = await store.refresh(providerID: "codex", force: true)
        XCTAssertEqual(outcome, .refreshed)
        await waitFor { center.requests.count == 4 }
        let quotaRequests = center.pending(prefix: quotaPrefix)
        let quotaWrites = center.writes[quotaPrefix]
        XCTAssertEqual(quotaRequests.count, 2)
        let binding = try XCTUnwrap(reading.codexResetClaimBinding)
        store.codexCreditsUnavailable(
            cardID: "codex", credits: .expiry(binding: binding, date: center.now.addingTimeInterval(3 * 86_400)))
        await waitFor { center.pending(prefix: creditPrefix).isEmpty }
        XCTAssertEqual(center.requests, quotaRequests)
        XCTAssertEqual(center.writes[quotaPrefix], quotaWrites)
        XCTAssertTrue(settings.weeklyMonthlyResetReminders)
        XCTAssertTrue(settings.codexCreditExpiry)
    }

    func testChangedCodexCredentialsCancelBothReminderKindsForTheAffectedCard() async throws {
        let center = Center()
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try reading(at: center.now)
        let other = try reading(at: center.now, profileID: UUID().uuidString, subject: "second-user")
        let transient: [(any Error, ErrorCategory)] = [
            (CodexUsageError.connectionFailed, .network),
            (CodexUsageError.requestFailed(429), .rateLimited),
            (KeychainError.accessBusy, .credentialAccess)
        ]
        let changed = CodexAuthError.credentialsChanged
        let provider = CodexProvider.makeProvider()
        let errors = transient.map { ProviderSnapshot.error(provider: provider, error: $0.0) }
        let (store, settings) = launch(
            reading: first, defaults: defaults, suite: suite, center: center,
            following: errors + [.error(provider: provider, error: changed), first], others: [other])
        XCTAssertNotEqual(first.liveQuotaAccountKey, other.liveQuotaAccountKey)
        settings.weeklyMonthlyResetReminders = true
        settings.codexCreditExpiry = true

        let otherOutcome = await store.refresh(providerID: other.providerID, force: true)
        XCTAssertEqual(otherOutcome, .refreshed)
        await waitFor { center.requests.count == 4 }
        let otherRequests = center.requests
        let firstOutcome = await store.refresh(providerID: first.providerID, force: true)
        XCTAssertEqual(firstOutcome, .refreshed)
        await waitFor { center.requests.count == 8 }
        XCTAssertEqual(center.pending(prefix: quotaPrefix).count, 4)
        XCTAssertEqual(center.pending(prefix: creditPrefix).count, 4)
        let initial = center.requests

        for (_, category) in transient {
            let reads = center.reads
            let outcome = await store.refresh(providerID: first.providerID, force: true)
            XCTAssertEqual(outcome, .failed)
            XCTAssertEqual(store.refreshResults[first.providerID]?.failure?.category, category)
            let witnessOutcome = await store.refresh(providerID: other.providerID, force: true)
            XCTAssertEqual(witnessOutcome, .refreshed)
            await waitForBothSchedulers(in: center, after: reads)
            XCTAssertEqual(center.requests, initial)
        }

        let changedOutcome = await store.refresh(providerID: first.providerID, force: true)
        XCTAssertEqual(changedOutcome, .failed)
        let failure = try XCTUnwrap(store.refreshResults[first.providerID]?.failure)
        XCTAssertEqual(failure.category, .other)
        XCTAssertNil(failure.authenticationIssue)
        XCTAssertEqual(failure.presentation, UserFacingErrors.presentation(changed))
        await waitFor { center.requests == otherRequests }

        let retryOutcome = await store.refresh(providerID: first.providerID, force: true)
        XCTAssertEqual(retryOutcome, .refreshed)
        await waitFor { center.requests == initial }
    }

    func testCodexCredentialReadFailureDuringTokenSavePreservesBothReminderKinds() async throws {
        let scenarios: [(source: CredentialSource, proactive: Bool)] = [
            (.file, true), (.keychain, true), (.keychain, false), (.savedAccount, false)
        ]
        for (source, proactive) in scenarios {
            let center = Center()
            let suite = "NotificationReminderIntegrationTests.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let failure = try await codexSaveVerificationFailure(at: center.now, source: source, proactive: proactive)
            let first = try reading(at: center.now)
            let other = try reading(at: center.now, profileID: UUID().uuidString, subject: "second-user")
            let (store, settings) = launch(
                reading: first, defaults: defaults, suite: suite, center: center, following: [failure], others: [other])
            settings.weeklyMonthlyResetReminders = true
            settings.codexCreditExpiry = true

            let firstOutcome = await store.refresh(providerID: first.providerID, force: true)
            XCTAssertEqual(firstOutcome, .refreshed)
            let otherOutcome = await store.refresh(providerID: other.providerID, force: true)
            XCTAssertEqual(otherOutcome, .refreshed)
            await waitFor { center.requests.count == 8 }
            let initialQuota = center.pending(prefix: quotaPrefix)
            let initialCredits = center.pending(prefix: creditPrefix)
            XCTAssertEqual(initialQuota.count, 4)
            XCTAssertEqual(initialCredits.count, 4)

            let reads = center.reads
            let failedOutcome = await store.refresh(providerID: first.providerID, force: true)
            XCTAssertEqual(failedOutcome, .failed)
            XCTAssertEqual(
                store.refreshResults[first.providerID]?.failure?.category,
                source == .file ? .permission : .credentialAccess
            )
            let witnessOutcome = await store.refresh(providerID: other.providerID, force: true)
            XCTAssertEqual(witnessOutcome, .refreshed)
            await waitForBothSchedulers(in: center, after: reads)
            XCTAssertEqual(center.pending(prefix: quotaPrefix), initialQuota)
            XCTAssertEqual(center.pending(prefix: creditPrefix), initialCredits)
        }
    }

    func testBoundCodexQuotaReadFailureAfterUsageResponsePreservesBothReminderKinds() async throws {
        let center = Center()
        let now = center.now
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let home = "/bound-reminder-credential-verification"
        let path = "\(home)/auth.json"
        let original = #"{"tokens":{"access_token":"fixture-access","account_id":"workspace"}}"#
        let files = FakeFiles([path: original])
        let http = RoutingHTTPClient { request in
            if request.url == CodexUsageClient.usageURL {
                files.unreadablePaths.insert(path)
                return HTTPResponse(
                    statusCode: 200, headers: [:],
                    body: Data(
                        #"{"rate_limit":{"primary_window":{"used_percent":20,"limit_window_seconds":604800}}}"#.utf8))
            }
            return HTTPResponse(statusCode: 200, headers: [:], body: Data(#"{"available_count":0}"#.utf8))
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: FakeKeychain(),
                scope: .home(path: home), expectedIdentityKey: "workspace", now: { now }),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: UUID().uuidString, rootsOverride: []),
            includeSharedUsage: false, now: { now }, pricing: { .empty }
        )

        let failure = await provider.refresh()

        XCTAssertEqual(http.requests.map(\.url), [CodexUsageClient.usageURL, CodexUsageClient.resetCreditsURL])
        XCTAssertEqual(files.files[path], original)
        XCTAssertEqual(failure.errorCategory, .permission)
        XCTAssertEqual(failure.errorPresentation, UserFacingErrors.presentation(CocoaError(.fileReadNoPermission)))
        XCTAssertFalse(failure.invalidatesQuotaIdentity)
        XCTAssertNil(failure.liveQuotaObservedAt)

        let first = try reading(at: now)
        let other = try reading(at: now, profileID: UUID().uuidString, subject: "second-user")
        let (store, settings) = launch(
            reading: first, defaults: defaults, suite: suite, center: center, following: [failure], others: [other])
        settings.weeklyMonthlyResetReminders = true
        settings.codexCreditExpiry = true
        let firstOutcome = await store.refresh(providerID: first.providerID, force: true)
        XCTAssertEqual(firstOutcome, .refreshed)
        let otherOutcome = await store.refresh(providerID: other.providerID, force: true)
        XCTAssertEqual(otherOutcome, .refreshed)
        await waitFor { center.requests.count == 8 }
        let requests = center.requests
        let reads = center.reads

        let failedOutcome = await store.refresh(providerID: first.providerID, force: true)
        XCTAssertEqual(failedOutcome, .failed)
        let witnessOutcome = await store.refresh(providerID: other.providerID, force: true)
        XCTAssertEqual(witnessOutcome, .refreshed)
        await waitForBothSchedulers(in: center, after: reads)
        XCTAssertEqual(center.requests, requests)
    }

    private enum CredentialSource: Sendable, Equatable { case file, keychain, savedAccount }

    private func codexSaveVerificationFailure(
        at now: Date, source: CredentialSource, proactive: Bool
    ) async throws -> ProviderSnapshot {
        let expiry = Int(now.addingTimeInterval(proactive ? 60 : 3_600).timeIntervalSince1970)
        let payload = Data(#"{"sub":"fixture-user","exp":\#(expiry)}"#.utf8).base64EncodedString()
        let original =
            #"{"tokens":{"access_token":"e30.\#(payload).signature","refresh_token":"fixture-refresh","account_id":"workspace"}}"#

        let files = FakeFiles()
        let keychain = SwitchRecoveryKeychain()
        let home = "/reminder-credential-verification"
        let path = "\(home)/auth.json"
        let service = CodexAuthStore.keychainService
        let profileID = "fixture"
        let snapshotService = AccountCredentialVault.service(family: "codex", profileID: profileID)
        let savedEntry = String(
            decoding: try JSONEncoder().encode(AccountCredentialVault.Entry(credential: original)), as: UTF8.self)
        let scope: CodexCredentialScope
        switch source {
        case .file:
            scope = .home(path: home)
            files.files[path] = original
        case .keychain:
            scope = .standard
            keychain.values[service] = original
        case .savedAccount:
            scope = .accountSnapshot(profileID: profileID)
            keychain.currentUserValues[snapshotService] = savedEntry
        }
        let readError: any Error =
            source == .file
            ? CocoaError(.fileReadNoPermission)
            : KeychainError.readFailed("Fixture Keychain verification read was denied.")
        let http = RoutingHTTPClient { request in
            guard request.url == CodexUsageClient.refreshURL else {
                return HTTPResponse(statusCode: 401, headers: [:], body: Data())
            }
            if source == .file {
                files.unreadablePaths.insert(path)
            } else {
                keychain.beforeRead = { _ in throw readError }
            }
            return HTTPResponse(
                statusCode: 200, headers: [:],
                body: Data(
                    #"{"access_token":"fixture-rotated","refresh_token":"fixture-refresh-rotated"}"#.utf8))
        }
        let provider = CodexProvider(
            authStore: CodexAuthStore(
                environment: FakeEnvironment(), files: files, keychain: keychain, scope: scope, now: { now }),
            usageClient: CodexUsageClient(http: http),
            logUsageScanner: CodexLogUsageScanner(cacheIdentityOverride: UUID().uuidString, rootsOverride: []),
            includeSharedUsage: false, now: { now }, pricing: { .empty }
        )

        let snapshot = await provider.refresh()

        let requested =
            proactive ? [CodexUsageClient.refreshURL] : [CodexUsageClient.usageURL, CodexUsageClient.refreshURL]
        XCTAssertEqual(http.requests.map(\.url), requested)
        switch source {
        case .file: XCTAssertEqual(files.files[path], original)
        case .keychain: XCTAssertEqual(keychain.values[service], original)
        case .savedAccount: XCTAssertEqual(keychain.currentUserValues[snapshotService], savedEntry)
        }
        XCTAssertEqual(keychain.writeCount, 0)
        XCTAssertEqual(snapshot.errorPresentation, UserFacingErrors.presentation(readError))
        XCTAssertFalse(snapshot.invalidatesQuotaIdentity)
        return snapshot
    }

    func testChangedCodexCredentialsPreserveReservationsSupportedByAnActiveAlias() async throws {
        let center = Center()
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = try reading(at: center.now)
        let aliasReading = try reading(at: center.now.addingTimeInterval(-60), profileID: UUID().uuidString)
        XCTAssertEqual(first.liveQuotaAccountKey, aliasReading.liveQuotaAccountKey)
        let provider = CodexProvider.makeProvider()
        let (store, settings) = launch(
            reading: first, defaults: defaults, suite: suite, center: center,
            following: [.error(provider: provider, error: CodexAuthError.credentialsChanged)], others: [aliasReading])
        settings.weeklyMonthlyResetReminders = true
        settings.codexCreditExpiry = true
        for card in [first.providerID, aliasReading.providerID] {
            let outcome = await store.refresh(providerID: card, force: true)
            XCTAssertEqual(outcome, .refreshed)
        }
        await waitFor { center.requests.count == 4 }
        let initial = center.requests
        let writes = center.writes

        let reads = center.reads
        let changedOutcome = await store.refresh(providerID: first.providerID, force: true)
        XCTAssertEqual(changedOutcome, .failed)
        let aliasOutcome = await store.refresh(providerID: aliasReading.providerID, force: true)
        XCTAssertEqual(aliasOutcome, .refreshed)
        await waitForBothSchedulers(in: center, after: reads)
        XCTAssertEqual(center.requests, initial)
        XCTAssertEqual(center.writes, writes)

        let remaining = runtime(for: first)
        store.replaceProviderCatalog(
            registry: WidgetRegistry.from([remaining]), providers: [remaining],
            identityKeys: [first.providerID: "workspace"])
        await waitFor { center.requests.isEmpty }
    }

    private func checkRestart(quota: Bool, credit: Bool) async throws {
        let center = Center()
        let suite = "NotificationReminderIntegrationTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let reading = try reading(at: center.now)
        let unrelated = ScheduledReminder(
            id: "other.notification", date: center.now.addingTimeInterval(345_600), title: "", subtitle: "", body: "")
        center.requests[unrelated.id] = unrelated

        let beforeRestart: [String: ScheduledReminder]
        do {
            let (store, settings) = launch(reading: reading, defaults: defaults, suite: suite, center: center)
            XCTAssertFalse(settings.anyEnabled)
            XCTAssertFalse(settings.weeklyMonthlyResetReminders)
            XCTAssertFalse(settings.codexCreditExpiry)
            settings.weeklyMonthlyResetReminders = true
            settings.codexCreditExpiry = true
            let outcome = await store.refresh(providerID: "codex", force: true)
            XCTAssertEqual(outcome, .refreshed)
            await waitFor { center.requests.count == 5 }

            let creditRequests = center.pending(prefix: creditPrefix)
            let creditWrites = center.writes[creditPrefix]
            XCTAssertEqual(creditRequests.count, 2)
            settings.weeklyMonthlyResetReminders = quota
            if !quota { await waitFor { center.pending(prefix: quotaPrefix).isEmpty } }
            XCTAssertEqual(center.pending(prefix: creditPrefix), creditRequests)
            XCTAssertEqual(center.writes[creditPrefix], creditWrites)

            let quotaRequests = center.pending(prefix: quotaPrefix)
            let quotaWrites = center.writes[quotaPrefix]
            XCTAssertEqual(quotaRequests.count, quota ? 2 : 0)
            settings.codexCreditExpiry = credit
            if !credit { await waitFor { center.pending(prefix: creditPrefix).isEmpty } }
            XCTAssertEqual(center.pending(prefix: quotaPrefix), quotaRequests)
            XCTAssertEqual(center.writes[quotaPrefix], quotaWrites)
            XCTAssertEqual(center.requests[unrelated.id], unrelated)
            beforeRestart = center.requests
        }

        let reads = center.reads
        let (relaunched, restoredSettings) = launch(reading: reading, defaults: defaults, suite: suite, center: center)
        XCTAssertEqual(restoredSettings.weeklyMonthlyResetReminders, quota)
        XCTAssertEqual(restoredSettings.codexCreditExpiry, credit)
        XCTAssertEqual(restoredSettings.anyEnabled, quota || credit)
        let cache = try XCTUnwrap(relaunched.localSnapshots["codex"])
        XCTAssertNil(cache.liveQuotaAccountKey)
        await waitFor {
            center.reads[self.quotaPrefix, default: 0] > reads[self.quotaPrefix, default: 0]
                && center.reads[self.creditPrefix, default: 0] > reads[self.creditPrefix, default: 0]
                && center.requests == [unrelated.id: unrelated]
        }

        let outcome = await relaunched.refresh(providerID: "codex", force: true)
        XCTAssertEqual(outcome, .refreshed)
        await waitFor { center.requests == beforeRestart }
        let deadlines = center.requests.values.filter { $0.id != unrelated.id }.map(\.date).sorted()
        let quotaDates = quota ? [24.0, 36].map { center.now.addingTimeInterval($0 * 3600) } : []
        let creditDates = credit ? [48.0, 60].map { center.now.addingTimeInterval($0 * 3600) } : []
        XCTAssertEqual(deadlines, quotaDates + creditDates)
    }

    private func launch(
        reading: ProviderSnapshot, defaults: UserDefaults, suite: String, center: Center,
        following: [ProviderSnapshot] = [], others: [ProviderSnapshot] = []
    ) -> (WidgetDataStore, NotificationSettingsStore) {
        let settings = NotificationSettingsStore(defaults: defaults)
        let enablement = ProviderEnablementStore(defaults: defaults)
        let providers = [runtime(for: reading, following: following)] + others.map { runtime(for: $0) }
        let identities = Dictionary(uniqueKeysWithValues: providers.map { ($0.provider.id, "workspace") })
        let store = WidgetDataStore(
            registry: WidgetRegistry.from(providers), providers: providers,
            cache: ProviderSnapshotCache(userDefaults: defaults, storageDomainName: suite, now: { center.now }),
            defaults: defaults, isProviderEnabled: { enablement.isEnabled($0) },
            now: { center.now }, notificationSettings: { settings },
            providerIdentityKeys: identities)
        let quota = QuotaResetReminders(scheduler: center.scheduler(prefix: quotaPrefix), defaults: defaults)
        store.onQuotaInvalidated = { quota.invalidate($0) }
        store.onFreshSnapshot = { snapshot, _, _ in quota.receivedSnapshot(snapshot) }
        store.onRefreshOutcome = { id, outcome, category, _, _ in
            if outcome == .failed { quota.refreshFailed(for: id, category: category) }
        }
        quota.observe(settings: settings, dataStore: store, enablement: enablement)
        store.configureCodexCreditReminders(scheduler: center.scheduler(prefix: creditPrefix))
        return (store, settings)
    }

    private func runtime(for reading: ProviderSnapshot, following: [ProviderSnapshot] = []) -> SequenceProviderRuntime {
        let provider = CodexProvider.makeProvider(id: reading.providerID)
        return SequenceProviderRuntime(
            provider: provider, descriptors: CodexProvider(provider: provider).widgetDescriptors,
            snapshots: [reading] + following)
    }

    private func reading(
        at now: Date, profileID: String? = nil, subject: String = "fixture-user"
    ) throws -> ProviderSnapshot {
        let payload = try JSONSerialization.data(withJSONObject: ["sub": subject]).base64EncodedString()
        let auth = CodexAuth(tokens: CodexTokens(accessToken: "e30.\(payload).signature", accountID: "workspace"))
        let source: CodexAuthState.Source = profileID.map { .accountSnapshot(profileID: $0) } ?? .keychain
        let binding = try XCTUnwrap(CodexResetClaimBinding(authState: CodexAuthState(auth: auth, source: source)))
        let card = profileID.map { AccountUsageCardPlanner.cardID(family: "codex", profileID: $0) } ?? "codex"
        var reading = ProviderSnapshot.make(
            provider: CodexProvider.makeProvider(id: card), plan: nil,
            lines: [
                .progress(
                    label: "Weekly", used: 20, limit: 100, format: .percent,
                    resetsAt: now.addingTimeInterval(2 * 86_400), periodDurationMs: MetricPeriod.weekMs),
                .values(
                    label: "Rate Limit Resets", values: [MetricValue(number: 1, kind: .count)],
                    expiriesAt: [now.addingTimeInterval(3 * 86_400)])
            ], refreshedAt: now, liveQuotaObservedAt: now,
            liveQuotaAccountKey: try XCTUnwrap(binding.verifiedAccountKey),
            codexResetClaimBinding: binding)
        reading.codexSwitchIdentity = try XCTUnwrap(DefaultAccountObserver.codexIdentity(for: auth)?.identityKey)
        return reading
    }

    private func waitForBothSchedulers(in center: Center, after reads: [String: Int]) async {
        await waitFor {
            center.reads[self.quotaPrefix, default: 0] > reads[self.quotaPrefix, default: 0]
                && center.reads[self.creditPrefix, default: 0] > reads[self.creditPrefix, default: 0]
        }
    }

    private func waitFor(_ condition: () -> Bool, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() && ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertTrue(condition(), line: line)
    }
}
