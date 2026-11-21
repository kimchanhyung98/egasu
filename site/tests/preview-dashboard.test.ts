import assert from 'node:assert/strict';
import { test } from 'node:test';
import { initialPreviewState, setMetric, activateAccount, changePreference, restorePreviewState, moveMetric, orderedMetrics, setProviderEnabled } from '../src/data/preview-state.ts';
import { cards } from '../src/data/dashboard.ts';
import { metricID } from '../src/data/metrics.ts';
import { priorityBoard, dashboardLines, menuBarItems, softLimitAccountStatuses } from '../src/data/preview-dashboard.ts';

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
  assert.equal(board.allClear, false, 'Pinned warnings still count as matches');
});

test('Priority distinguishes hidden limits from providers with no reported limits', () => {
  let state = initialPreviewState();
  for (const line of dashboardLines(state)) {
    if (line.row.kind === 'bounded') state = setMetric(state, line.id, line.accountID, 'hide');
  }
  assert.ok(!dashboardLines(state).some((line) => line.row.kind === 'bounded'));
  assert.equal(priorityBoard(state).allClear, false);
  assert.equal(priorityBoard(state).noLimits, false);
  assert.equal(priorityBoard(state).hiddenLimits, true);

  for (const provider of state.enabledProviders) state = setProviderEnabled(state, provider, false);
  assert.equal(priorityBoard(state).noLimits, true);
  assert.equal(priorityBoard(state).hiddenLimits, false);
  const pending = priorityBoard(setProviderEnabled(state, 'cursor', true));
  assert.deepEqual(pending.pending, ['cursor']);
  assert.equal(pending.noLimits, false);
  assert.equal(pending.hiddenLimits, false);
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

test('warning and critical visibility follow separate thresholds without changing urgency or alerts', () => {
  let state = restorePreviewState({ ...initialPreviewState(), preferences: { warningNotification: true, showBurningFast: false } });
  const shown = (key: string) => priorityBoard(state).runningOut.some((line) => line.key === key);
  const warning = 'claude.weekly@account-1';
  const critical = 'codex.weekly@account-1';
  assert.ok(shown(warning) && shown(critical));
  state = changePreference(state, 'showWarning', false);
  assert.ok(!shown(warning) && shown(critical));
  assert.equal(dashboardLines(state).find((line) => line.key === warning)?.severity, 'warning');
  state = changePreference(state, 'showCritical', false);
  assert.ok(!shown(critical));
  state = changePreference(state, 'showBurningFast', true);
  assert.ok(shown(critical), 'the critical fixture also qualifies as Burning Fast');
  state = changePreference(state, 'showWarning', true);
  assert.ok(shown(warning));
  assert.equal(state.preferences.warningNotification, true);
  assert.equal(state.preferences.criticalNotification, false);
  assert.deepEqual(restorePreviewState(JSON.parse(JSON.stringify(state))), state);
});

test('metric ordering preserves each account and common slots across scope boundaries', () => {
  let state = moveMetric(initialPreviewState(), 'claude', 'account-1', 'claude.weekly', 'claude.session');
  assert.equal(orderedMetrics(state, 'claude', 'account-1')[0].id, 'claude.weekly');
  assert.equal(orderedMetrics(state, 'claude', 'account-2')[0].id, 'claude.session');
  const dropIndex = orderedMetrics(state, 'claude', 'account-1').findIndex((row) => row.id === 'claude.today');
  state = moveMetric(state, 'claude', 'account-1', 'claude.weekly', 'claude.today');
  const saved = orderedMetrics(state, 'claude', 'account-1').map((row) => row.id);
  assert.equal(saved.indexOf('claude.weekly'), dropIndex);
  assert.ok(saved.indexOf('claude.today') < saved.indexOf('claude.weekly'));
  state = activateAccount(state, 'claude', 'account-2');
  assert.deepEqual(orderedMetrics(state, 'claude', 'account-1').map((row) => row.id), saved);
  assert.deepEqual(orderedMetrics(restorePreviewState(JSON.parse(JSON.stringify(state))), 'claude', 'account-1').map((row) => row.id), saved);
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
});

test('Soft Limit reports separate account readings and distinguishes estimates from measured quotas', () => {
  let state = initialPreviewState();
  state.accountOrder.codex = ['account-2', 'account-1'];
  for (const id of ['kiro', 'opencode', 'cursor']) state = setProviderEnabled(state, id, true);
  state = changePreference(state, 'softLimitWindow', 'Weekly');
  let statuses = softLimitAccountStatuses(state);
  assert.deepEqual(statuses.filter((row) => row.provider === 'codex').map(({ accountID, message }) => [accountID, message]), [
    ['account-2', '35% used'], ['account-1', '97% used · Soft limit reached'],
  ]);
  assert.ok(!statuses.some((row) => row.provider === 'kiro'));
  state = changePreference(state, 'softLimitWindow', 'Monthly');
  state = changePreference(state, 'softLimitThreshold', '35');
  statuses = softLimitAccountStatuses(state);
  assert.equal(statuses.find((row) => row.provider === 'kiro')?.message, '46% used · Soft limit reached');
  assert.equal(statuses.find((row) => row.provider === 'opencode')?.message, 'Estimated usage: 40%');
  assert.equal(statuses.find((row) => row.provider === 'cursor')?.message, 'Quota not verified');
  assert.deepEqual(statuses.filter((row) => row.provider === 'codex').map((row) => row.message), [
    'Quota not verified', 'Quota not verified',
  ]);
  assert.ok(!statuses.some((row) => row.provider === 'claude'));
  assert.deepEqual(softLimitAccountStatuses({ ...state, enabledProviders: [] }), []);
});

test('Soft Limit compares the unrounded quantity at a threshold boundary', () => {
  const state = changePreference(initialPreviewState(), 'softLimitThreshold', '98');
  const codex = cards.find((card) => card.provider === 'codex')!;
  const weekly = codex.always.find((row) => row.kind === 'bounded' && row.label === 'Weekly');
  assert.ok(weekly?.kind === 'bounded');
  for (const [used, limit, expected] of [
    [97.99, 100, '97.9% used'], [98, 100, '98% used · Soft limit reached'],
    [-1, 100, 'Quota not verified'], [10, 0, 'Quota not verified'], [NaN, 100, 'Quota not verified'], [10, Infinity, 'Quota not verified'],
    [Number.MAX_VALUE, Number.MIN_VALUE, 'Quota not verified'],
  ] as const) {
    const sample = { ...codex, always: [{ ...weekly, used, limit }], onDemand: [] };
    const statuses = softLimitAccountStatuses(state, [sample]);
    assert.equal(statuses.find((row) => row.provider === 'codex' && row.accountID === 'account-1')?.message, expected);
  }
});

test('each reported fixture row maps to a descriptor and rendered example', () => {
  let state = initialPreviewState();
  for (const card of cards) state = setProviderEnabled(state, card.provider, true);
  const lines = dashboardLines(state);
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

test('shared Reset Watch follows the active account and preserves its forecast', () => {
  const initial = initialPreviewState();
  const forecasts = (state: typeof initial) => dashboardLines(state).filter((line) => line.id === 'codex.resetWatch');
  const before = forecasts(initial);
  assert.deepEqual(before.map((line) => line.accountID), ['account-1']);

  const changed = forecasts(activateAccount(initial, 'codex', 'account-2'));
  assert.deepEqual(changed.map((line) => line.accountID), ['account-2']);
  assert.deepEqual(changed[0].row, {
    kind: 'forecast', label: 'Reset Watch', probability: 65, voteShare: 72,
    resetAbsolute: 'By Oct 27 at 10:00', resetRelative: 'Within 18h 30m',
  });
  assert.deepEqual(before[0].row, changed[0].row);
});

test('showing an account limit restores its warning without pinning it again', () => {
  const id = 'codex.weekly';
  const key = 'codex.weekly@account-1';
  let state = setMetric(initialPreviewState(), id, 'account-1', 'pin');
  assert.ok(priorityBoard(state).pinned.some((line) => line.key === key));

  state = setMetric(state, id, 'account-1', 'hide');
  assert.deepEqual(dashboardLines(state).filter((line) => line.id === id).map((line) => line.key), ['codex.weekly@account-2']);
  const hidden = priorityBoard(state);
  assert.ok(!hidden.pinned.some((line) => line.key === key));
  assert.ok(!hidden.runningOut.some((line) => line.key === key));

  state = setMetric(state, id, 'account-1', 'show');
  assert.equal(dashboardLines(state).filter((line) => line.id === id).length, 2);
  const shown = priorityBoard(state);
  assert.deepEqual(shown.runningOut.filter((line) => line.id === id).map((line) => line.key), [key]);
  assert.ok(!shown.pinned.some((line) => line.key === key));
});

test('the dashboard omits disabled providers and reports enabled dormant ones as pending', () => {
  const disabled = setProviderEnabled(initialPreviewState(), 'codex', false);
  assert.ok(!dashboardLines(disabled).some((line) => line.provider === 'codex'));
  assert.ok(priorityBoard(setProviderEnabled(disabled, 'cursor', true)).pending.includes('cursor'));
});

test('dashboard restore rejects unknown metric ids, private scopes and unsupported pins', () => {
  const before = initialPreviewState();
  for (const key of ['codex.nonsense@account-1', 'codex.weekly@unknown', 'codex.trend@account-1', 'codex.weekly@account-1@extra']) {
    assert.throws(() => restorePreviewState({ ...before, hiddenMetrics: [key] }), key);
  }
  assert.throws(() => restorePreviewState({ ...before, pinnedMetrics: ['codex.trend'] }));
});
