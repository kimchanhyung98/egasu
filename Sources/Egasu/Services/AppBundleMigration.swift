import Darwin
import Foundation

/// 구버전 Sparkle이 유지한 설치 경로를 첫 실행에서 변경. 설정·계정 데이터와 사용자 지정 앱 이름은 유지.
@MainActor
enum AppBundleMigration {
    struct RecoveryError: Error, CustomNSError {
        let underlyingError: Error
        let recoveryErrors: [Error]

        static var errorDomain: String { "Egasu.AppBundleMigration" }
        var errorCode: Int { 1 }
        var errorUserInfo: [String: Any] {
            [
                NSLocalizedDescriptionKey: "The app was renamed, but migration recovery is incomplete.",
                NSUnderlyingErrorKey: underlyingError,
                NSMultipleUnderlyingErrorsKey: recoveryErrors
            ]
        }
    }

    private struct CommandLink {
        let url: URL
        let oldTarget: String
        let newTarget: String
    }

    static func migrateIfNeeded(
        bundle: Bundle = .main,
        commandDirectory: URL = URL(fileURLWithPath: "/usr/local/bin"),
        fileManager: FileManager = .default,
        replacePrivilegedLink: (@MainActor (URL, String, String) throws -> Void)? = nil,
        scheduleRelaunch: @MainActor (URL) throws -> Void
    ) throws -> Bool {
        let source = bundle.bundleURL
        guard bundle.bundleIdentifier == "com.kimchanhyung98.openusage",
              bundle.object(forInfoDictionaryKey: "CFBundleName") as? String == "egasu",
              bundle.object(forInfoDictionaryKey: "SUFeedURL") != nil,
              ["OpenUsage.app", "egasu.app"].contains(source.lastPathComponent) else { return false }
        guard try source.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let privilegedReplacement = replacePrivilegedLink ?? CommandLineToolInstaller.replacePrivilegedLink
        if source.lastPathComponent == "egasu.app" {
            let legacy = source.deletingLastPathComponent().appendingPathComponent("OpenUsage.app")
            do {
                // 별도 설치나 심볼릭 링크가 남아 있으면 해당 경로의 명령 소유권 유지.
                _ = try fileManager.attributesOfItem(atPath: legacy.path)
                return false
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            } catch {
                throw RecoveryError(underlyingError: error, recoveryErrors: [])
            }
            do {
                try repairOwnedCommandLinks(source: legacy, destination: source, directory: commandDirectory,
                                            fileManager: fileManager, privilegedReplacement: privilegedReplacement)
            } catch {
                throw RecoveryError(underlyingError: error, recoveryErrors: [])
            }
            return false
        }
        let destination = source.deletingLastPathComponent().appendingPathComponent("egasu.app")
        let links = try ownedCommandLinks(
            source: source, destination: destination, directory: commandDirectory, fileManager: fileManager
        )
        // moveItem은 기존 파일·심볼릭 링크를 덮어쓰지 않음. 이동 실패 시 원래 앱에서 계속 실행 가능.
        try fileManager.moveItem(at: source, to: destination)
        var changedLinks: [CommandLink] = []
        do {
            for link in links {
                try replaceLink(link.url, expected: link.oldTarget, target: link.newTarget,
                                fileManager: fileManager, privilegedReplacement: privilegedReplacement)
                changedLinks.append(link)
            }
            try scheduleRelaunch(destination)
        } catch {
            var rollbackErrors: [Error] = []
            for link in changedLinks.reversed() {
                do {
                    try replaceLink(link.url, expected: link.newTarget, target: link.oldTarget,
                                    fileManager: fileManager, privilegedReplacement: privilegedReplacement)
                } catch { rollbackErrors.append(error) }
            }
            if rollbackErrors.isEmpty {
                do { try fileManager.moveItem(at: destination, to: source) }
                catch { rollbackErrors.append(error) }
            }
            if !rollbackErrors.isEmpty {
                // 롤백 실패 시 새 앱 경로 유지. 이미 복원한 링크도 실제 앱 경로로 다시 연결.
                do {
                    try repairOwnedCommandLinks(source: source, destination: destination, directory: commandDirectory,
                                                fileManager: fileManager, privilegedReplacement: privilegedReplacement)
                } catch { rollbackErrors.append(error) }
                throw RecoveryError(underlyingError: error, recoveryErrors: rollbackErrors)
            }
            throw error
        }
        AppLog.info(.lifecycle, "Renamed legacy app bundle and scheduled relaunch")
        return true
    }

    private static func repairOwnedCommandLinks(
        source: URL, destination: URL, directory: URL, fileManager: FileManager,
        privilegedReplacement: @MainActor (URL, String, String) throws -> Void
    ) throws {
        let links = try ownedCommandLinks(source: source, destination: destination, directory: directory,
                                         fileManager: fileManager)
        for link in links {
            try replaceLink(link.url, expected: link.oldTarget, target: link.newTarget,
                            fileManager: fileManager, privilegedReplacement: privilegedReplacement)
        }
        if !links.isEmpty { AppLog.info(.lifecycle, "Repaired CLI links after an interrupted app migration") }
    }

    private static func ownedCommandLinks(
        source: URL, destination: URL, directory: URL, fileManager: FileManager
    ) throws -> [CommandLink] {
        try ["openusage", "egasu"].compactMap { name in
            let url = directory.appendingPathComponent(name)
            let attributes: [FileAttributeKey: Any]
            do { attributes = try fileManager.attributesOfItem(atPath: url.path) }
            catch let error as CocoaError where error.code == .fileReadNoSuchFile { return nil }
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else { return nil }
            let oldTarget = try fileManager.destinationOfSymbolicLink(atPath: url.path)
            let ownedTargets = ["openusage", "egasu"].map {
                source.appendingPathComponent("Contents/Helpers/\($0)").path
            }
            guard ownedTargets.contains(oldTarget) else { return nil }
            return CommandLink(
                url: url, oldTarget: oldTarget,
                newTarget: destination.appendingPathComponent("Contents/Helpers/egasu").path
            )
        }
    }

    /// 이 앱의 헬퍼를 가리키는 링크만 임시 링크로 교체.
    private static func replaceLink(
        _ url: URL, expected: String, target: String, fileManager: FileManager,
        privilegedReplacement: @MainActor (URL, String, String) throws -> Void
    ) throws {
        do {
            try replaceLocalLink(url, expected: expected, target: target, fileManager: fileManager)
        } catch {
            let failure = error as NSError
            guard (failure.domain == NSCocoaErrorDomain && failure.code == CocoaError.fileWriteNoPermission.rawValue)
                || (failure.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(failure.code)) else { throw error }
            try privilegedReplacement(url, expected, target)
        }
    }

    private static func replaceLocalLink(
        _ url: URL, expected: String, target: String, fileManager: FileManager
    ) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".egasu-link-\(UUID().uuidString)")
        try fileManager.createSymbolicLink(atPath: temporary.path, withDestinationPath: target)
        do {
            guard try fileManager.destinationOfSymbolicLink(atPath: url.path) == expected else {
                throw CocoaError(.fileWriteFileExists)
            }
            guard rename(temporary.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            do { try fileManager.removeItem(at: temporary) }
            catch { AppLog.error(.lifecycle, "Could not remove temporary CLI link: \(error.localizedDescription)") }
            throw error
        }
    }
}
