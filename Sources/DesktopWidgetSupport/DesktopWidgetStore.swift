import Foundation

public struct DesktopWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let schemaVersion: Int
    public let generatedAt: Date
    public let content: DesktopWidgetContent

    public init(content: DesktopWidgetContent, generatedAt: Date) {
        self.schemaVersion = Self.currentVersion
        self.generatedAt = generatedAt
        self.content = content
    }
}

public enum DesktopWidgetRead: Equatable, Sendable {
    case snapshot(DesktopWidgetSnapshot)
    case missing
    case unsupportedVersion(Int)
    case unreadable
}

public enum DesktopWidgetStoreError: Error {
    case missingAppGroup, invalidContent
}

public struct DesktopWidgetStore: Sendable {
    public static let kind = "EgasuDesktopUsage"
    private let fileURL: URL?

    public init(bundle: Bundle = .main) {
        let group = bundle.object(forInfoDictionaryKey: "EgasuWidgetAppGroup") as? String
        self.fileURL = group.flatMap {
            FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: $0)
        }?.appendingPathComponent("desktop-widget.json", isDirectory: false)
    }

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    private struct Version: Decodable {
        let schemaVersion: Int
    }

    public func read() -> DesktopWidgetRead {
        guard let fileURL else { return .unreadable }
        do {
            let data = try Data(contentsOf: fileURL)
            let decoder = JSONDecoder()
            let version = try decoder.decode(Version.self, from: data).schemaVersion
            guard version == DesktopWidgetSnapshot.currentVersion else { return .unsupportedVersion(version) }
            let snapshot = try decoder.decode(DesktopWidgetSnapshot.self, from: data)
            guard snapshot.content.hasUniqueIDs else { return .unreadable }
            return .snapshot(snapshot)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return .missing
        } catch {
            return .unreadable
        }
    }

    /// 같은 내용이면 기존 생성 시각 유지. 쓰기와 재조회 요청은 호스트에서 직렬 실행.
    @discardableResult
    public func write(_ content: DesktopWidgetContent, at date: Date = Date()) throws -> Bool {
        guard let fileURL else { throw DesktopWidgetStoreError.missingAppGroup }
        guard content.hasUniqueIDs else { throw DesktopWidgetStoreError.invalidContent }
        if case .snapshot(let previous) = read(), previous.content == content { return false }
        let data = try JSONEncoder().encode(DesktopWidgetSnapshot(content: content, generatedAt: date))
        try data.write(to: fileURL, options: .atomic)
        return true
    }
}

extension DesktopWidgetContent {
    fileprivate var hasUniqueIDs: Bool {
        Set(accounts.map(\.id)).count == accounts.count
            && accounts.allSatisfy { account in
                !account.id.isEmpty && Set(account.metrics.map(\.id)).count == account.metrics.count
                    && account.metrics.allSatisfy { !$0.id.isEmpty }
            }
    }
}
