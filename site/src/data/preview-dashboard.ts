import { cards, cardRows, accountCardVariants, type Card } from './dashboard.ts';
import { type Row, type BoundedRow } from './demo.ts';
import { metricID, metricKey, isSharedMetric, softLimitWindows } from './metrics.ts';
import { orderedMetrics, type PreviewState } from './preview-state.ts';

export type PriorityGroup = 'runningOut' | 'usedUp' | 'useItOrLoseIt';
export interface DashboardLine {
  id: string;
  key: string;
  cardID: string;
  provider: string;
  accountID: string;
  row: Row;
  pinned: boolean;
  severity: 'normal' | 'warning' | 'critical';
  group?: PriorityGroup;
  rank: number;
}

export function quotaSeverity(row: BoundedRow, preferences: PreviewState['preferences']): DashboardLine['severity'] {
  const left = Math.round(Math.max(0, 1 - row.used / row.limit) * 100);
  return left <= parseInt(String(preferences.critical)) ? 'critical'
    : left <= parseInt(String(preferences.warning)) ? 'warning' : 'normal';
}

function reportsLimit(row: Row): row is BoundedRow {
  return row.kind === 'bounded' && row.limit > 0 && !row.noData;
}

/** 공개 예시만 계산. 프로바이더 API·로컬 인증을 읽지 않음. */
export function dashboardLines(state: PreviewState, input: Card[] = cards.flatMap(accountCardVariants)): DashboardLine[] {
  return state.providerOrder.flatMap((provider) => {
    if (!state.enabledProviders.includes(provider)) return [];
    const viewed = state.preferences.usageCards === 'Single Card' ? state.viewedAccounts[provider] : undefined;
    const accounts = input.filter((card) => card.provider === provider && (!viewed || card.accountID === viewed)).sort((a, b) =>
      (state.accountOrder[provider]?.indexOf(a.accountID ?? '') ?? 0) - (state.accountOrder[provider]?.indexOf(b.accountID ?? '') ?? 0));
    return accounts.flatMap((card) => {
      const accountID = card.accountID ?? 'default';
      const order = orderedMetrics(state, provider, accountID).map((metric) => metric.id);
      return cardRows(card).flatMap((row): DashboardLine[] => {
        const id = metricID(provider, row.label);
        if (!id) return [];
        const key = metricKey(id, accountID);
        if (state.hiddenMetrics.includes(key)) return [];
        if (isSharedMetric(id) && (viewed ?? state.activeAccounts[provider]) !== accountID) return [];
        if ((row.kind === 'text' && row.values.includes('No data')) || (row.kind === 'bounded' && row.noData)) return [];
        const line: DashboardLine = { id, key, cardID: card.id, provider, accountID, row,
          pinned: state.pinnedMetrics.includes(key), severity: 'normal', rank: Infinity };
        if (reportsLimit(row)) {
          line.severity = quotaSeverity(row, state.preferences);
          const fraction = row.used / row.limit;
          const period = softLimitWindows[id] === 'Weekly' ? 168 : 5;
          const runway = fraction >= 0.05 && row.elapsed > 0 ? (1 - fraction) * period * row.elapsed / fraction : undefined;
          const reset = period * (1 - row.elapsed);
          if (fraction >= 1) { line.group = 'usedUp'; line.rank = reset; }
          else if (line.severity !== 'normal' || (state.preferences.showBurningFast && runway !== undefined && runway < reset && !row.notStarted)) {
            line.group = 'runningOut'; line.rank = runway ?? 1_000_000 + 1 - fraction;
          } else if (state.preferences.showUseItOrLoseIt && period > 24 && reset > 0 && reset <= 24 && fraction < 0.5) {
            line.group = 'useItOrLoseIt'; line.rank = reset;
          }
        }
        return [line];
      }).sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id));
    });
  });
}

export function priorityBoard(state: PreviewState) {
  const lines = dashboardLines(state);
  const ranked = [...lines].sort((a, b) => a.rank - b.rank);
  const enabledCards = cards.filter((card) => state.enabledProviders.includes(card.provider));
  const pending = state.enabledProviders.filter((provider) => !enabledCards.some((card) => card.provider === provider));
  const warnings = ranked.filter((line) => line.group === 'runningOut');
  const hasShownLimits = lines.some((line) => reportsLimit(line.row));
  const hasReportedLimits = enabledCards.some((card) => cardRows(card).some(reportsLimit));
  return {
    pinned: lines.filter((line) => line.pinned),
    runningOut: warnings.filter((line) => !line.pinned),
    useItOrLoseIt: ranked.filter((line) => line.group === 'useItOrLoseIt' && !line.pinned),
    usedUp: ranked.filter((line) => line.group === 'usedUp' && !line.pinned),
    pending,
    allClear: !pending.length && !warnings.length && hasShownLimits,
    noLimits: !pending.length && !hasReportedLimits,
  };
}

export function menuBarItems(state: PreviewState) {
  const board = priorityBoard(state);
  const lines = dashboardLines(state);
  const running = lines.filter((line) => line.group === 'runningOut').sort((a, b) => a.rank - b.rank);
  const selection = state.preferences.menuBarItems;
  const candidates = selection === 'Pinned Only' ? board.pinned
    : selection === 'Priority' ? [...board.pinned, ...board.runningOut, ...board.useItOrLoseIt]
      : running;
  const count = state.preferences.menuBarLimit === 'App Icon Only' ? 0 : Number(String(state.preferences.menuBarLimit).slice(-1));
  const supportsStyle = (line: DashboardLine) => state.preferences.iconStyle !== 'Bars' || line.row.kind === 'bounded';
  const counted = candidates.filter(supportsStyle);
  // Priority의 남는 칸만 소진 지표로 채우며 자동으로 채운 항목은 +N에서 제외.
  const usedUp = selection === 'Priority' ? board.usedUp.filter(supportsStyle) : [];
  const items = [...counted, ...usedUp].slice(0, count);
  const overflow = state.preferences.menuBarExtras && count ? Math.max(0, counted.length - count) : 0;
  return { items, overflow };
}
