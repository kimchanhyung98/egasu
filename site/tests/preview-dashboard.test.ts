import assert from 'node:assert/strict';
import { test } from 'node:test';
import { initialPreviewState, setMetric, activateAccount, changePreference, restorePreviewState, selectDashboardAccount, setCustomizeMetric, customizeMetricStatus, setProviderEnabled } from '../src/data/preview-state.ts';
import { cards } from '../src/data/dashboard.ts';
import { metricID } from '../src/data/metrics.ts';
import { priorityBoard, dashboardLines, menuBarItems } from '../src/data/preview-dashboard.ts';

test('Priority separates low and spent limits and keeps pinned limits in one section', () => {
  let state = initialPreviewState();
  let board = priorityBoard(state);
  assert.ok(board.runningOut.some((line) => line.key === 'codex.weekly@account-1'));
  assert.ok(board.usedUp.some((line) => line.key === 'claude.fable@account-1'));
  assert.equal(board.allClear, false);
  state = setMetric(state, 'codex.weekly', 'account-1', 'pin');
  state = setMetric(state, 'claude.fable', 'account-1', 'pin');
  board = priorityBoard(state);
  assert.ok(board.pinned.some((line) => line.key === 'codex.weekly@account-1'));
  assert.ok(board.pinned.some((line) => line.key === 'claude.fable@account-1'));
  assert.ok(!board.runningOut.some((line) => line.key === 'codex.weekly@account-1'));
  assert.ok(!board.usedUp.some((line) => line.key === 'claude.fable@account-1'));
  assert.equal(board.allClear, false, 'Pinned warnings still suppress All Clear');
});

test('Priority distinguishes hidden limits from providers with no reported limits', () => {
  let state = initialPreviewState();
  for (const line of dashboardLines(state)) {
    if (line.row.kind === 'bounded') state = setMetric(state, line.id, line.accountID, 'hide');
  }
  assert.ok(!dashboardLines(state).some((line) => line.row.kind === 'bounded'));
  assert.equal(priorityBoard(state).allClear, false);
  assert.equal(priorityBoard(state).noLimits, false);

  for (const provider of state.enabledProviders) state = setProviderEnabled(state, provider, false);
  assert.equal(priorityBoard(state).noLimits, true);
  const pending = priorityBoard(setProviderEnabled(state, 'cursor', true));
  assert.deepEqual(pending.pending, ['cursor']);
  assert.equal(pending.noLimits, false);
});

test('hiding a metric unpins only that account while shared settings survive switching', () => {
  let state = setMetric(initialPreviewState(), 'claude.weekly', 'account-1', 'pin');
  state = setMetric(state, 'claude.weekly', 'account-2', 'pin');
  state = setMetric(state, 'claude.weekly', 'account-1', 'hide');
  assert.deepEqual(state.pinnedMetrics, ['claude.weekly@account-2']);
  assert.ok(!dashboardLines(state).some((line) => line.key === 'claude.weekly@account-1'));
  assert.ok(dashboardLines(state).some((line) => line.key === 'claude.weekly@account-2'));
  state = setMetric(state, 'claude.today', 'account-1', 'pin');
  state = activateAccount(state, 'claude', 'account-2');
  const shared = dashboardLines(state).filter((line) => line.id === 'claude.today');
  assert.equal(shared.length, 1);
  assert.equal(shared[0].accountID, 'account-2');
  assert.ok(state.pinnedMetrics.includes(shared[0].key));
  assert.deepEqual(restorePreviewState(JSON.parse(JSON.stringify(state))), state);
});

test('all descriptors start visible, have no pin cap, and omit unreported values', () => {
  let state = initialPreviewState();
  assert.deepEqual(state.hiddenMetrics, []);
  assert.deepEqual(state.pinnedMetrics, []);
  for (const id of ['claude.session', 'claude.weekly', 'claude.fable', 'claude.today']) state = setMetric(state, id, 'account-1', 'pin');
  assert.equal(state.pinnedMetrics.length, 4);
  assert.ok(!dashboardLines(state).some((line) => line.id === 'antigravity.argonWeekly'));
  assert.throws(() => setMetric(state, 'claude.trend', 'account-1', 'pin'));
  state = setMetric(state, 'claude.weekly', 'account-1', 'hide');
  assert.throws(() => setMetric(state, 'claude.weekly', 'account-1', 'pin'));
});

test('menu bar fills spare Priority slots with Used Up without counting them in overflow', () => {
  let state = changePreference(initialPreviewState(), 'menuBarLimit', 'Up to 1');
  state = changePreference(state, 'menuBarItems', 'Priority');
  const result = menuBarItems(state);
  assert.equal(result.items.length, 1);
  assert.ok(!result.items.some((line) => line.group === 'usedUp'));
  const board = priorityBoard(state);
  assert.equal(result.overflow, board.runningOut.length + board.useItOrLoseIt.length - 1);
  for (const line of [...board.runningOut, ...board.useItOrLoseIt]) state = setMetric(state, line.id, line.accountID, 'hide');
  const spare = menuBarItems(state);
  assert.equal(spare.items[0].group, 'usedUp');
  assert.equal(spare.overflow, 0);
  state = changePreference(state, 'menuBarItems', 'Pinned Only');
  assert.equal(menuBarItems(state).items.length, 0);
});

test('menu bar Bars excludes non-limit pins while explicit Used Up pins still count', () => {
  let state = changePreference(initialPreviewState(), 'menuBarItems', 'Pinned Only');
  state = changePreference(state, 'menuBarLimit', 'Up to 1');
  state = changePreference(state, 'iconStyle', 'Text');
  state = setMetric(state, 'claude.today', 'account-1', 'pin');
  state = setMetric(state, 'claude.fable', 'account-1', 'pin');
  assert.equal(menuBarItems(state).overflow, 1);
  state = changePreference(state, 'iconStyle', 'Bars');
  assert.deepEqual(menuBarItems(state).items.map((line) => line.key), ['claude.fable@account-1']);
  assert.equal(menuBarItems(state).overflow, 0);
  state = changePreference(state, 'menuBarLimit', 'App Icon Only');
  assert.deepEqual(menuBarItems(state), { items: [], overflow: 0 });
});

test('thresholds remain ordered and update Priority without changing sample values', () => {
  let state = changePreference(initialPreviewState(), 'warning', '20% left');
  state = changePreference(state, 'critical', '25% left');
  assert.equal(state.preferences.warning, '30% left');
  state = changePreference(state, 'warning', '20% left');
  assert.equal(state.preferences.critical, '15% left');
  assert.ok(!priorityBoard(state).runningOut.some((line) => line.key === 'claude.weekly@account-1'));
});

test('restored metric order is applied to the saved account and keeps shared slots', () => {
  const initial = initialPreviewState();
  const state = restorePreviewState({
    ...initial,
    metricOrder: { 'claude:account-1': ['claude.weekly'] },
  });
  const accountOrder = (preview: typeof initial, accountID: string) => dashboardLines(preview)
    .filter((line) => line.provider === 'claude' && line.accountID === accountID).map((line) => line.id);
  const original = accountOrder(initial, 'account-1');
  assert.deepEqual(accountOrder(state, 'account-1'), ['claude.weekly', 'claude.session', ...original.slice(2)]);
  assert.deepEqual(accountOrder(state, 'account-2'), accountOrder(initial, 'account-2'));
  assert.throws(() => restorePreviewState({
    ...initial,
    metricOrder: { 'claude:account-1': ['claude.today'] },
  }));
});


test('each reported fixture row maps to a descriptor and rendered example', () => {
  const lines = dashboardLines(initialPreviewState());
  for (const card of cards) {
    for (const row of [...card.always, ...card.onDemand]) {
      const id = metricID(card.provider, row.label);
      assert.ok(id, `${card.provider}: ${row.label}`);
      assert.ok(lines.some((line) => line.id === id && line.row.kind === row.kind), id);
    }
  }
  assert.equal(lines.filter((line) => line.id === 'codex.resetWatch').length, 1);
  assert.equal(lines.filter((line) => line.id === 'codex.rateLimitResets').length, 2);
});

test('retained single-card choices only change the viewed account and keep the shared forecast', () => {
  let state = changePreference(initialPreviewState(), 'usageCards', 'Single Card');
  state = selectDashboardAccount(state, 'codex', 'account-2');
  const viewed = dashboardLines(state).filter((line) => line.provider === 'codex');
  assert.deepEqual([...new Set(viewed.map((line) => line.accountID))], ['account-2']);
  const viewedForecast = viewed.find((line) => line.id === 'codex.resetWatch');
  assert.equal(viewedForecast?.accountID, 'account-2');
  assert.deepEqual(viewedForecast?.row, {
    kind: 'forecast', label: 'Reset Watch', probability: 65, voteShare: 72,
    resetAbsolute: 'By Oct 27 at 10:00', resetRelative: 'Within 18h 30m',
  });
  assert.equal(state.activeAccounts.codex, 'account-1');
  state = changePreference(state, 'usageCards', 'Separate Cards');
  const separate = dashboardLines(state).filter((line) => line.provider === 'codex');
  assert.deepEqual([...new Set(separate.map((line) => line.accountID))], ['account-1', 'account-2']);
  const activeForecast = separate.find((line) => line.id === 'codex.resetWatch');
  assert.equal(activeForecast?.accountID, 'account-1');
  assert.deepEqual(activeForecast?.row, viewedForecast?.row);
});

test('legacy Customize still hides both account rows and restores their actual Priority eligibility', () => {
  let state = setCustomizeMetric(initialPreviewState(), 'codex.weekly', 'pin');
  assert.equal(priorityBoard(state).pinned.filter((line) => line.id === 'codex.weekly').length, 2);
  state = setCustomizeMetric(state, 'codex.weekly', 'hide');
  assert.deepEqual(customizeMetricStatus(state, 'codex.weekly'), { shown: false, pinned: false });
  assert.ok(!dashboardLines(state).some((line) => line.id === 'codex.weekly'));
  assert.ok(!priorityBoard(state).pinned.some((line) => line.id === 'codex.weekly'));
  assert.ok(!priorityBoard(state).runningOut.some((line) => line.id === 'codex.weekly'));
  state = setCustomizeMetric(state, 'codex.weekly', 'show');
  assert.equal(dashboardLines(state).filter((line) => line.id === 'codex.weekly').length, 2);
  const shown = priorityBoard(state);
  assert.deepEqual(shown.runningOut.filter((line) => line.id === 'codex.weekly').map((line) => line.key), ['codex.weekly@account-1']);
  assert.ok(!shown.pinned.some((line) => line.id === 'codex.weekly'));
  const disabled = setProviderEnabled(state, 'codex', false);
  assert.ok(!dashboardLines(disabled).some((line) => line.provider === 'codex'));
  assert.ok(priorityBoard(setProviderEnabled(disabled, 'cursor', true)).pending.includes('cursor'));
});

test('V preview restores earlier Settings alongside its new dashboard controls', () => {
  const restored = restorePreviewState({
    preferences: { density: 'Default', theme: 'Dark', usageCards: 'Single Card' },
    activeAccounts: { codex: 'account-1' },
    viewedAccounts: { codex: 'account-2' },
  });
  assert.equal(restored.preferences.density, 'Default');
  assert.equal(restored.preferences.theme, 'Dark');
  assert.equal(restored.preferences.usageCards, 'Single Card');
  assert.equal(restored.preferences.defaultTab, 'Priority');
  assert.equal(restored.preferences.allUsageLayout, 'Minimal');
  const updated = changePreference(restored, 'allUsageLayout', 'Cards');
  assert.equal(restorePreviewState(JSON.parse(JSON.stringify(updated))).preferences.allUsageLayout, 'Cards');
  assert.throws(() => changePreference(updated, 'allUsageLayout', 'Compact'));
});

test('dashboard restore rejects unknown metric ids, private scopes and unsupported pins', () => {
  const before = initialPreviewState();
  for (const key of ['codex.nonsense@account-1', 'codex.weekly@unknown', 'codex.trend@account-1', 'codex.weekly@account-1@extra']) {
    assert.throws(() => restorePreviewState({ ...before, hiddenMetrics: [key] }), key);
  }
  assert.throws(() => restorePreviewState({ ...before, pinnedMetrics: ['codex.trend'] }));
});
