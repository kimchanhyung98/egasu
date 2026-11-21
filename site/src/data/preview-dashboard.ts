import { cards, cardRows, accountCardVariants, emptyCard, type Card } from './dashboard.ts';
import { boundedView, type Row, type BoundedRow } from './demo.ts';
import { providers } from './providers.ts';
import { metricID, metricKey, isSharedMetric, providerMetrics, softLimitWindows, softLimitWindowFor, type SoftLimitWindow } from './metrics.ts';
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

export function priorityGauge(row: Row, mode: 'used' | 'left') {
  if (row.kind !== 'bounded') return { fill: row.kind === 'forecast' ? row.probability : 0, angle: null };
  const { fill, tick } = boundedView(row, mode);
  return { fill: Math.min(100, Math.max(0, fill)), angle: row.used < row.limit && tick >= 0 ? tick * 3.6 : null };
}

export function reportsLimit(row: Row): row is BoundedRow {
  return row.kind === 'bounded' && !row.noData && Number.isFinite(row.limit) && row.limit > 0 &&
    row.used >= 0 && Number.isFinite(row.used / row.limit);
}

function orderedAccountCards(cards: Card[], order?: string[]): Card[] {
  return order ? cards.sort((a, b) => order.indexOf(a.accountID ?? '') - order.indexOf(b.accountID ?? '')) : cards;
}

export function softLimitAccountStatuses(state: PreviewState, input: Card[] = cards) {
  const period = state.preferences.softLimitWindow;
  const includes = (window: SoftLimitWindow | undefined) => window && (period === 'Weekly and Monthly' || period === window);
  return state.providerOrder.flatMap((id) => {
    if (!state.enabledProviders.includes(id) || !providerMetrics[id].rows.some((metric) => softLimitWindows[metric.id]?.some(includes))) return [];
    const name = providers.find((provider) => provider.id === id)!.name;
    const sample = input.find((card) => card.provider === id) ?? emptyCard(id, name);
    return orderedAccountCards(accountCardVariants(sample), state.accountOrder[id]).map((card) => {
      const matching = cardRows(card).filter((row): row is BoundedRow => {
        const metric = metricID(id, row.label);
        return reportsLimit(row) && !!metric && !!includes(softLimitWindowFor(metric, row.periodHours));
      });
      const reported = matching.filter((row) => !row.estimated);
      const readings = reported.length ? reported : matching;
      let message = 'Quota not verified';
      if (readings.length) {
        const fraction = Math.max(...readings.map((row) => row.used / row.limit));
        const percent = fraction.toLocaleString('en-US', { style: 'percent', maximumFractionDigits: 1, roundingMode: 'floor' });
        message = !reported.length ? `Estimated usage: ${percent}`
          : fraction >= Number(state.preferences.softLimitThreshold) / 100 ? `${percent} used · Soft limit reached` : `${percent} used`;
      }
      return { provider: id, name, accountID: card.accountID, message };
    });
  });
}

/** 공개 예시만 계산. 프로바이더 API·로컬 인증을 읽지 않음. */
export function dashboardLines(state: PreviewState, input: Card[] = cards.flatMap(accountCardVariants)): DashboardLine[] {
  return state.providerOrder.flatMap((provider) => {
    if (!state.enabledProviders.includes(provider)) return [];
    const accounts = orderedAccountCards(input.filter((card) => card.provider === provider), state.accountOrder[provider]);
    return accounts.flatMap((card) => {
      const accountID = card.accountID ?? 'default';
      const order = orderedMetrics(state, provider, accountID).map((metric) => metric.id);
      return cardRows(card).flatMap((row): DashboardLine[] => {
        const id = metricID(provider, row.label);
        if (!id) return [];
        const key = metricKey(id, accountID);
        if (state.hiddenMetrics.includes(key)) return [];
        if (isSharedMetric(id) && state.activeAccounts[provider] !== accountID) return [];
        if ((row.kind === 'text' && row.values.includes('No data')) || (row.kind === 'bounded' && row.noData)) return [];
        const line: DashboardLine = { id, key, cardID: card.id, provider, accountID, row,
          pinned: state.pinnedMetrics.includes(key), severity: 'normal', rank: Infinity };
        if (reportsLimit(row)) {
          line.severity = quotaSeverity(row, state.preferences);
          const fraction = row.used / row.limit;
          const period = row.periodHours;
          const runway = fraction >= 0.05 && row.elapsed > 0 ? (1 - fraction) * period * row.elapsed / fraction : undefined;
          const reset = period * (1 - row.elapsed);
          const showThreshold = (line.severity === 'warning' && state.preferences.showWarning)
            || (line.severity === 'critical' && state.preferences.showCritical);
          if (fraction >= 1) { line.group = 'usedUp'; line.rank = reset; }
          else if (showThreshold || (state.preferences.showBurningFast && runway !== undefined && runway < reset && !row.notStarted)) {
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
  const pinned = lines.filter((line) => line.pinned);
  return {
    pinned,
    runningOut: warnings.filter((line) => !line.pinned),
    useItOrLoseIt: ranked.filter((line) => line.group === 'useItOrLoseIt' && !line.pinned),
    usedUp: ranked.filter((line) => line.group === 'usedUp' && !line.pinned),
    pending,
    allClear: !pending.length && !warnings.length && hasShownLimits,
    noLimits: !pending.length && !hasReportedLimits,
    hiddenLimits: !pending.length && !pinned.length && !hasShownLimits && hasReportedLimits,
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
