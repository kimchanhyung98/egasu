import Foundation

struct OpenAIAdminKeyStore: Sendable {
    var keychain: any KeychainAccessing = SecurityKeychainAccessor()
    var namespace: StorageNamespace = .current

    private var service: String { "\(namespace.name) OpenAI Organization Admin API Key" }

    func load(allowInteraction: Bool = false) throws -> String? {
        guard
            let value = try keychain.readAppOwnedPassword(
                service: service, forCurrentUser: true, allowInteraction: allowInteraction)
        else { return nil }
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw KeychainError.invalidData }
        return key
    }

    func save(_ value: String) throws {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAICostsError.missingKey }
        try keychain.writeGenericPasswordForCurrentUser(service: service, value: key)
    }

    func remove() throws {
        try keychain.deleteGenericPasswordForCurrentUser(service: service)
    }
}
