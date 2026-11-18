import Foundation

/// 최초 실행 시 활성화되는 metric 기본값
/// `LayoutStore`가 활성 registry 기준으로 필터링 — 미정의 ID는 무시
/// provider 섹션 순서는 여기서 시드하지 않음, 빈 저장 순서는 registry 순서로 정착
enum DefaultLayout {
    /// v1 켜짐 목록 이전 직전의 기본 ON 지표 — 명시적 시드 기록이 있는 설치에만 적용.
    static let legacyV1DefaultMetricIDs: [String] = [
        "antigravity.geminiPro", "antigravity.geminiWeekly", "antigravity.claude", "antigravity.claudeWeekly",
        "antigravity.argonWeekly",

        "claude.session", "claude.weekly", "claude.fable", "claude.trend",
        "claude.today", "claude.yesterday",

        "codex.session", "codex.weekly", "codex.trend", "codex.rateLimitResets",
        "codex.today", "codex.yesterday",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30",

        "copilot.premium", "copilot.extra", "copilot.orgCredits", "copilot.orgSpend",
        "copilot.chat", "copilot.completions",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.weekly", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "kimi.session", "kimi.weekly", "kimi.total", "kimi.extra", "kimi.extraBalance",

        "kiro.credits",

        "opencode.session", "opencode.weekly", "opencode.monthly", "opencode.trend",
        "opencode.today", "opencode.yesterday", "opencode.last30",

        "openrouter.credits", "openrouter.balance",
        "openrouter.today", "openrouter.week", "openrouter.month", "openrouter.keyLimit",

        "zai.session", "zai.weekly", "zai.webSearches"
    ]

    static func metricIDs(in registry: WidgetRegistry) -> [String] {
        var seen = Set<String>()
        return registry.descriptors.compactMap { descriptor in
            let id = ProviderAccountID.canonicalMetricID(descriptor.id)
            return seen.insert(id).inserted ? id : nil
        }
    }

    /// default 시딩 도입 릴리스 시점 default-on metric의 고정 snapshot
    /// 시딩 키 없는 기존 사용자는 이미 제안받은 것으로 간주 — 과거 opt-out 유지, 이후 추가분만 자동 노출
    static let migrationBaselineMetricIDs: [String] = [
        "claude.session", "claude.weekly", "claude.trend",
        "claude.extra", "claude.today", "claude.yesterday", "claude.last30",

        "codex.session", "codex.weekly", "codex.trend",
        "codex.credits", "codex.rateLimitResets", "codex.today", "codex.yesterday", "codex.last30",

        "devin.daily", "devin.weekly", "devin.extra",

        "grok.creditsUsed", "grok.trend",
        "grok.payAsYouGo", "grok.today", "grok.yesterday", "grok.last30",

        "cursor.usage", "cursor.auto", "cursor.api", "cursor.trend",
        "cursor.onDemand", "cursor.today", "cursor.yesterday", "cursor.last30"
    ]

    /// 이전 기본 메뉴 막대 별표. 사용자 지정 별표를 Priority 고정으로 이전할 때만 비교.
    static let pinnedMetricIDs: [String] = [
        "antigravity.geminiPro", "antigravity.geminiWeekly",
        "claude.weekly",
        "codex.weekly",
        "cursor.auto", "cursor.api",
        "copilot.premium",
        "kimi.weekly",
        "kiro.credits",
        "openrouter.credits",
        "zai.session", "zai.weekly"
    ]

}
