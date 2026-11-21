import assert from 'node:assert/strict';
import { test } from 'node:test';
import { initialPreviewState, orderedMetrics, moveMetric, restorePreviewState, setMetric, type PreviewState } from '../src/data/preview-state.ts';
const ids = (state: PreviewState, account: string) => orderedMetrics(state, 'codex', account).map((row) => row.id);
const a = 'account-1', b = 'account-2';
test('default order follows the interleaved provider declaration', () => {
  assert.deepEqual(ids(initialPreviewState(), a), [
    'codex.session', 'codex.weekly', 'codex.monthly', 'codex.individualCredits', 'codex.trend', 'codex.resetWatch', 'codex.rateLimitResets',
    'codex.spark', 'codex.sparkWeekly', 'codex.sparkMonthly', 'codex.credits', 'codex.today', 'codex.yesterday', 'codex.last30',
  ]);
});
test('a quota can cross a common row and survive reload without changing the other account', () => {
  let state = initialPreviewState();
  const other = ids(state, b);
  state = setMetric(state, 'codex.weekly', a, 'hide');
  const hidden = [...state.hiddenMetrics];
  state = moveMetric(state, 'codex', a, 'codex.session', 'codex.today');
  assert.ok(ids(state, a).indexOf('codex.today') < ids(state, a).indexOf('codex.session'));
  const restored = restorePreviewState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(ids(restored, a), ids(state, a));
  assert.deepEqual(ids(restored, b), other);
  assert.deepEqual(restored.hiddenMetrics, hidden);
});
test('common order is shared while every account retains its private slots', () => {
  let state = moveMetric(initialPreviewState(), 'codex', b, 'codex.weekly', 'codex.today');
  const pattern = orderedMetrics(state, 'codex', b).map((row) => row.shared ? 'shared' : row.id);
  state = moveMetric(state, 'codex', a, 'codex.today', 'codex.trend');
  const sharedA = orderedMetrics(state, 'codex', a).filter((row) => row.shared).map((row) => row.id);
  const sharedB = orderedMetrics(state, 'codex', b).filter((row) => row.shared).map((row) => row.id);
  assert.deepEqual(sharedA, sharedB);
  assert.deepEqual(orderedMetrics(state, 'codex', b).map((row) => row.shared ? 'shared' : row.id), pattern);
  assert.deepEqual(ids(restorePreviewState(JSON.parse(JSON.stringify(state))), b), ids(state, b));
});
test('legacy private-only order keeps the declared common slots', () => {
  const state = initialPreviewState();
  state.metricOrder['codex:' + a] = ['codex.weekly', 'codex.session'];
  const restored = restorePreviewState(JSON.parse(JSON.stringify(state)));
  assert.deepEqual(ids(restored, a).slice(0, 6), ['codex.weekly', 'codex.session', 'codex.monthly', 'codex.individualCredits', 'codex.trend', 'codex.resetWatch']);
});
test('a newly available Codex credit limit follows monthly once and keeps its own saved position', () => {
  const state = initialPreviewState();
  const original = ids(state, a).filter((id) => id !== 'codex.individualCredits' && id !== 'codex.monthly');
  state.metricOrder['codex:' + a] = [...original, 'codex.monthly'];
  const migrated = restorePreviewState(state);
  assert.deepEqual(ids(migrated, a).slice(-2), ['codex.monthly', 'codex.individualCredits']);
  const reordered = moveMetric(migrated, 'codex', a, 'codex.individualCredits', 'codex.session');
  assert.deepEqual(ids(restorePreviewState(reordered), a), ids(reordered, a));
});
test('restore rejects an unknown account scope and duplicate or foreign metrics', () => {
  const invalid: Array<[string, string[]]> = [['codex:unknown', ['codex.weekly']], ['codex:' + a, ['codex.weekly', 'codex.weekly']], ['codex:' + a, ['claude.session']], ['codex:shared', ['codex.weekly']]];
  for (const [key, value] of invalid) {
    const state = initialPreviewState(); state.metricOrder[key] = value;
    assert.throws(() => restorePreviewState(state));
  }
});
