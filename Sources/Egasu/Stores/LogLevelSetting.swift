import Foundation

/// 파일에 기록할 로그 수준 — 사용자 설정 저장.
/// 원본 Tauri 판과 같은 저장 키·값을 사용하여 로그 수준 이름 유지.
/// Trace·off는 제공하지 않음 — 기본값은 info, debug는 명시적으로 선택할 때만 사용.
enum LogLevelSetting: String, Hashable, Sendable, CaseIterable, UserDefaultsBacked {
    case error
    case warn
    case info
    case debug

    /// 원본 Tauri 판과 같은 키 이름 — 두 판의 저장소는 독립.
    static let key = "logLevel"

    /// 키가 없거나 값을 해석하지 못하면 info 사용.
    static var fallback: LogLevelSetting { .info }

    var label: String {
        switch self {
        case .error: L10n.settings("Error")
        case .warn: L10n.settings("Warning")
        case .info: L10n.settings("Info")
        case .debug: L10n.settings("Debug")
        }
    }

    /// 값이 클수록 상세 기록 — 로그의 severity가 설정값 이하일 때 파일에 기록.
    var severity: Int {
        switch self {
        case .error: 0
        case .warn: 1
        case .info: 2
        case .debug: 3
        }
    }
}
