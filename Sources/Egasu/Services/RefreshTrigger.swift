/// 캐시 우회 여부와 별개인 작업 원인 — 사용자가 직접 요청한 새로 고침만 manual 집계.
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
