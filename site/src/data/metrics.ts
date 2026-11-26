// 현재 앱의 widgetDescriptors 선언 순서. 모든 지표는 기본 표시, 고정은 사용자 선택.
/** Providers/<Name>/<Name>Provider.swift의 widgetDescriptors 선언 순서. 뒤 3개가 있으면 spendTiles. */
const declared: Record<string, Array<[string, string]>> = {
  claude: [
    ['claude.session', 'Session'],
    ['claude.weekly', 'Weekly'],
    ['claude.fable', 'Fable'],
    ['claude.trend', 'Usage Trend'],
    ['claude.extra', 'Extra Usage'],
    ['claude.sonnet', 'Sonnet'],
    ['claude.today', 'Today'],
    ['claude.yesterday', 'Yesterday'],
    ['claude.last30', 'Last 30 Days'],
  ],
  codex: [
    ['codex.session', 'Session'],
    ['codex.weekly', 'Weekly'],
    ['codex.monthly', 'Monthly'],
    ['codex.individualCredits', 'Individual Credits'],
    ['codex.trend', 'Usage Trend'],
    ['codex.resetWatch', 'Reset Watch'],
    ['codex.rateLimitResets', 'Rate Limit Resets'],
    ['codex.spark', 'Spark'],
    ['codex.sparkWeekly', 'Spark Weekly'],
    ['codex.sparkMonthly', 'Spark Monthly'],
    ['codex.credits', 'Extra Usage'],
    ['codex.today', 'Today'],
    ['codex.yesterday', 'Yesterday'],
    ['codex.last30', 'Last 30 Days'],
  ],
  cursor: [
    ['cursor.usage', 'Total Usage'],
    ['cursor.auto', 'Auto Usage'],
    ['cursor.api', 'API Usage'],
    ['cursor.onDemand', 'Extra Usage'],
    ['cursor.requests', 'Requests'],
    ['cursor.credits', 'Credits'],
    ['cursor.trend', 'Usage Trend'],
    ['cursor.today', 'Today'],
    ['cursor.yesterday', 'Yesterday'],
    ['cursor.last30', 'Last 30 Days'],
  ],
  antigravity: [
    ['antigravity.geminiPro', 'Session'],
    ['antigravity.geminiWeekly', 'Weekly'],
    ['antigravity.claude', 'Claude'],
    ['antigravity.claudeWeekly', 'Claude Weekly'],
    ['antigravity.argonWeekly', 'Argon Weekly'],
  ],
  copilot: [
    ['copilot.premium', 'Credits'],
    ['copilot.extra', 'Extra Usage'],
    ['copilot.orgCredits', 'Org Credits'],
    ['copilot.orgSpend', 'Org Spend'],
    ['copilot.chat', 'Chat'],
    ['copilot.completions', 'Completions'],
  ],
  deepseek: [
    ['deepseek.balanceUSD', 'Balance (USD)'],
    ['deepseek.balanceCNY', 'Balance (CNY)'],
    ['deepseek.api', 'API Access'],
  ],
  devin: [
    ['devin.daily', 'Daily'],
    ['devin.weekly', 'Weekly'],
    ['devin.extra', 'Extra Balance'],
  ],
  grok: [
    ['grok.weekly', 'Weekly'],
    ['grok.monthly', 'Monthly'],
    ['grok.payAsYouGo', 'Extra Usage'],
    ['grok.trend', 'Usage Trend'],
    ['grok.today', 'Today'],
    ['grok.yesterday', 'Yesterday'],
    ['grok.last30', 'Last 30 Days'],
  ],
  kimi: [
    ['kimi.session', 'Session'],
    ['kimi.weekly', 'Weekly'],
    ['kimi.total', 'Total Usage'],
    ['kimi.extra', 'Extra Usage'],
    ['kimi.extraBalance', 'Extra Balance'],
  ],
  kiro: [['kiro.credits', 'Credits']],
  'openai-api': [
    ['openai-api.costs', 'Last 30 Days'],
    ['openai-api.scope', 'Billing Scope'],
    ['openai-api.balance', 'Credit Balance'],
    ['openai-api.updated', 'Last Updated'],
  ],
  opencode: [
    ['opencode.session', 'Session'],
    ['opencode.weekly', 'Weekly'],
    ['opencode.monthly', 'Monthly'],
    ['opencode.trend', 'Usage Trend'],
    ['opencode.today', 'Today'],
    ['opencode.yesterday', 'Yesterday'],
    ['opencode.last30', 'Last 30 Days'],
  ],
  // Today·This Week·This Month는 spendTiles가 아니라 API spend 값.
  openrouter: [
    ['openrouter.credits', 'Credits'],
    ['openrouter.balance', 'Balance'],
    ['openrouter.today', 'Today'],
    ['openrouter.week', 'This Week'],
    ['openrouter.month', 'This Month'],
    ['openrouter.keyLimit', 'Key Limit'],
  ],
  zai: [
    ['zai.session', 'Session'],
    ['zai.weekly', 'Weekly'],
    ['zai.monthly', 'Monthly'],
    ['zai.webSearches', 'Web Searches'],
  ],
};

/** 계정 상세의 구역 구분. All Usage 배치는 이 목록을 읽지 않음. */
const onDemandIDs = new Set([
  'antigravity.claude', 'antigravity.claudeWeekly',
  'claude.trend', 'claude.extra', 'claude.sonnet',
  'claude.today', 'claude.yesterday', 'claude.last30',
  'codex.trend', 'codex.resetWatch', 'codex.rateLimitResets', 'codex.spark', 'codex.sparkWeekly',
  'codex.sparkMonthly', 'codex.credits', 'codex.today', 'codex.yesterday', 'codex.last30',
  'cursor.onDemand', 'cursor.requests', 'cursor.credits',
  'cursor.today', 'cursor.yesterday', 'cursor.last30',
  'copilot.orgCredits', 'copilot.orgSpend', 'copilot.chat', 'copilot.completions',
  'devin.extra',
  'grok.payAsYouGo', 'grok.today', 'grok.yesterday', 'grok.last30',
  'opencode.today', 'opencode.yesterday', 'opencode.last30',
  'openrouter.today', 'openrouter.week', 'openrouter.month', 'openrouter.keyLimit',
  'zai.webSearches',
]);

export interface MetricRow {
  id: string;
  title: string;
  pinnable: boolean;
  shared: boolean;
  enabled: boolean;
  starred: boolean;
}

export interface ProviderMetrics {
  rows: MetricRow[];
  alwaysVisible: MetricRow[];
  onDemand: MetricRow[];
  count: number;
}

/** Claude·Codex의 로컬 이력과 Reset Watch는 프로바이더 공통 설정. */
export function isSharedMetric(id: string): boolean {
  return /^(claude|codex)\.(trend|today|yesterday|last30|resetWatch)$/.test(id);
}

export const providerMetrics: Record<string, ProviderMetrics> = Object.fromEntries(
  Object.entries(declared).map(([provider, list]) => {
    const rows = list.map(([id, title]): MetricRow => ({
      id, title, pinnable: !id.endsWith('.trend'), shared: isSharedMetric(id), enabled: true, starred: false,
    }));
    return [provider, {
      rows,
      alwaysVisible: rows.filter((row) => !onDemandIDs.has(row.id)),
      onDemand: rows.filter((row) => onDemandIDs.has(row.id)),
      count: rows.length,
    }];
  }),
);

/** 계정 지표는 등록 ID, 공통 지표는 프로바이더 ID를 사용해 전환 뒤에도 설정 유지. */
export function metricKey(id: string, account = 'default'): string {
  return isSharedMetric(id) ? id : `${id}@${account}`;
}

export type SoftLimitWindow = 'Weekly' | 'Monthly';

/** 프로바이더가 지원하는 구독 한도 기간. 실제 막대에는 해당 응답의 주기를 대조한 뒤 적용. */
export const softLimitWindows: Partial<Record<string, readonly SoftLimitWindow[]>> = {
  'claude.weekly': ['Weekly'],
  'claude.fable': ['Weekly'],
  'claude.sonnet': ['Weekly'],
  'codex.weekly': ['Weekly'],
  'codex.monthly': ['Monthly'],
  'codex.sparkWeekly': ['Weekly'],
  'codex.sparkMonthly': ['Monthly'],
  'cursor.usage': ['Weekly', 'Monthly'],
  'cursor.auto': ['Weekly', 'Monthly'],
  'cursor.api': ['Weekly', 'Monthly'],
  'cursor.requests': ['Weekly', 'Monthly'],
  'antigravity.geminiWeekly': ['Weekly'],
  'antigravity.claudeWeekly': ['Weekly'],
  'antigravity.argonWeekly': ['Weekly'],
  'copilot.premium': ['Monthly'],
  'copilot.chat': ['Monthly'],
  'copilot.completions': ['Monthly'],
  'devin.weekly': ['Weekly'],
  'grok.weekly': ['Weekly'],
  'grok.monthly': ['Monthly'],
  'kimi.weekly': ['Weekly'],
  'kimi.total': ['Monthly'],
  'kiro.credits': ['Monthly'],
  'opencode.weekly': ['Weekly'],
  'opencode.monthly': ['Monthly'],
  'zai.weekly': ['Weekly'],
  'zai.monthly': ['Monthly'],
  'zai.webSearches': ['Weekly', 'Monthly'],
};

export function softLimitWindowFor(id: string, periodHours?: number): SoftLimitWindow | undefined {
  if (periodHours === undefined) return id === 'kimi.total' ? 'Monthly' : undefined;
  return softLimitWindows[id]?.find((window) => {
    const days = window === 'Weekly' ? [7] : [28, 29, 30, 31];
    return days.some((day) => Math.abs(periodHours - day * 24) <= 1);
  });
}

/** 대시보드 행 라벨 → 지표 id. 라벨이 곧 WidgetDescriptor.title이라 그대로 맞물림. */
export function metricID(provider: string, title: string): string | undefined {
  return declared[provider]?.find(([, t]) => t === title)?.[0];
}
