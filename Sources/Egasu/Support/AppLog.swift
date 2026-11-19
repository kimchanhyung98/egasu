import Foundation
import os

/// 파일 로그의 대괄호 태그와 macOS 통합 로그의 category에 같은 이름 사용.
enum LogTag: String, Sendable {
    case refresh
    case cache
    case http
    case auth
    case keychain
    case menubar
    case updates
    case config
    case statusItem = "statusitem"
    case localAPI = "localapi"
    case subprocess
    case lifecycle
    case notifications

    /// 계정 카드도 같은 프로바이더 태그로 기록해 파일과 통합 로그에서 계정 식별자 제외.
    static func plugin(_ id: String) -> String { "plugin:\(ProviderAccountID.family(of: id))" }
    static func auth(_ id: String) -> String { "auth:\(ProviderAccountID.family(of: id))" }
}

/// 파일과 macOS 통합 로그에 같은 기록 수준과 민감 정보 마스킹 적용.
/// HTTP 요청은 호출부에서 진단용 경로만 전달. 헤더와 본문은 제외.
package enum AppLog {
    private enum Level: Int {
        case error = 0
        case warn = 1
        case info = 2
        case debug = 3

        var label: String {
            switch self {
            case .error: "ERROR"
            case .warn: "WARN"
            case .info: "INFO"
            case .debug: "DEBUG"
            }
        }

        var osType: OSLogType {
            switch self {
            case .error: .error
            case .warn: .default
            case .info: .info
            case .debug: .debug
            }
        }
    }

    /// 여러 스레드에서 읽는 로그 수준을 lock으로 보호.
    private static let levelLock = NSLock()
    private nonisolated(unsafe) static var cachedSeverity = LogLevelSetting.fallback.severity

    /// category별 `os.Logger` 캐시.
    private static let loggerLock = NSLock()
    private nonisolated(unsafe) static var loggers: [String: Logger] = [:]

    /// 기본 기록기는 앱 로그와 테스트 로그를 분리하며, 개별 테스트에서 임시 기록기 주입 가능.
    nonisolated(unsafe) static var sink: LogFile = .shared

    // MARK: - Lifecycle

    /// 앱 시작 시 로그 파일을 열고 저장된 기록 수준을 적용.
    static func bootstrap() {
        sink.open()
        reloadLevel()
        let level = LogLevelSetting.current
        // 홈 경로를 `~`로 표시해 사용자 이름 노출 방지.
        let displayPath = (LogFile.url.path as NSString).abbreviatingWithTildeInPath
        info(LogTag.config.rawValue,
             "egasu v\(AppInfo.version) starting (level=\(level.rawValue), log=\(displayPath))")
    }

    /// 앱은 현재 설정, 독립 실행하는 CLI는 설치된 앱의 설정에서 기록 수준을 읽어 적용.
    package static func reloadLevel(defaults: UserDefaults = .standard) {
        let level = defaults.enumValue(forKey: LogLevelSetting.key, default: LogLevelSetting.fallback)
        apply(level.severity)
    }

    /// 테스트에서 사용자 설정을 변경하지 않고 기록 수준 지정.
    static func reloadLevel(_ level: LogLevelSetting) {
        apply(level.severity)
    }

    private static func apply(_ severity: Int) {
        levelLock.lock()
        cachedSeverity = severity
        levelLock.unlock()
    }

    /// 파일 로그에는 알려진 프로바이더 이름만 기록하고 계정 카드 식별자는 제외.
    static func providerFamily(_ cardID: String) -> String {
        TelemetryPrivacy.providerFamily(cardID) ?? "unknown"
    }

    /// 원문 설명 대신 오류 범주, 고정 domain, 숫자 코드만 로컬 진단에 기록.
    static func errorDetails(_ error: Error, category: ErrorCategory? = nil) -> String {
        let nsError = error as NSError
        let domain: String
        switch nsError.domain {
        case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, NSOSStatusErrorDomain, NSMachErrorDomain,
            "SUSparkleErrorDomain":
            domain = nsError.domain
        default:
            // 임의 NSError domain에는 사용자 입력이 들어갈 수 있어 앱 오류는 선언된 타입 이름만 사용.
            let errorType = type(of: error)
            domain = String(reflecting: errorType).hasPrefix("Egasu.") ? String(describing: errorType) : "other"
        }
        let category = category ?? ErrorCategory.classify(error)
        return "category=\(category.rawValue) error_domain=\(domain) error_code=\(nsError.code)"
    }

    // MARK: - Public API

    /// `@autoclosure`로 interpolation 지연 — floor 미달 라인은 메시지 생성 비용 자체가 없음.
    static func error(_ tag: String, _ message: @autoclosure () -> String) { emit(.error, tag, message) }
    static func warn(_ tag: String, _ message: @autoclosure () -> String) { emit(.warn, tag, message) }
    static func info(_ tag: String, _ message: @autoclosure () -> String) { emit(.info, tag, message) }
    static func debug(_ tag: String, _ message: @autoclosure () -> String) { emit(.debug, tag, message) }

    // 타입 태그용 편의 overload.
    static func error(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.error, tag.rawValue, message) }
    static func warn(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.warn, tag.rawValue, message) }
    static func info(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.info, tag.rawValue, message) }
    static func debug(_ tag: LogTag, _ message: @autoclosure () -> String) { emit(.debug, tag.rawValue, message) }

    // MARK: - Emit

    private static func emit(_ level: Level, _ tag: String, _ message: () -> String) {
        // 기록 대상일 때만 메시지를 생성하고 마스킹. 오류는 모든 수준에서 기록.
        levelLock.lock()
        let floor = cachedSeverity
        levelLock.unlock()
        guard level.rawValue <= floor else { return }

        let redacted = LogRedaction.redactLogMessage(message())

        logger(for: tag).log(level: level.osType, "[\(tag, privacy: .public)] \(redacted, privacy: .public)")

        let timestamp = EgasuISO8601.string(from: Date())
        sink.append("\(timestamp) [\(level.label)] [\(tag)] \(redacted)")
    }

    private static func logger(for tag: String) -> Logger {
        loggerLock.lock()
        defer { loggerLock.unlock() }
        if let existing = loggers[tag] { return existing }
        let logger = Logger(subsystem: "egasu", category: tag)
        loggers[tag] = logger
        return logger
    }
}
