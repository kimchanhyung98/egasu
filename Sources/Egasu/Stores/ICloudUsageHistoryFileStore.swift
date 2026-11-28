import Foundation

/// 비공개 iCloud 기록 저장소 — 새 경로에 쓴 기기의 옛 파일만 정리, 다른 기기의 기록은 두 경로에서 읽음.
actor ICloudUsageHistoryFileStore: UsageHistoryFileStoring {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let containerURL: @Sendable () -> URL?

    init(
        containerURL: @escaping @Sendable () -> URL? = {
            FileManager.default.url(forUbiquityContainerIdentifier: nil)
        }
    ) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        self.containerURL = containerURL
    }

    func loadDocuments() async throws -> UsageHistoryLoadResult {
        let directories = try historyDirectories()
        return readDocuments(in: [directories.current, directories.legacy], read: coordinatedRead)
    }

    private func readDocuments(in directories: [URL], read: (URL) throws -> Data) -> UsageHistoryLoadResult {
        var result = UsageHistoryLoadResult(documents: [])
        // 같은 기기·시각이면 먼저 읽은 새 경로의 기록 유지.
        for directory in directories {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "json" }
            } catch {
                if isMissingFile(error) { continue }
                result.appendFailure(error, fileName: directory.lastPathComponent, isDirectory: true)
                let issue = error as NSError
                AppLog.warn(
                    .config,
                    "iCloud history couldn't read \(directory.lastPathComponent): \(issue.domain) (\(issue.code))")
                continue
            }

            for url in urls {
                do {
                    let data = try read(url)
                    let document = try decoder.decode(UsageHistoryDocument.self, from: data)
                    try document.validate()
                    result.documents.append(document)
                    let name = url.deletingPathExtension().lastPathComponent
                    if UUID(uuidString: name) != nil, name.lowercased() != document.deviceID.lowercased() {
                        throw UsageHistoryDocumentError.invalidDevice
                    }
                } catch {
                    result.appendFailure(error, fileName: url.lastPathComponent)
                    AppLog.warn(.config, "iCloud history ignored \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        result.documents = UsageHistoryDocument.newestByDevice(result.documents)
        return result
    }

    func write(_ document: UsageHistoryDocument, replacing previous: UsageHistoryDocument?) async throws {
        try document.validate()
        let directories = try historyDirectories()
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: directories.current, withIntermediateDirectories: true)
        let name = document.deviceID + ".json"
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        // 이동용 조정은 피어 파일에 삭제 승인을 요청하지 않고 하위 파일의 조정 쓰기를 대기.
        NSFileCoordinator().coordinate(
            writingItemAt: directories.current, options: .forMoving,
            writingItemAt: directories.legacy, options: .forMoving, error: &coordinationError
        ) { current, legacy in
            result = Result {
                let stored = readDocuments(in: [current, legacy]) { try Data(contentsOf: $0) }
                guard stored.canReplaceDocument(for: document.deviceID),
                    stored.documents.first(where: { $0.deviceID == document.deviceID }) == previous
                else { throw ICloudHistoryChangedDuringWrite() }
                try data.write(to: current.appendingPathComponent(name), options: .atomic)
                do { try FileManager.default.removeItem(at: legacy.appendingPathComponent(name)) }
                catch { if !isMissingFile(error) { throw error } }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    func delete(deviceID: String) async throws {
        guard let deviceID = UUID(uuidString: deviceID) else {
            throw ICloudUsageSyncError.invalidDeviceID
        }
        let directories = try historyDirectories()
        var coordinationError: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(
            writingItemAt: directories.current, options: .forMoving,
            writingItemAt: directories.legacy, options: .forMoving, error: &coordinationError
        ) { current, legacy in
            result = Result { try deleteDocuments(deviceID: deviceID, in: [current, legacy]) }
        }
        if let coordinationError { throw coordinationError }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }

    private func historyDirectories() throws -> (current: URL, legacy: URL) {
        guard let container = containerURL() else { throw ICloudUsageSyncError.unavailable }
        return (
            container.appendingPathComponent("egasu", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true),
            container.appendingPathComponent("OpenUsage", isDirectory: true)
                .appendingPathComponent("History", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
        )
    }

    private func coordinatedRead(_ url: URL) throws -> Data {
        var coordinationError: NSError?
        var result: Result<Data, Error>?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinatedURL in
            result = Result { try Data(contentsOf: coordinatedURL) }
        }
        if let coordinationError { throw coordinationError }
        return try result?.get() ?? { throw CocoaError(.fileReadUnknown) }()
    }

    /// 조정 구간에서 최신 기기 ID 확인 — 실패한 파일을 보존하고 나머지 정상 사본은 계속 삭제.
    private func deleteDocuments(deviceID: UUID, in directories: [URL]) throws {
        var firstError: Error?
        func recordFailure(_ error: Error, at url: URL) {
            guard !isMissingFile(error) else { return }
            if firstError == nil { firstError = error }
            AppLog.warn(
                .config, "iCloud history couldn't delete \(url.lastPathComponent): \(error.localizedDescription)")
        }
        for directory in directories {
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "json" }
            } catch {
                recordFailure(error, at: directory)
                continue
            }
            for url in urls {
                do {
                    let document = try decoder.decode(UsageHistoryDocument.self, from: Data(contentsOf: url))
                    try document.validate()
                    guard let storedDeviceID = UUID(uuidString: document.deviceID) else {
                        throw UsageHistoryDocumentError.invalidDevice
                    }
                    guard storedDeviceID == deviceID else { continue }
                    try FileManager.default.removeItem(at: url)
                } catch {
                    recordFailure(error, at: url)
                }
            }
        }
        if let firstError { throw firstError }
    }

    private func isMissingFile(_ error: Error) -> Bool {
        guard let error = error as? CocoaError else { return false }
        return error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
    }
}
