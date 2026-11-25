import Foundation

@MainActor
final class OpenAICostsProvider: APIKeyManaging {
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
    private nonisolated static let connectionKey = "openaiAPIBillingConnection"

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

    var projectIDs: [String] {
        defaults.dictionary(forKey: Self.connectionKey)?["projects"] as? [String] ?? []
    }

    /// 키나 조회 범위가 바뀌면 새 식별자를 발급. 비밀 키를 캐시 식별자로 사용하지 않음.
    nonisolated static func connectionID(in defaults: UserDefaults) -> String {
        defaults.dictionary(forKey: connectionKey)?["id"] as? String ?? "initial-organization"
    }

    var connectionID: String { Self.connectionID(in: defaults) }

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
        let revision = connectionID
        let projects = projectIDs
        let requestedAt = now()
        // UTC 오늘을 포함한 30일. 같은 기간을 모든 페이지에 적용.
        let end = Int(requestedAt.timeIntervalSince1970)
        let start = (end / 86_400 - 29) * 86_400
        do {
            let manual = ProviderRefreshContext.isManual
            guard let key = try await loadOffMainActor({ [keys] in try keys.load(allowInteraction: manual) }) else {
                throw OpenAICostsError.missingKey
            }
            let totals = try await client.totals(key: key, projects: projects, start: start, end: end) {
                revision == self.connectionID
            }
            try Task.checkCancellation()
            guard revision == connectionID else { throw CancellationError() }
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
            snapshot.producedByIdentityKey = revision
            return snapshot
        } catch {
            if revision != connectionID { return .error(provider: provider, error: OpenAICostsError.connectionChanged) }
            return .error(provider: provider, error: error)
        }
    }
}
