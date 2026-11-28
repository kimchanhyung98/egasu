import CryptoKit
import Foundation

@MainActor
final class DeepSeekProvider: APIKeyManaging, CredentialBoundSnapshotProvider {
    let provider = Provider(
        id: "deepseek", displayName: "DeepSeek", icon: .providerMark("deepseek"),
        links: [
            ProviderLink(label: "Dashboard", url: "https://platform.deepseek.com/usage"),
            ProviderLink(label: "API Keys", url: "https://platform.deepseek.com/api_keys")
        ]
    )

    let authStore: UserAPIKeyStore
    let usageClient: DeepSeekUsageClient

    init(
        files: any TextFileAccessing = LocalTextFileAccessor(),
        environment: any EnvironmentReading = ProcessEnvironmentReader(),
        usageClient: DeepSeekUsageClient = DeepSeekUsageClient()
    ) {
        authStore = UserAPIKeyStore(
            providerID: "deepseek", configPaths: [StorageNamespace.current.configPath("deepseek.json")],
            environmentNames: ["DEEPSEEK_API_KEY"], files: files, environment: environment,
            makeError: { DeepSeekError.keyStorage($0) }
        )
        self.usageClient = usageClient
    }

    var widgetDescriptors: [WidgetDescriptor] {
        DeepSeekCurrency.allCases.map { currency in
            var descriptor = WidgetDescriptor.values(
                id: "deepseek.\(currency.resourceKey)", provider: provider, title: currency.balanceLabel,
                selection: .kind(currency.valueKind)
            ).exportingLimit(
                currency.resourceKey, kind: .balance, unit: currency.rawValue.lowercased(),
                source: .value(kind: currency.valueKind, label: currency.rawValue)
            )
            descriptor.detailLabels = [currency.toppedUpLabel, currency.grantedLabel]
            return descriptor
        } + [.badge(id: "deepseek.api", provider: provider, title: "API Access")]
    }

    var apiKeyStatus: APIKeyStatus { authStore.keyStatus() }
    func currentAPIKey() -> String? { try? authStore.loadKey() }
    func saveAPIKey(_ key: String) throws { try authStore.saveKey(key) }
    func deleteAPIKey() throws { try authStore.deleteKey() }

    func hasLocalCredentials() async -> Bool {
        await loadOffMainActor { [authStore] in (try? authStore.loadKey()) != nil }
    }

    nonisolated private static func identity(for key: String) -> String {
        Data(SHA256.hash(data: Data(("deepseek\u{0}" + key).utf8))).base64EncodedString()
    }

    func currentIdentityKey(allowKeychainInteraction _: Bool) async -> String? {
        await loadOffMainActor { [authStore] in (try? authStore.loadKey()).map(Self.identity) }
    }

    func refresh() async -> ProviderSnapshot {
        var requestedIdentity: String?
        do {
            guard let key = try await loadOffMainActor({ [authStore] in try authStore.loadKey() }) else {
                throw DeepSeekError.keyStorage(.missingKey)
            }
            requestedIdentity = Self.identity(for: key)
            let balance = try await usageClient.balance(apiKey: key)
            try Task.checkCancellation()
            guard await currentIdentityKey(allowKeychainInteraction: false) == requestedIdentity else {
                throw DeepSeekError.credentialsChanged
            }
            var snapshot = try balance.snapshot(for: provider)
            snapshot.producedByIdentityKey = requestedIdentity
            return snapshot
        } catch {
            guard let requestedIdentity else { return .error(provider: provider, error: error) }
            let current = await currentIdentityKey(allowKeychainInteraction: false)
            let changed = current != requestedIdentity
            var failure = ProviderSnapshot.error(
                provider: provider, error: changed ? DeepSeekError.credentialsChanged : error)
            failure.producedByIdentityKey = current
            return failure
        }
    }
}
