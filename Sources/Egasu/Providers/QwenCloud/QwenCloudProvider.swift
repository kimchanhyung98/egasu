import Foundation

@MainActor
final class QwenCloudProvider: CredentialBoundSnapshotProvider {
    let provider = Provider(
        id: "qwencloud", displayName: "QwenCloud", icon: .providerMark("qwencloud"),
        links: [ProviderLink(label: "Dashboard", url: "https://home.qwencloud.com")]
    )
    private let cli: QwenCloudCLI

    init(cli: QwenCloudCLI = QwenCloudCLI()) {
        self.cli = cli
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .percent(id: "qwencloud.weekly", provider: provider, title: "Weekly", showsPeriodWithoutResetDate: false)
                .supportingSoftLimit(.weekly).exportingLimit("weekly", unit: "percent"),
            .percent(id: "qwencloud.monthly", provider: provider, title: "Monthly", showsPeriodWithoutResetDate: false)
                .supportingSoftLimit(.monthly, acceptsMissingDuration: true).exportingLimit("monthly", unit: "percent")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [cli] in (try? cli.login().credentialPresent) == true }
    }

    func currentIdentityKey(allowKeychainInteraction _: Bool) async -> String? {
        await loadOffMainActor { [cli] in try? cli.login().identityKey }
    }

    func refresh() async -> ProviderSnapshot {
        var requestedIdentity: String?
        do {
            let login = try await loadOffMainActor { [cli] in try cli.login() }
            requestedIdentity = login.identityKey
            let usage = try await cli.fetch(login)
            let currentLogin = try await loadOffMainActor { [cli] in try cli.login() }
            try Task.checkCancellation()
            guard currentLogin.credentialPresent != false, currentLogin.identityKey == requestedIdentity else {
                throw QwenCloudError.loginChanged
            }
            let observedAt = Date()
            var snapshot = ProviderSnapshot.make(
                provider: provider, plan: usage.plan, lines: [usage.line], refreshedAt: observedAt,
                liveQuotaObservedAt: observedAt
            )
            snapshot.producedByIdentityKey = requestedIdentity
            return snapshot
        } catch {
            let current = await currentIdentityKey(allowKeychainInteraction: false)
            let changed = requestedIdentity != nil && current != requestedIdentity
            var snapshot = ProviderSnapshot.error(
                provider: provider, error: changed ? QwenCloudError.loginChanged : error)
            snapshot.producedByIdentityKey = current
            return snapshot
        }
    }
}

struct QwenCloudUsage {
    let plan: String?
    let line: MetricLine

    static func parse(_ data: Data) throws -> Self {
        guard let individual = ProviderParse.jsonObject(data)?["individual"] as? [String: Any],
            individual["edition"] as? String == "individual"
        else { throw QwenCloudError.invalidResponse }
        switch individual["status"] as? String {
        case "not_subscribed": throw QwenCloudError.noSubscription
        case "active": break
        default: throw QwenCloudError.invalidResponse
        }
        let weekly = individual["weeklyCredits"] as? [String: Any]
        let monthly = individual["monthlyCredits"] as? [String: Any]
        guard weekly == nil || monthly == nil else { throw QwenCloudError.invalidResponse }
        guard let credits = weekly ?? monthly else {
            let diagnostics = individual["diagnostics"] as? [[String: Any]] ?? []
            let usageFailure = diagnostics.first {
                $0["api"] as? String == "zeldaHttp.apikeyMgr./tokenplan/personal/api/v2/usage"
            }
            switch usageFailure?["errorCode"] as? String {
            case nil, "MissingUsageWindow": throw QwenCloudError.noUsage
            case "AUTH_REQUIRED": throw QwenCloudError.notLoggedIn
            case "NETWORK_ERROR": throw QwenCloudError.network
            case "PROTOCOL_ERROR": throw QwenCloudError.invalidResponse
            default: throw QwenCloudError.commandFailed
            }
        }
        let used: Double
        if let reported = try percent(credits["usedPct"]) {
            used = reported
        } else if let remaining = try percent(credits["remainingPct"]) {
            used = 100 - remaining
        } else {
            throw QwenCloudError.noUsage
        }
        let reset: Date?
        if let value = credits["resetTime"], !(value is NSNull) {
            guard let string = value as? String, let date = EgasuISO8601.date(from: string) else {
                throw QwenCloudError.invalidResponse
            }
            reset = date
        } else {
            reset = nil
        }
        return Self(
            plan: individual["name"] as? String,
            line: .progress(
                label: weekly != nil ? "Weekly" : "Monthly", used: used, limit: 100, format: .percent,
                resetsAt: reset, periodDurationMs: weekly != nil ? MetricPeriod.weekMs : nil
            )
        )
    }

    private static func percent(_ value: Any?) throws -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let number = ProviderParse.number(value), (0...100).contains(number) else {
            throw QwenCloudError.invalidResponse
        }
        return number
    }
}

enum QwenCloudError: String, LocalizedError, UserPresentableError, CategorizedError {
    case loginChanged = "QwenCloud sign-in changed while refreshing. Refresh again to use the current account."
    case cliMissing = "Install the QwenCloud CLI and refresh."
    case unsafeCredentialFile =
        "Move the credentials file to a new, private location outside the QwenCloud CLI configuration folder. If you need to sign in again, use Keychain or encrypted file storage."
    case plaintextMode = "Unset QWENCLOUD_KEYRING=plaintext and restart egasu."
    case notLoggedIn = "Sign in with `qwencloud auth login` and refresh."
    case noSubscription = "No active QwenCloud personal Token Plan."
    case noUsage = "QwenCloud did not report credit usage for this period."
    case invalidResponse = "Usage response invalid. Try again later."
    case commandFailed = "The QwenCloud CLI could not retrieve the subscription. Check the CLI and refresh."
    case network = "Usage request failed. Check your connection."

    var errorDescription: String? { rawValue }
    var presentationMessage: LocalizedMessage { LocalizedMessage(rawValue) }

    var errorCategory: ErrorCategory {
        switch self {
        case .cliMissing, .commandFailed: .subprocess
        case .loginChanged: .other
        case .plaintextMode: .credentialAccess
        case .notLoggedIn, .unsafeCredentialFile: .notLoggedIn
        case .noSubscription, .noUsage: .notAvailable
        case .invalidResponse: .decoding
        case .network: .network
        }
    }
}
