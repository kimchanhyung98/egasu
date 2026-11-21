import Foundation

/// Antigravity 한도 조회 중 사용자에게 표시하는 오류.
enum AntigravityError: Error, LocalizedError, Equatable {
    /// 사용 가능한 Antigravity 자격 증명을 찾지 못한 상태.
    case notSignedIn
    /// Keychain credential이 있을 수 있으나 macOS가 읽기를 거부.
    case credentialStoreUnreadable
    /// Keychain 항목은 있으나 사용 가능한 Antigravity credential 데이터가 없음.
    case invalidCredentialData
    /// 요청이나 토큰 갱신에서 인증이 거부되고 복구하지 못한 상태.
    case authExpired
    /// 자격 증명은 있으나 일시적 조회·갱신 실패 또는 유효한 응답 부재로 한도를 확인할 수 없는 상태.
    case unavailable

    var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Start Antigravity or run `agy` and try again."
        case .credentialStoreUnreadable:
            return "Couldn't read Antigravity credentials from Keychain. Unlock Keychain or sign in to Antigravity again."
        case .invalidCredentialData:
            return "Antigravity credentials are invalid. Open Antigravity or run `agy` to sign in again."
        case .authExpired:
            return "Antigravity sign-in expired. Open Antigravity or run `agy` to refresh."
        case .unavailable:
            return "Antigravity usage is temporarily unavailable. Try again shortly."
        }
    }
}
