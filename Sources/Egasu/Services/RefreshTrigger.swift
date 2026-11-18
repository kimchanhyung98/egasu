/// 캐시 우회 여부와 별개인 작업 원인.
/// 직접 요청한 새로 고침과 Keychain으로 로그인 확인 후 실행하는 계정 카드 조회를 `manual`로 집계.
enum RefreshTrigger: String, Codable, CaseIterable, Sendable {
    case scheduled
    case manual
    case accountChange = "account_change"
    case credentialChange = "credential_change"
    case resetClaim = "reset_claim"
    case weeklyTimer = "weekly_timer"
    case weeklyTimerCheck = "weekly_timer_check"
    case cli
}
