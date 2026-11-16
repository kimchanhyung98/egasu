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
        var result = UsageHistoryLoadResult(documents: [])
        // 같은 기기·시각이면 먼저 읽은 새 경로의 기록 유지.
        for directory in [directories.current, directories.legacy] {
            guard FileManager.default.fileExists(atPath: directory.path) else { continue }
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(
                    at: directory,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles]
                ).filter { $0.pathExtension == "json" }
            } catch {
                result.appendFailure(error, fileName: directory.lastPathComponent)
                let issue = error as NSError
                AppLog.warn(
                    .config,
                    "iCloud history couldn't read \(directory.lastPathComponent): \(issue.domain) (\(issue.code))")
                continue
            }

            for url in urls {
                do {
                    let data = try coordinatedRead(url)
                    let document = try decoder.decode(UsageHistoryDocument.self, from: data)
                    try document.validate()
                    result.documents.append(document)
                } catch {
                    result.appendFailure(error, fileName: url.lastPathComponent)
                    AppLog.warn(.config, "iCloud history ignored \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
        }
        result.documents = UsageHistoryDocument.newestByDevice(result.documents)
        return result
    }

    func write(_ document: UsageHistoryDocument) async throws {
        try document.validate()
        let directories = try historyDirectories()
        let data = try encoder.encode(document)
        try FileManager.default.createDirectory(at: directories.current, withIntermediateDirectories: true)
        let url = directories.current.appendingPathComponent(document.deviceID).appendingPathExtension("json")
        try coordinatedWrite(data, to: url)
        // 새 파일 저장 실패 시 원본 유지. 옛 파일 정리 실패는 다음 쓰기에서 재시도.
        try coordinatedDelete(
            directories.legacy.appendingPathComponent(document.deviceID).appendingPathExtension("json")
        )
    }

    func delete(deviceID: String) async throws {
        guard UUID(uuidString: deviceID) != nil else {
            throw ICloudUsageSyncError.invalidDeviceID
        }
        let directories = try historyDirectories()
        for directory in [directories.current, directories.legacy] {
            try coordinatedDelete(directory.appendingPathComponent(deviceID).appendingPathExtension("json"))
        }
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

    private func coordinatedWrite(_ data: Data, to url: URL) throws {
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordinationError) { coordinatedURL in
            do { try data.write(to: coordinatedURL, options: .atomic) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }

    private func coordinatedDelete(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var coordinationError: NSError?
        var operationError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forDeleting, error: &coordinationError) { coordinatedURL in
            do { try FileManager.default.removeItem(at: coordinatedURL) }
            catch { operationError = error }
        }
        if let coordinationError { throw coordinationError }
        if let operationError { throw operationError }
    }
}
