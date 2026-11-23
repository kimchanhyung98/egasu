import Foundation
import Observation

struct UsageHistoryLoadResult: Sendable {
    var documents: [UsageHistoryDocument]
    private(set) var invalidFileMessages: [String] = []
    private(set) var failureCategories: Set<ErrorCategory> = []

    private var unreadableFileNames: Set<String> = []
    private var directoryReadFailed = false

    func canReplaceDocument(for deviceID: String) -> Bool {
        !directoryReadFailed && !unreadableFileNames.contains(deviceID.lowercased() + ".json")
    }

    init(documents: [UsageHistoryDocument]) { self.documents = documents }

    mutating func appendFailure(_ error: Error, fileName: String, isDirectory: Bool = false) {
        if isDirectory {
            directoryReadFailed = true
        } else {
            unreadableFileNames.insert(fileName.lowercased())
        }
        invalidFileMessages.append("\(fileName): \(error.localizedDescription)")
        failureCategories.insert(ErrorCategory.classify(error))
    }
}

struct ICloudHistoryChangedDuringWrite: UserPresentableError {
    var presentationMessage: LocalizedMessage {
        .init("This Mac’s synced history changed again. egasu will retry on the next update.")
    }
}

protocol UsageHistoryFileStoring: Sendable {
    func loadDocuments() async throws -> UsageHistoryLoadResult
    func write(_ document: UsageHistoryDocument, replacing previous: UsageHistoryDocument?) async throws
    func delete(deviceID: String) async throws
}

protocol ICloudDeviceIDStoring: Sendable {
    func readDeviceID() throws -> String?
    func writeDeviceID(_ deviceID: String) throws
}

struct KeychainICloudDeviceIDStore: ICloudDeviceIDStoring {
    private let service: String
    private let keychain: any KeychainAccessing

    init(
        keychain: any KeychainAccessing = SecurityKeychainAccessor(),
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.kimchanhyung98.openusage"
    ) {
        self.keychain = keychain
        self.service = "\(bundleIdentifier).icloud-sync-device-id.v1"
    }

    func readDeviceID() throws -> String? {
        try keychain.readGenericPasswordForCurrentUser(service: service)
    }

    func writeDeviceID(_ deviceID: String) throws {
        try keychain.writeGenericPasswordForCurrentUser(service: service, value: deviceID)
    }
}

enum ICloudUsageSyncError: Error, LocalizedError {
    case unavailable
    case invalidDeviceID

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "iCloud Drive isn’t available. Check that this Mac is signed into iCloud and iCloud Drive is on."
        case .invalidDeviceID:
            "The saved iCloud sync device identifier is invalid."
        }
    }
}

@MainActor
@Observable
final class ICloudUsageSyncStore {
    private static let enabledKey = "openusage.icloudSync.enabled.v1"
    private static let deviceIDKey = "openusage.icloudSync.deviceID.v1"
    private static let pendingDeletionDeviceIDKey = "openusage.icloudSync.pendingDeletionDeviceID.v1"

    private let defaults: UserDefaults
    private let fileStore: any UsageHistoryFileStoring
    private let identityError: String?
    private let dataStore: WidgetDataStore
    private let writeDebounce: Duration
    private let observesMetadataChanges: Bool
    private let makeMetadataQuery: () -> NSMetadataQuery
    private let workQueue: BackgroundWorkQueue
    private var writeTask: Task<Void, Never>?
    private var metadataQuery: NSMetadataQuery?
    private var notificationTokens: [NSObjectProtocol] = []
    private var syncActivityCount = 0
    private var enablementGeneration = 0
    private var canReplaceOwnDocument = false

    let deviceID: String
    let deviceName: String
    var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            canReplaceOwnDocument = false
            enablementGeneration &+= 1
            let generation = enablementGeneration
            let expectedEnabled = enabled
            if enabled {
                defaults.set(true, forKey: Self.enabledKey)
                clearCurrentPendingDeletionIfReenabled()
            } else {
                persistCurrentDeletionRequestForDisable()
                defaults.set(false, forKey: Self.enabledKey)
            }
            Task { await applyEnabledChange(expectedEnabled: expectedEnabled, generation: generation) }
        }
    }
    private(set) var isSyncing = false
    private var operationError: String?
    private(set) var deletionError: String?
    var serviceError: String? { operationError ?? deletionError ?? identityError }
    private(set) var invalidFileMessages: [String] = []
    private(set) var documents: [UsageHistoryDocument] = []

    init(
        dataStore: WidgetDataStore,
        defaults: UserDefaults = .standard,
        fileStore: any UsageHistoryFileStoring = ICloudUsageHistoryFileStore(),
        deviceIDStore: any ICloudDeviceIDStoring = KeychainICloudDeviceIDStore(),
        writeDebounce: Duration = .seconds(3),
        observesMetadataChanges: Bool = true,
        makeMetadataQuery: @escaping () -> NSMetadataQuery = { NSMetadataQuery() },
        workQueue: BackgroundWorkQueue = BackgroundWorkQueue()
    ) {
        self.dataStore = dataStore
        self.defaults = defaults
        self.fileStore = fileStore
        self.writeDebounce = writeDebounce
        self.observesMetadataChanges = observesMetadataChanges
        self.makeMetadataQuery = makeMetadataQuery
        self.workQueue = workQueue
        let identity = Self.resolveDeviceID(defaults: defaults, store: deviceIDStore)
        self.deviceID = identity.id
        self.identityError = identity.error
        self.deviceName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        self.enabled = defaults.bool(forKey: Self.enabledKey)
        dataStore.onLocalHistoryChanged = { [weak self] in self?.scheduleWrite() }
        if enabled {
            clearCurrentPendingDeletionIfReenabled()
            let generation = enablementGeneration
            Task { await applyEnabledChange(expectedEnabled: true, generation: generation) }
        } else if defaults.object(forKey: Self.pendingDeletionDeviceIDKey) != nil {
            let generation = enablementGeneration
            Task { await retryPendingDeletion(expectedEnabled: false, generation: generation) }
        }
    }

    private var pendingDeletionDeviceID: String? {
        defaults.string(forKey: Self.pendingDeletionDeviceIDKey)
    }

    private func clearPendingDeletion() {
        defaults.removeObject(forKey: Self.pendingDeletionDeviceIDKey)
        deletionError = nil
    }

    private func clearCurrentPendingDeletionIfReenabled() {
        guard Self.normalizedDeviceID(pendingDeletionDeviceID) == deviceID else { return }
        clearPendingDeletion()
    }

    private func persistCurrentDeletionRequestForDisable() {
        if let pendingDeviceID = Self.normalizedDeviceID(pendingDeletionDeviceID),
           pendingDeviceID != deviceID {
            return
        }
        defaults.set(deviceID, forKey: Self.pendingDeletionDeviceIDKey)
    }

    private func retryPendingDeletion(expectedEnabled: Bool, generation: Int) async {
        guard isCurrent(expectedEnabled: expectedEnabled, generation: generation) else { return }
        guard let persistedDeviceID = pendingDeletionDeviceID else {
            if defaults.object(forKey: Self.pendingDeletionDeviceIDKey) != nil {
                reportInvalidDeletionRequest()
            }
            return
        }
        guard let pendingDeviceID = Self.normalizedDeviceID(persistedDeviceID) else {
            reportInvalidDeletionRequest()
            return
        }
        await withSyncActivity {
            do {
                let deleted = try await workQueue.run("icloud:delete") {
                    guard isCurrent(expectedEnabled: expectedEnabled, generation: generation) else { return false }
                    try await fileStore.delete(deviceID: pendingDeviceID)
                    return true
                }
                guard deleted == true else { return }
                AppDiagnostics.record(.iCloudDelete, result: .success)
                guard isCurrent(expectedEnabled: expectedEnabled, generation: generation),
                      pendingDeletionDeviceID == persistedDeviceID else {
                    if enabled {
                        await writeNow(generation: enablementGeneration)
                    }
                    return
                }
                if !expectedEnabled, pendingDeviceID != deviceID {
                    defaults.set(deviceID, forKey: Self.pendingDeletionDeviceIDKey)
                    deletionError = nil
                    await retryPendingDeletion(expectedEnabled: false, generation: generation)
                } else {
                    clearPendingDeletion()
                }
            } catch {
                guard isCurrent(expectedEnabled: expectedEnabled, generation: generation),
                      pendingDeletionDeviceID == persistedDeviceID else { return }
                reportDeletion(error)
            }
        }
    }

    var displayedDocuments: [UsageHistoryDocument] {
        documents.sorted { lhs, rhs in
            if lhs.deviceID == deviceID { return true }
            if rhs.deviceID == deviceID { return false }
            return lhs.updatedAt > rhs.updatedAt
        }
    }

    func scheduleWrite() {
        guard enabled else { return }
        writeTask?.cancel()
        let generation = enablementGeneration
        writeTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: writeDebounce)
            guard !Task.isCancelled else { return }
            if !canReplaceOwnDocument { await reload(generation: generation) }
            await writeNow(generation: generation)
        }
    }

    private func applyEnabledChange(expectedEnabled: Bool, generation: Int) async {
        guard isCurrent(expectedEnabled: expectedEnabled, generation: generation) else { return }
        if expectedEnabled {
            startObserving()
            await retryPendingDeletion(expectedEnabled: true, generation: generation)
            guard isCurrent(expectedEnabled: true, generation: generation) else { return }
            await reload(generation: generation)
            await writeNow(generation: generation)
        } else {
            writeTask?.cancel()
            stopObserving()
            dataStore.clearPeerHistoryDocuments()
            documents = []
            invalidFileMessages = []
            operationError = nil
            await retryPendingDeletion(expectedEnabled: false, generation: generation)
        }
    }

    private func writeNow(generation: Int, retryOnChange: Bool = true) async {
        guard isCurrent(expectedEnabled: true, generation: generation) else { return }
        await withSyncActivity {
            guard isCurrent(expectedEnabled: true, generation: generation) else { return }
            do {
                let written = try await workQueue.run("icloud:write") {
                    guard isCurrent(expectedEnabled: true, generation: generation), canReplaceOwnDocument else {
                        return false
                    }
                    let previous = documents.first { $0.deviceID == deviceID }
                    let document = dataStore.localHistoryDocument(
                        deviceID: deviceID, deviceName: deviceName, preserving: previous)
                    try await fileStore.write(document, replacing: previous)
                    return true
                }
                guard written == true else { return }
                AppDiagnostics.record(.iCloudWrite, result: .success)
            } catch let error as ICloudHistoryChangedDuringWrite {
                guard isCurrent(expectedEnabled: true, generation: generation) else { return }
                await reload(generation: generation)
                guard isCurrent(expectedEnabled: true, generation: generation),
                    canReplaceOwnDocument, !Task.isCancelled
                else { return }
                if retryOnChange {
                    await writeNow(generation: generation, retryOnChange: false)
                } else {
                    report(error, operation: .iCloudWrite)
                }
                return
            } catch {
                if isCurrent(expectedEnabled: true, generation: generation) {
                    report(error, operation: .iCloudWrite)
                } else if !enabled {
                    persistCurrentDeletionRequestForDisable()
                    await retryPendingDeletion(expectedEnabled: false, generation: enablementGeneration)
                }
                return
            }
            guard isCurrent(expectedEnabled: true, generation: generation) else {
                if !enabled {
                    persistCurrentDeletionRequestForDisable()
                    await retryPendingDeletion(expectedEnabled: false, generation: enablementGeneration)
                }
                return
            }
            operationError = nil
            await reload(generation: generation)
        }
    }

    private func reload(generation: Int) async {
        guard isCurrent(expectedEnabled: true, generation: generation) else { return }
        let pendingAtStart = Self.normalizedDeviceID(pendingDeletionDeviceID)
        await withSyncActivity {
            guard let ticket = await workQueue.acquire("icloud:read") else { return }
            defer { workQueue.finish(ticket) }
            guard !Task.isCancelled, isCurrent(expectedEnabled: true, generation: generation) else { return }
            do {
                let result = try await fileStore.loadDocuments()
                guard isCurrent(expectedEnabled: true, generation: generation) else { return }
                let excludedDeviceIDs = Set([
                    pendingAtStart,
                    Self.normalizedDeviceID(pendingDeletionDeviceID)
                ].compactMap { $0 })
                let visibleDocuments = result.documents.filter { document in
                    !excludedDeviceIDs.contains(document.deviceID.lowercased())
                }
                canReplaceOwnDocument = result.canReplaceDocument(for: deviceID)
                documents = UsageHistoryDocument.newestByDevice(visibleDocuments)
                invalidFileMessages = result.invalidFileMessages
                if result.invalidFileMessages.isEmpty {
                    AppDiagnostics.record(.iCloudRead, result: .success)
                } else {
                    for category in result.failureCategories.sorted(by: { $0.rawValue < $1.rawValue }) {
                        AppDiagnostics.record(.iCloudRead, result: .degraded, category: category)
                    }
                }
                dataStore.setPeerHistoryDocuments(visibleDocuments, ownDeviceID: deviceID)
                operationError = result.invalidFileMessages.isEmpty
                    ? nil
                    : L10n.errors("Some synced usage data couldn’t be read. Check the log for details.")
            } catch {
                if isCurrent(expectedEnabled: true, generation: generation) {
                    canReplaceOwnDocument = false
                    report(error, operation: .iCloudRead)
                }
            }
        }
    }

    private func withSyncActivity(_ operation: () async -> Void) async {
        syncActivityCount += 1
        isSyncing = true
        await operation()
        syncActivityCount -= 1
        isSyncing = syncActivityCount > 0
    }

    private func report(_ error: Error, operation: DiagnosticOperation) {
        operationError = UserFacingErrors.message(error)
        AppDiagnostics.failure(operation, error: error)
    }

    private func reportDeletion(_ error: Error) {
        deletionError = L10n.errors("egasu couldn’t remove this Mac’s synced usage history from iCloud. It will try again automatically.")
        AppDiagnostics.failure(.iCloudDelete, error: error)
    }

    private func reportInvalidDeletionRequest() {
        deletionError = L10n.errors("egasu couldn’t read the saved iCloud history deletion request.")
        AppDiagnostics.record(
            .iCloudDelete, result: .failure, category: .decoding,
            localContext: "iCloud history deletion request has an invalid device identifier"
        )
    }

    private func isCurrent(expectedEnabled: Bool, generation: Int) -> Bool {
        enabled == expectedEnabled && enablementGeneration == generation
    }

    private static func resolveDeviceID(
        defaults: UserDefaults,
        store: any ICloudDeviceIDStoring
    ) -> (id: String, error: String?) {
        let saved = normalizedDeviceID(defaults.string(forKey: deviceIDKey))
        do {
            if let stored = normalizedDeviceID(try store.readDeviceID()) {
                defaults.set(stored, forKey: deviceIDKey)
                return (stored, nil)
            }

            let id = saved ?? UUID().uuidString.lowercased()
            try store.writeDeviceID(id)
            defaults.set(id, forKey: deviceIDKey)
            return (id, nil)
        } catch {
            let id = saved ?? UUID().uuidString.lowercased()
            defaults.set(id, forKey: deviceIDKey)
            let message = L10n.errors("egasu couldn’t save this Mac’s sync identity in Keychain. Sync may create a duplicate device if app preferences are reset.")
            AppDiagnostics.failure(.iCloudIdentity, error: error)
            return (id, message)
        }
    }

    private static func normalizedDeviceID(_ value: String?) -> String? {
        guard let value, UUID(uuidString: value) != nil else { return nil }
        return value.lowercased()
    }

    private func startObserving() {
        guard observesMetadataChanges else { return }
        guard metadataQuery == nil else { return }
        let query = makeMetadataQuery()
        query.searchScopes = [NSMetadataQueryUbiquitousDataScope]
        query.predicate = NSPredicate(format: "%K LIKE '*.json'", NSMetadataItemFSNameKey)
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.metadataQuery?.enableUpdates()
                    await self.reload(generation: self.enablementGeneration)
                }
            },
            center.addObserver(forName: .NSMetadataQueryDidUpdate, object: query, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    await self.reload(generation: self.enablementGeneration)
                }
            }
        ]
        metadataQuery = query
        query.start()
    }

    private func stopObserving() {
        metadataQuery?.stop()
        metadataQuery = nil
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
    }
}
