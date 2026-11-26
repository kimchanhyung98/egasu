import { accountFamilies } from './accounts.ts';
import { settingGroups } from './settings.ts';
import { providers } from './providers.ts';
import { metricKey, providerMetrics, type MetricRow } from './metrics.ts';

export interface PreviewState {
  preferences: Record<string, string | boolean>;
  terminalHelperInstalled: boolean;
  activeAccounts: Record<string, string>;
  enabledProviders: string[];
  hiddenMetrics: string[];
  pinnedMetrics: string[];
  metricOrder: Record<string, string[]>;
  accountNames: Record<string, string>;
  providerOrder: string[];
  accountOrder: Record<string, string[]>;
}

const rows = settingGroups.flatMap((group) => group.rows);

export function initialPreviewState(): PreviewState {
  const preferences: PreviewState['preferences'] = {};
  for (const { id, control } of rows) {
    if (control.kind === 'toggle') preferences[id] = control.on;
    if (control.kind === 'picker' || control.kind === 'number') preferences[id] = control.value;
  }
  return {
    preferences,
    terminalHelperInstalled: false,
    activeAccounts: Object.fromEntries(accountFamilies.map((family) => [family.id, family.activeAccount])),
    enabledProviders: ['claude', 'codex', 'antigravity'],
    hiddenMetrics: [], pinnedMetrics: [], metricOrder: {}, accountNames: {},
    providerOrder: providers.map((provider) => provider.id),
    accountOrder: Object.fromEntries(accountFamilies.map((family) => [family.id, family.profiles.map((profile) => profile.id)])),
  };
}

export function changePreference(state: PreviewState, id: string, value: unknown): PreviewState {
  const control = rows.find((row) => row.id === id)?.control;
  if (!control || control.kind === 'action' || control.kind === 'terminalHelper'
    || (control.kind === 'toggle' && typeof value !== 'boolean')
    || (control.kind === 'picker' && (typeof value !== 'string' || !control.options.includes(value)))
    || (control.kind === 'number' && (typeof value !== 'string' || !/^\d+$/.test(value)
      || Number(value) < control.min || Number(value) > control.max))) {
    throw new Error(`Invalid preview setting: ${id}`);
  }
  const preferences = { ...state.preferences, [id]: value as string | boolean };
  if (!preferences.betaUpdates) preferences.softLimitEnabled = false;
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

export function accountName(state: PreviewState, family: string, id: string): string {
  return state.accountNames[`${family}:${id}`] ?? account(family, id).name;
}

export function accountEmail(family: string, id: string): string {
  account(family, id);
  return `${family}.${id}@example.com`;
}

function validatedAccountName(family: string, id: string, value: string): string {
  const hasForbiddenCharacters = /[/\\\p{Cc}]/u.test(value);
  const name = value.trim() || accountEmail(family, id);
  if (hasForbiddenCharacters || name.length > 60) {
    throw new Error('Use up to 60 characters without slashes, backslashes, or control characters.');
  }
  return name;
}

export function renameAccount(
  state: PreviewState, family: string, id: string, value: string, displayedName?: (id: string) => string,
): PreviewState {
  account(family, id);
  const name = validatedAccountName(family, id, value);
  const siblings = accountFamilies.find((entry) => entry.id === family)!.profiles;
  const nameKey = name.normalize('NFC').toLowerCase();
  const matchesName = (candidate?: string) => candidate?.normalize('NFC').toLowerCase() === nameKey;
  if (siblings.some((other) => other.id !== id
    && (matchesName(accountName(state, family, other.id)) || matchesName(displayedName?.(other.id))))) {
    throw new Error('This account name is already in use.');
  }
  return { ...state, accountNames: { ...state.accountNames, [`${family}:${id}`]: name } };
}

/** 전환은 예시 활성 계정만 변경. 등록 ID 기반 표시·고정과 공통 지표 설정은 유지. */
export function activateAccount(state: PreviewState, family: string, id: string): PreviewState {
  if (account(family, id).status !== 'Ready') throw new Error('This account needs sign-in.');
  return { ...state, activeAccounts: { ...state.activeAccounts, [family]: id } };
}

export function setProviderEnabled(state: PreviewState, id: string, enabled: boolean): PreviewState {
  if (!providers.some((provider) => provider.id === id)) throw new Error('Unknown preview provider.');
  return { ...state, enabledProviders: enabled ? [...new Set([...state.enabledProviders, id])] : state.enabledProviders.filter((item) => item !== id) };
}

export function setMetric(state: PreviewState, id: string, accountID: string, action: 'show' | 'hide' | 'pin' | 'unpin'): PreviewState {
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

function interleavePrivateOrder(rows: MetricRow[], order: string[]): string[] {
  let index = 0;
  return rows.map((row) => row.shared ? row.id : order[index++]);
}

export function orderedMetrics(state: PreviewState, family: string, accountID: string) {
  const rows = providerMetrics[family].rows;
  const shared = rows.filter((row) => row.shared).map((row) => row.id);
  const own = rows.filter((row) => !row.shared).map((row) => row.id);
  const saved = state.metricOrder[`${family}:${accountID}`];
  let slots = rows.map((row) => row.id);
  if (saved?.some((id) => shared.includes(id))) {
    slots = [...saved, ...slots.filter((id) => !saved.includes(id))];
  } else if (saved) {
    const ordered = [...saved, ...own.filter((id) => !saved.includes(id))];
    slots = interleavePrivateOrder(rows, ordered);
  }
  const common = state.metricOrder[`${family}:shared`] ?? shared;
  const sharedOrder = [...common, ...shared.filter((id) => !common.includes(id))];
  let sharedIndex = 0;
  return slots.map((id) => {
    const row = rows.find((row) => row.id === id)!;
    if (!row.shared) return row;
    const commonID = sharedOrder[sharedIndex++];
    return rows.find((row) => row.id === commonID)!;
  });
}

export function moveMetric(state: PreviewState, family: string, accountID: string, id: string, target: string): PreviewState {
  const rows = orderedMetrics(state, family, accountID);
  const from = rows.findIndex((row) => row.id === id);
  const to = rows.findIndex((row) => row.id === target);
  if (from < 0 || to < 0 || from === to) return state;
  const order = rows.map((row) => row.id);
  order.splice(from, 1);
  // 드롭 대상의 원래 슬롯 사용 — 아래로 옮기면 대상 뒤, 위로 옮기면 대상 앞.
  order.splice(to, 0, id);
  const common = order.filter((id) => rows.find((row) => row.id === id)!.shared);
  return { ...state, metricOrder: { ...state.metricOrder,
    [`${family}:${accountID}`]: order, [`${family}:shared`]: common } };
}

function record(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('Invalid preview preferences.');
  return value as Record<string, unknown>;
}

/** 삭제된 웹 설정만 제외. 기존 언어·테마·시간·안내선 선택은 이어받음. */
export function restorePreviewState(value: unknown): PreviewState {
  const stored = record(value);
  let state = initialPreviewState();
  const obsolete = new Set(['usageCards', 'density', 'increaseTransparency']);
  const renamed: Record<string, string> = {
    alwaysShowPacing: 'paceMarks', hideFromScreenShare: 'privacyMode',
    healthyToClose: 'warningNotification', underTenPercent: 'criticalNotification',
    useItOrLoseIt: 'useItOrLoseItNotification',
  };
  const preferences = record(stored.preferences);
  if (Object.hasOwn(preferences, 'betaUpdates')) state = changePreference(state, 'betaUpdates', preferences.betaUpdates);
  for (const [id, preference] of Object.entries(preferences)) {
    if (id === 'betaUpdates' || (id === 'softLimitWindow' && preference === '5 Hours')) continue;
    if (!obsolete.has(id)) state = changePreference(state, Object.hasOwn(renamed, id) ? renamed[id] : id, preference);
  }
  if (stored.terminalHelperInstalled !== undefined) {
    if (typeof stored.terminalHelperInstalled !== 'boolean') throw new Error('Invalid preview Terminal Helper status.');
    state.terminalHelperInstalled = stored.terminalHelperInstalled;
  }
  for (const [family, id] of Object.entries(record(stored.activeAccounts))) {
    if (typeof id !== 'string') throw new Error('Invalid active preview account.');
    state = activateAccount(state, family, id);
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
    if (stored[field] === undefined) continue;
    if (!Array.isArray(stored[field])) throw new Error('Invalid preview metrics.');
    for (const key of stored[field]) {
      if (typeof key !== 'string') throw new Error('Invalid preview metric.');
      const parts = key.split('@');
      const [id, accountID] = parts;
      const scope = accountID ?? state.activeAccounts[id.split('.')[0]] ?? 'default';
      if (parts.length > 2 || (accountID !== undefined && metricKey(id, scope) !== key)) throw new Error('Invalid preview metric scope.');
      state = setMetric(state, id, scope, field === 'hiddenMetrics' ? 'hide' : 'pin');
    }
  }
  for (const [key, name] of Object.entries(record(stored.accountNames ?? {}))) {
    const parts = key.split(':');
    const [family, id] = parts;
    if (parts.length !== 2 || typeof name !== 'string') throw new Error('Invalid preview account name.');
    state.accountNames[key] = validatedAccountName(family, id, name);
  }
  // 이름 중복은 복원할 최종 집합에서 검사.
  for (const [key, name] of Object.entries(state.accountNames)) {
    const [family, id] = key.split(':');
    state = renameAccount(state, family, id, name);
  }
  for (const [key, order] of Object.entries(record(stored.metricOrder ?? {}))) {
    const parts = key.split(':');
    const [family, scope] = parts;
    const rows = providerMetrics[family]?.rows;
    if (!rows || parts.length !== 2) throw new Error('Invalid preview metric order.');
    if (scope !== 'shared') {
      if (accountFamilies.some((entry) => entry.id === family)) account(family, scope);
      else if (scope !== 'default') throw new Error('Invalid preview metric order.');
    }
    const valid = rows.filter((row) => scope !== 'shared' || row.shared).map((row) => row.id);
    if (!Array.isArray(order) || order.length !== new Set(order).size || !order.every((id) => valid.includes(id))) {
      throw new Error('Invalid preview metric order.');
    }
    const legacyPrivate = scope !== 'shared' && !order.some((id) => rows.find((row) => row.id === id)!.shared);
    const missing = legacyPrivate ? rows.filter((row) => !row.shared).map((row) => row.id) : valid;
    let merged = [...order, ...missing.filter((id) => !order.includes(id))];
    const credits = 'codex.individualCredits';
    if (merged.includes(credits) && !order.includes(credits)) {
      merged.splice(merged.indexOf(credits), 1);
      if (legacyPrivate) merged = interleavePrivateOrder(rows.filter((row) => row.id !== credits), merged);
      merged.splice(merged.indexOf('codex.monthly') + 1, 0, credits);
    }
    state.metricOrder[key] = merged;
  }
  const providerOrder = stored.providerOrder;
  if (providerOrder !== undefined) {
    if (!Array.isArray(providerOrder) || new Set(providerOrder).size !== providerOrder.length
      || !providerOrder.every((id) => state.providerOrder.includes(id))) throw new Error('Invalid preview order.');
    state.providerOrder = [...providerOrder, ...state.providerOrder.filter((id) => !providerOrder.includes(id))];
  }
  for (const [family, order] of Object.entries(record(stored.accountOrder ?? {}))) {
    const valid = Object.hasOwn(state.accountOrder, family) ? state.accountOrder[family] : undefined;
    if (!valid || !Array.isArray(order) || order.length !== valid.length || new Set(order).size !== order.length || !order.every((id) => valid.includes(id))) throw new Error('Invalid preview account order.');
    state.accountOrder[family] = order;
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
