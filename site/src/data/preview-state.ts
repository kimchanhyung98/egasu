import { accountFamilies } from './accounts.ts';
import { settingGroups, type Control } from './settings.ts';
import { providers } from './providers.ts';
import { metricKey, providerMetrics } from './metrics.ts';

export interface PreviewState {
  preferences: Record<string, string | boolean>;
  activeAccounts: Record<string, string>;
  viewedAccounts: Record<string, string>;
  enabledProviders: string[];
  hiddenMetrics: string[];
  pinnedMetrics: string[];
  metricOrder: Record<string, string[]>;
  providerOrder: string[];
  accountOrder: Record<string, string[]>;
}

// 기존 Settings에는 대시보드 설정 일부만 노출. 나머지는 미리보기 기본값.
const dashboardControls: Record<string, Control> = {
  defaultTab: { kind: 'picker', value: 'Priority', options: ['Priority', 'All Usage'] },
  allUsageLayout: { kind: 'picker', value: 'Minimal', options: ['Minimal', 'Cards'] },
  menuBarLimit: { kind: 'picker', value: 'Up to 3', options: ['App Icon Only', 'Up to 1', 'Up to 2', 'Up to 3', 'Up to 4', 'Up to 5'] },
  menuBarItems: { kind: 'picker', value: 'Running Out', options: ['Running Out', 'Priority', 'Pinned Only'] },
  menuBarExtras: { kind: 'toggle', on: true },
  warning: { kind: 'picker', value: '30% left', options: Array.from({ length: 11 }, (_, index) => `${70 - index * 5}% left`) },
  critical: { kind: 'picker', value: '10% left', options: ['25% left', '20% left', '15% left', '10% left', '5% left'] },
  showBurningFast: { kind: 'toggle', on: true },
  showUseItOrLoseIt: { kind: 'toggle', on: true },
};
const controls = new Map<string, Control>(Object.entries(dashboardControls));
for (const { id, control } of settingGroups.flatMap((group) => group.rows)) controls.set(id, control);

export function initialPreviewState(): PreviewState {
  const preferences: PreviewState['preferences'] = {};
  for (const [id, control] of controls) {
    if (control.kind === 'toggle') preferences[id] = control.on;
    if (control.kind === 'picker' || control.kind === 'number') preferences[id] = control.value;
  }
  preferences.usageCards = 'Separate Cards';
  return {
    preferences,
    activeAccounts: Object.fromEntries(accountFamilies.map((family) => [family.id, family.activeAccount])),
    viewedAccounts: Object.fromEntries(accountFamilies.map((family) => [family.id, family.activeAccount])),
    enabledProviders: ['claude', 'codex', 'antigravity'],
    hiddenMetrics: [],
    pinnedMetrics: [],
    metricOrder: {},
    providerOrder: providers.map((provider) => provider.id),
    accountOrder: Object.fromEntries(accountFamilies.map((family) => [family.id, family.profiles.map((profile) => profile.id)])),
  };
}

export function changePreference(state: PreviewState, id: string, value: unknown): PreviewState {
  const control = controls.get(id);
  if (!control || control.kind === 'action'
    || (control.kind === 'toggle' && typeof value !== 'boolean')
    || (control.kind === 'picker' && (typeof value !== 'string' || !control.options.includes(value)))
    || (control.kind === 'number' && (typeof value !== 'string' || !/^\d+$/.test(value)
      || Number(value) < control.min || Number(value) > control.max))) {
    throw new Error(`Invalid preview setting: ${id}`);
  }
  const preferences = { ...state.preferences, [id]: value as string | boolean };
  if (id === 'warning' && parseInt(String(preferences.critical)) >= parseInt(String(value))) {
    preferences.critical = `${parseInt(String(value)) - 5}% left`;
  }
  if (id === 'critical' && parseInt(String(preferences.warning)) <= parseInt(String(value))) {
    preferences.warning = `${parseInt(String(value)) + 5}% left`;
  }
  return { ...state, preferences };
}

function account(family: string, id: string) {
  const profile = accountFamilies.find((entry) => entry.id === family)?.profiles.find((entry) => entry.id === id);
  if (!profile) throw new Error(`Unknown preview account: ${family}/${id}`);
  return profile;
}

export function accountName(_state: PreviewState, family: string, id: string): string {
  return account(family, id).name;
}

export function accountEmail(family: string, id: string): string {
  account(family, id);
  return `${family}.${id}@example.com`;
}

/** 대시보드 선택은 표시만 변경. 터미널용 활성 계정은 유지. */
export function selectDashboardAccount(state: PreviewState, family: string, id: string): PreviewState {
  account(family, id);
  return { ...state, viewedAccounts: { ...state.viewedAccounts, [family]: id } };
}

/** Settings에서 확정한 전환은 활성 계정과 대시보드 선택을 함께 이동. */
export function activateAccount(state: PreviewState, family: string, id: string): PreviewState {
  if (account(family, id).status !== 'Ready') throw new Error('This account needs sign-in.');
  return { ...selectDashboardAccount(state, family, id), activeAccounts: { ...state.activeAccounts, [family]: id } };
}

export function setProviderEnabled(state: PreviewState, id: string, enabled: boolean): PreviewState {
  if (!providers.some((provider) => provider.id === id)) throw new Error('Unknown preview provider.');
  return { ...state, enabledProviders: enabled ? [...new Set([...state.enabledProviders, id])] : state.enabledProviders.filter((item) => item !== id) };
}

type MetricAction = 'show' | 'hide' | 'pin' | 'unpin';

export function setMetric(state: PreviewState, id: string, accountID: string, action: MetricAction): PreviewState {
  const family = id.split('.')[0];
  const metric = Object.hasOwn(providerMetrics, family) && providerMetrics[family].rows.find((row) => row.id === id);
  if (!metric) throw new Error('Unknown preview metric.');
  if (accountFamilies.some((entry) => entry.id === family)) account(family, accountID);
  else if (accountID !== 'default') throw new Error('Unknown preview account.');
  const key = metricKey(id, accountID);
  const hidden = new Set(state.hiddenMetrics);
  const pinned = new Set(state.pinnedMetrics);
  if (action === 'hide') { hidden.add(key); pinned.delete(key); }
  if (action === 'show') hidden.delete(key);
  if (action === 'unpin') pinned.delete(key);
  if (action === 'pin') {
    if (!metric.pinnable || hidden.has(key)) throw new Error('Only visible values can be pinned.');
    pinned.add(key);
  }
  return { ...state, hiddenMetrics: [...hidden], pinnedMetrics: [...pinned] };
}

export function orderedMetrics(state: PreviewState, family: string, accountID: string) {
  const rows = providerMetrics[family].rows;
  const scopedRows = (shared: boolean) => {
    const group = rows.filter((row) => row.shared === shared);
    const order = state.metricOrder[`${family}:${shared ? 'shared' : accountID}`];
    return order ? [...group].sort((a, b) => order.indexOf(a.id) - order.indexOf(b.id)) : group;
  };
  const privateRows = scopedRows(false).values();
  const sharedRows = scopedRows(true).values();
  return rows.map((row) => (row.shared ? sharedRows : privateRows).next().value!);
}

/** 기존 Customize의 지표 한 행은 프로바이더 전체에 적용. */
export function setCustomizeMetric(state: PreviewState, id: string, action: MetricAction): PreviewState {
  const family = id.split('.')[0];
  const profiles = accountFamilies.find((entry) => entry.id === family)?.profiles;
  const accountIDs = profiles?.map((profile) => profile.id) ?? ['default'];
  if (action === 'pin') {
    accountIDs.forEach((accountID) => {
      if (!state.hiddenMetrics.includes(metricKey(id, accountID))) state = setMetric(state, id, accountID, action);
    });
    return state;
  }
  return accountIDs.reduce((result, accountID) => setMetric(result, id, accountID, action), state);
}

/** 기존 Customize의 단일 스위치·별은 현재 기준 계정의 상태 표시. */
export function customizeMetricStatus(state: PreviewState, id: string): { shown: boolean; pinned: boolean } {
  const family = id.split('.')[0];
  const accountID = state.preferences.usageCards === 'Single Card' ? state.viewedAccounts[family] : state.activeAccounts[family];
  const key = metricKey(id, accountID);
  return { shown: !state.hiddenMetrics.includes(key), pinned: state.pinnedMetrics.includes(key) };
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid preview preferences.');
  return value as Record<string, unknown>;
}

export function restorePreviewState(value: unknown): PreviewState {
  const stored = record(value);
  let state = initialPreviewState();
  for (const [id, preference] of Object.entries(record(stored.preferences))) {
    state = changePreference(state, id, preference);
  }
  for (const [family, id] of Object.entries(record(stored.activeAccounts))) {
    if (typeof id !== 'string') throw new Error('Invalid active preview account.');
    state = activateAccount(state, family, id);
  }
  for (const [family, id] of Object.entries(record(stored.viewedAccounts))) {
    if (typeof id !== 'string') throw new Error('Invalid selected preview account.');
    state = selectDashboardAccount(state, family, id);
  }
  if (stored.enabledProviders !== undefined) {
    if (!Array.isArray(stored.enabledProviders)) throw new Error('Invalid preview providers.');
    state.enabledProviders = [];
    for (const id of stored.enabledProviders) {
      if (typeof id !== 'string') throw new Error('Invalid preview provider.');
      state = setProviderEnabled(state, id, true);
    }
  }
  for (const field of ['hiddenMetrics', 'pinnedMetrics'] as const) {
    const keys = stored[field];
    if (keys === undefined) continue;
    if (!Array.isArray(keys)) throw new Error('Invalid preview metrics.');
    for (const key of keys) {
      if (typeof key !== 'string') throw new Error('Invalid preview metric.');
      const parts = key.split('@');
      const [id, accountID] = parts;
      const scope = accountID ?? state.activeAccounts[id.split('.')[0]] ?? 'default';
      if (parts.length > 2 || metricKey(id, scope) !== key) throw new Error('Invalid preview metric scope.');
      state = setMetric(state, id, scope, field === 'hiddenMetrics' ? 'hide' : 'pin');
    }
  }
  for (const [key, order] of Object.entries(record(stored.metricOrder ?? {}))) {
    const parts = key.split(':');
    const [family, scope] = parts;
    if (parts.length !== 2 || !Object.hasOwn(providerMetrics, family)
      || (scope !== 'shared' && !(state.accountOrder[family] ?? ['default']).includes(scope))) {
      throw new Error('Invalid preview metric scope.');
    }
    const valid = providerMetrics[family].rows.filter((row) => row.shared === (scope === 'shared')).map((row) => row.id);
    if (!Array.isArray(order) || order.length !== new Set(order).size || !order.every((id) => valid.includes(id))) {
      throw new Error('Invalid preview metric order.');
    }
    state.metricOrder[key] = [...order, ...valid.filter((id) => !order.includes(id))];
  }
  return state;
}

export function previewTime(text: string, format: string | boolean, systemHour12: boolean): string {
  if (format !== '12-hour' && !(format === 'Auto' && systemHour12)) return text;
  return text.replace(/\b(\d{1,2}):(\d{2})\b/g, (_, hour: string, minute: string) => {
    const value = Number(hour);
    return `${value % 12 || 12}:${minute} ${value < 12 ? 'AM' : 'PM'}`;
  });
}
