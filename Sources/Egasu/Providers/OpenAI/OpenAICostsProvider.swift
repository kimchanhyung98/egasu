import CryptoKit
import Foundation

@MainActor
final class OpenAICostsProvider: APIKeyManaging, CredentialBoundSnapshotProvider {
    let provider = Provider(
        id: "openai-api", displayName: "OpenAI API", icon: .providerMark("codex"),
        links: [
            ProviderLink(label: "Usage", url: "https://platform.openai.com/usage"),
            ProviderLink(label: "API Keys", url: "https://platform.openai.com/settings/organization/admin-keys")
        ])

    private let keys: OpenAIAdminKeyStore
    private let client: OpenAICostsClient
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private static let connectionKey = "openaiAPIBillingConnection"

    init(
        defaults: UserDefaults = .standard,
        keys: OpenAIAdminKeyStore = .init(),
        client: OpenAICostsClient = .init(),
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.keys = keys
        self.client = client
        self.now = now
    }

    private struct Scope {
        let revision: String
        let projects: [String]

        func identity(for key: String) throws -> String {
            let material = try JSONEncoder().encode([revision, key] + projects)
            return Data(SHA256.hash(data: material)).base64EncodedString()
        }
    }

    private var scope: Scope {
        let connection = defaults.dictionary(forKey: Self.connectionKey)
        return Scope(
            revision: connection?["id"] as? String ?? "initial-organization",
            projects: connection?["projects"] as? [String] ?? [])
    }

    var projectIDs: [String] { scope.projects }

    func currentIdentityKey(allowKeychainInteraction: Bool) async -> String? {
        let manual = allowKeychainInteraction && ProviderRefreshContext.isManual
        guard let key = await loadOffMainActor({ [keys] in try? keys.load(allowInteraction: manual) }) else {
            return nil
        }
        return try? scope.identity(for: key)
    }

    static func parseProjects(_ input: String) throws -> [String] {
        let projects = input.split { $0 == "," || $0.isWhitespace }.map(String.init)
        if projects.isEmpty && !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpenAICostsError.invalidProjects
        }
        return Set(projects).sorted()
    }

    func saveConnection(key: String, projects: String) throws {
        let ids = try Self.parseProjects(projects)
        if !key.isEmpty {
            try keys.save(key)
        } else {
            guard try keys.load(allowInteraction: true) != nil else { throw OpenAICostsError.missingKey }
            if ids == projectIDs { return }
        }
        replaceConnection(projects: ids)
    }

    private func replaceConnection(projects: [String]) {
        defaults.set(["id": UUID().uuidString, "projects": projects], forKey: Self.connectionKey)
    }

    var widgetDescriptors: [WidgetDescriptor] {
        [
            .badge(id: "openai-api.costs", provider: provider, title: "Last 30 Days"),
            .badge(id: "openai-api.scope", provider: provider, title: "Billing Scope"),
            .badge(id: "openai-api.balance", provider: provider, title: "Credit Balance"),
            .badge(id: "openai-api.updated", provider: provider, title: "Last Updated")
        ]
    }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [keys] in (try? keys.load()) != nil }
    }

    var apiKeyStatus: APIKeyStatus {
        do { return try keys.load() == nil ? .notSet : .saved } catch { return .unreadable }
    }

    func currentAPIKey() -> String? { try? keys.load() }

    func saveAPIKey(_ key: String) throws {
        try keys.save(key)
        replaceConnection(projects: projectIDs)
    }

    func deleteAPIKey() throws {
        try keys.remove()
        replaceConnection(projects: [])
    }

    func refresh() async -> ProviderSnapshot {
        let requestedScope = scope
        let projects = requestedScope.projects
        var requestedIdentity: String?
        let requestedAt = now()
        // UTC 오늘을 포함한 30일. 같은 기간을 모든 페이지에 적용.
        let end = Int(requestedAt.timeIntervalSince1970)
        let start = (end / 86_400 - 29) * 86_400
        let manual = ProviderRefreshContext.isManual
        do {
            guard let key = try await loadOffMainActor({ [keys] in try keys.load(allowInteraction: manual) }) else {
                throw OpenAICostsError.missingKey
            }
            let identity = try requestedScope.identity(for: key)
            requestedIdentity = identity
            let totals = try await client.totals(key: key, projects: projects, start: start, end: end) {
                await self.currentIdentityKey(allowKeychainInteraction: manual) == identity
            }
            try Task.checkCancellation()
            guard await currentIdentityKey(allowKeychainInteraction: manual) == identity else {
                throw OpenAICostsError.connectionChanged
            }
            let refreshedAt = now()
            let costs = totals.sorted { $0.key < $1.key }.map { currency, value in
                "\(currency) \(NSDecimalNumber(decimal: value).stringValue)"
            }
            let day = Date.ISO8601FormatStyle().year().month().day()
            let first = Date(timeIntervalSince1970: TimeInterval(start)).formatted(day)
            let range = "\(first) – \(requestedAt.formatted(day)) UTC"
            let timestamp = Date.ISO8601FormatStyle(dateTimeSeparator: .space).year().month().day()
                .time(includingFractionalSeconds: false)
            var snapshot = ProviderSnapshot.make(
                provider: provider, plan: nil,
                lines: [
                    .badge(
                        label: "Last 30 Days",
                        text: costs.isEmpty ? "No costs reported" : costs.joined(separator: " · "), subtitle: range),
                    .badge(
                        label: "Billing Scope",
                        text: projects.isEmpty ? "Organization" : projects.joined(separator: ", ")),
                    .badge(label: "Credit Balance", text: "Unavailable"),
                    .badge(label: "Last Updated", text: refreshedAt.formatted(timestamp) + " UTC")
                ], refreshedAt: refreshedAt)
            snapshot.producedByIdentityKey = identity
            return snapshot
        } catch {
            guard let requestedIdentity else { return .error(provider: provider, error: error) }
            let current = await currentIdentityKey(allowKeychainInteraction: manual)
            let changed = current.map { $0 != requestedIdentity } ?? false
            var failure = ProviderSnapshot.error(
                provider: provider, error: changed ? OpenAICostsError.connectionChanged : error)
            failure.producedByIdentityKey = current
            return failure
        }
    }
}
