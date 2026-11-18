import Foundation

extension UserDefaults {
    /// 저장값을 RawRepresentable 열거형으로 변환 — 키가 없거나 값이 유효하지 않으면 기본값 사용.
    /// 저장된 열거형 설정의 공통 해석 경로.
    func enumValue<T: RawRepresentable>(forKey key: String, default fallback: T) -> T where T.RawValue == String {
        string(forKey: key).flatMap(T.init(rawValue:)) ?? fallback
    }

    /// 명시적 기본값을 지원하는 Bool 조회 — 미설정 상태와 사용자가 저장한 false 구분.
    /// 키가 없거나 Bool로 해석할 수 없을 때만 기본값 사용.
    func bool(forKey key: String, default fallback: Bool) -> Bool {
        object(forKey: key) as? Bool ?? fallback
    }
}

/// UserDefaults.standard의 고정 키에 저장하는 문자열 열거형 — current 접근자 공통 제공.
/// 별도 UserDefaults나 인스턴스별 키를 쓰는 저장소는 enumValue(forKey:default:) 직접 사용.
protocol UserDefaultsBacked: RawRepresentable where RawValue == String {
    /// UserDefaults.standard에서 사용할 저장 키.
    static var key: String { get }
    /// 키가 없거나 값이 유효하지 않을 때의 기본값.
    static var fallback: Self { get }
}

extension UserDefaultsBacked {
    /// 현재 저장값 조회 — 값이 없거나 유효하지 않으면 기본값 사용.
    static var current: Self {
        UserDefaults.standard.enumValue(forKey: key, default: fallback)
    }
}
