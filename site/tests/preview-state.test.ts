import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { test } from 'node:test';
import { accountFamilies } from '../src/data/accounts.ts';
import { settingGroups, settingsTabs, alertConditions } from '../src/data/settings.ts';
import { providerMetrics, softLimitWindowFor, softLimitWindows } from '../src/data/metrics.ts';
import { initialPreviewState, changePreference, activateAccount, renameAccount, restorePreviewState, previewTime } from '../src/data/preview-state.ts';

test('subscription timer automation defaults on and restores the saved choice', () => {
  const initial = initialPreviewState();
  assert.equal(initial.preferences.autoStartSubscriptionTimers, true);
  const changed = changePreference(initial, 'autoStartSubscriptionTimers', false);
  assert.equal(restorePreviewState(JSON.parse(JSON.stringify(changed))).preferences.autoStartSubscriptionTimers, false);
  assert.equal(restorePreviewState({ preferences: {}, activeAccounts: {} }).preferences.autoStartSubscriptionTimers, true);
});

test('menu bar text options default to metric labels and preserve saved choices', () => {
  const initial = initialPreviewState();
  assert.equal(initial.preferences.menuBarMetricLabels, true);
  assert.equal(initial.preferences.menuBarAccountNames, false);
  const changed = changePreference(changePreference(initial, 'menuBarMetricLabels', false), 'menuBarAccountNames', true);
  const restored = restorePreviewState(JSON.parse(JSON.stringify(changed)));
  assert.equal(restored.preferences.menuBarMetricLabels, false);
  assert.equal(restored.preferences.menuBarAccountNames, true);
  const legacy = restorePreviewState({ preferences: {}, activeAccounts: {} });
  assert.equal(legacy.preferences.menuBarMetricLabels, true);
  assert.equal(legacy.preferences.menuBarAccountNames, false);
});

test('menu bar reset countdown defaults off and restores the saved choice', () => {
  const initial = initialPreviewState();
  assert.equal(initial.preferences.menuBarResetCountdown, false);
  assert.equal(restorePreviewState({ preferences: {}, activeAccounts: {} }).preferences.menuBarResetCountdown, false);
  const enabled = changePreference(initial, 'menuBarResetCountdown', true);
  assert.equal(restorePreviewState(JSON.parse(JSON.stringify(enabled))).preferences.menuBarResetCountdown, true);
});

const source = (path: string): string => readFileSync(new URL(`../../Sources/Egasu/${path}`, import.meta.url), 'utf8');
const englishSource = (path: string): string => source(path)
  .replace(/\bL10n\.\w+\(\s*("(?:\\.|[^"\\])*")\s*\)/g, '$1');

test('Settings follows the native tab order and covers its named sections', () => {
  const cases = source('Stores/PopoverState.swift').match(/enum SettingsTab:[^{]+\{\s*case ([^\n]+)/)?.[1];
  assert.ok(cases);
  assert.deepEqual(settingsTabs.map((tab) => tab.toLowerCase()), cases.split(',').map((name) => name.trim()));
  for (const tab of settingsTabs) {
    const body = englishSource(`Views/Settings/Settings${tab}Tab.swift`);
    const titles = [...body.matchAll(/Section\(\s*"([^"]+)"\s*\)|}\s*header:\s*\{\s*Text\(\s*"([^"]+)"\s*\)/g)]
      .map((match) => match[1] ?? match[2]);
    const groups = settingGroups.filter((group) => group.tab === tab);
    if (tab === 'Display') assert.ok(titles.includes('Menu Bar Icons'));
    for (const title of titles) {
      assert.ok(groups.some((group) => group.title === title), `${tab}: ${title}`);
    }
  }
  assert.ok(!settingGroups.some((group) => group.id === 'accounts'));
});

test('Settings matches native control names within each tab', () => {
  const controlsIn = (view: string) => [...englishSource(`Views/Settings/${view}.swift`)
    .matchAll(/\b(?:Toggle|Picker|SettingsPicker|LabeledContent|levelPicker)\(\s*"([^"]+)"|SettingsTitle\(\s*title:\s*"([^"]+)"/g)]
    .map((match) => match[1] ?? match[2])
    .filter((label) => !label.includes('\\('));
  const sectionsByTab = {
    General: ['LanguageSettingsRow', 'ICloudSyncSettingsSection'],
    Display: [],
    Alerts: [],
    Advanced: [],
    Labs: ['SoftLimitSettingsSection', 'SoftLimitThresholdField', 'TerminalHelperSettingsSection'],
  };
  const alerts = englishSource('Views/Settings/SettingsAlertsTab.swift');
  const conditions = [...alerts.matchAll(/\bconditionRow\(\s*"([^"]+)",\s*info:\s*"[^"]+",\s*shown:\s*\$[\w.]+,/g)];
  assert.deepEqual(conditions.map(([, name]) => name), ['Warning', 'Critical', 'Burning Fast', 'Use It or Lose It']);
  assert.deepEqual(conditions.map(([, name]) => name), alertConditions.map((condition) => condition.label));
  const resetWatchLabel = englishSource('Stores/CodexResetWatchNotificationEvaluator.swift')
    .match(/settingLabel:\s*String\s*\{\s*"([^"]+)"/)?.[1];
  assert.ok(resetWatchLabel);
  assert.match(alerts,
    /Toggle\(isOn:\s*\$notifications\.codexResetWatch\)\s*\{\s*SettingsTitle\(\s*title:\s*CodexResetWatchNotificationEvaluator\.settingLabel\b/);
  const recoveryLabel = englishSource('Support/PaceNotificationLogic.swift').match(/case \.quotaRecovered: return "([^"]+)"/)?.[1];
  assert.ok(recoveryLabel);
  assert.match(alerts, /title: PaceMilestone\.quotaRecovered\.settingLabel/);
  const tokscale = englishSource('Views/Settings/TokscaleSettingsSection.swift');
  assert.match(tokscale, /Text\(\s*"Usage Sync"\s*\)/);
  assert.match(tokscale, /Button\(\s*"Sync"\s*\)\s*\{\s*store\.startSubmit\(\)/);
  for (const tab of settingsTabs) {
    const native = controlsIn(`Settings${tab}Tab`).concat(sectionsByTab[tab].flatMap(controlsIn))
      .filter((label) => !(tab === 'General' && label === 'iCloud Sync'));
    if (tab === 'Alerts') {
      native.push(recoveryLabel, resetWatchLabel, ...conditions.flatMap(([, name]) => [
        `${name}, Show in Priority`, `${name}, Receive Alerts`,
      ]));
    }
    if (tab === 'Advanced') native.push('Usage Sync');
    const preview = settingGroups.filter((group) => group.tab === tab)
      .flatMap((group) => group.rows.map((row) => row.label)).filter(Boolean);
    assert.deepEqual(preview.sort(), native.sort(), tab);
  }
});

test('Labs contains the same feature groups as the native app', () => {
  const labs = englishSource('Views/Settings/SettingsLabsTab.swift');
  const groups = settingGroups.filter((group) => group.tab === 'Labs');
  assert.deepEqual(groups.map((group) => group.title), ['Soft Limit', 'Command Line']);
  assert.match(labs, /SoftLimitSettingsSection\(/);
  assert.match(labs, /TerminalHelperSettingsSection\(/);
  const helper = englishSource('Views/Settings/TerminalHelperSettingsSection.swift');
  for (const label of ['Install…', 'Uninstall', 'Unavailable']) assert.ok(helper.includes(`"${label}"`), label);
});

test('Alerts, Soft Limit, and Tokscale expose their preview controls', () => {
  const expectedRows = {
    thresholds: { tab: 'Alerts', rows: { warning: 'picker', critical: 'picker' } },
    conditions: { tab: 'Alerts', rows: {
      showWarning: 'toggle',
      warningNotification: 'toggle',
      showCritical: 'toggle',
      criticalNotification: 'toggle',
      showBurningFast: 'toggle',
      closeToRunningOut: 'toggle',
      showUseItOrLoseIt: 'toggle',
      useItOrLoseItNotification: 'toggle',
    } },
    notifications: { tab: 'Alerts', rows: { quotaRecovered: 'toggle', codexResetWatch: 'toggle' } },
    softLimit: { tab: 'Labs', rows: { softLimitEnabled: 'toggle', softLimitWindow: 'picker', softLimitThreshold: 'number', softLimitCommands: 'action' } },
    tokscale: { tab: 'Advanced', rows: { usageSync: 'action' } },
  };
  for (const [groupId, { tab, rows }] of Object.entries(expectedRows)) {
    const group = settingGroups.find((group) => group.id === groupId);
    assert.ok(group, groupId);
    assert.equal(group.tab, tab, groupId);
    for (const [id, kind] of Object.entries(rows)) {
      assert.equal(group.rows.find((row) => row.id === id)?.control.kind, kind, id);
    }
  }
  const softLimit = settingGroups.find((group) => group.id === 'softLimit');
  for (const id of ['softLimitWindow', 'softLimitThreshold', 'softLimitCommands']) {
    assert.equal(softLimit?.rows.find((row) => row.id === id)?.requires, 'softLimitEnabled', id);
  }
});

test('Soft Limit preserves its threshold, rejects invalid percentages, and defaults to off', () => {
  const initial = initialPreviewState();
  assert.equal(initial.preferences.softLimitEnabled, false);
  assert.equal(initial.preferences.softLimitWindow, 'Weekly and Monthly');
  assert.equal(initial.preferences.softLimitThreshold, '90');
  const window = settingGroups.flatMap((group) => group.rows).find((row) => row.id === 'softLimitWindow')!.control;
  assert.deepEqual(window.kind === 'picker' && window.options, ['Weekly and Monthly', 'Weekly', 'Monthly']);
  assert.throws(() => changePreference(initial, 'softLimitWindow', '5 Hours'));
  const changed = changePreference(initial, 'softLimitThreshold', '95');
  assert.equal(restorePreviewState(changed).preferences.softLimitThreshold, '95');
  for (const invalid of ['0', '101', '-1', '90.5', '', 'abc']) {
    assert.throws(() => changePreference(changed, 'softLimitThreshold', invalid));
  }
  assert.equal(initial.preferences.codexResetWatch, false);
});

test('Soft Limit migrates the retired session window and preserves saved subscription windows', () => {
  for (const [stored, expected] of [
    ['5 Hours', 'Weekly and Monthly'], ['Weekly', 'Weekly'], ['Monthly', 'Monthly'],
    ['Weekly and Monthly', 'Weekly and Monthly'],
  ]) {
    for (const enabled of [true, false]) {
      const state = restorePreviewState({
        preferences: { softLimitWindow: stored, softLimitEnabled: enabled, softLimitThreshold: '78', betaUpdates: true },
        activeAccounts: {},
      });
      assert.equal(state.preferences.softLimitWindow, expected);
      assert.equal(state.preferences.softLimitEnabled, enabled);
      assert.equal(state.preferences.softLimitThreshold, '78');
      assert.deepEqual(restorePreviewState(state).preferences, state.preferences);
    }
  }
});

test('beta opt-out clears only Soft Limit consent, including previously stored settings', () => {
  const initial = initialPreviewState();
  const enabled = changePreference(changePreference(initial, 'betaUpdates', true), 'softLimitEnabled', true);
  const configured = changePreference(changePreference(enabled, 'softLimitWindow', 'Monthly'), 'softLimitThreshold', '82');
  const installed = { ...configured, terminalHelperInstalled: true };
  const disabled = changePreference(installed, 'betaUpdates', false);
  assert.equal(disabled.preferences.softLimitEnabled, false);
  assert.equal(disabled.preferences.softLimitWindow, 'Monthly');
  assert.equal(disabled.preferences.softLimitThreshold, '82');
  assert.equal(disabled.terminalHelperInstalled, true);
  assert.equal(changePreference(disabled, 'betaUpdates', true).preferences.softLimitEnabled, false);
  for (const betaUpdates of [true, false]) {
    for (const preferences of [{ betaUpdates, softLimitEnabled: true }, { softLimitEnabled: true, betaUpdates }]) {
      const restored = restorePreviewState({ ...initial, preferences, terminalHelperInstalled: true });
      assert.equal(restored.preferences.softLimitEnabled, betaUpdates);
      assert.equal(restored.terminalHelperInstalled, true);
    }
  }
  const legacy = restorePreviewState({ preferences: { softLimitEnabled: true }, activeAccounts: {} });
  assert.equal(legacy.preferences.softLimitEnabled, false);
  assert.equal(legacy.terminalHelperInstalled, false);
});

const antigravityConstants = Object.fromEntries([...source('Providers/Antigravity/AntigravityMetric.swift')
  .matchAll(/static let (\w+) = "([^"]+)"/g)].map(([, key, value]) => [`AntigravityMetric.${key}`, value]));

test('the preview lists every Antigravity and Kimi widget in native declaration order', () => {
  for (const provider of ['Antigravity', 'Kimi']) {
    const descriptors = source(`Providers/${provider}/${provider}Provider.swift`)
      .match(/var widgetDescriptors: \[WidgetDescriptor\] \{([\s\S]*?)\n    \}/)?.[1];
    assert.ok(descriptors, provider);
    const native = [...descriptors.matchAll(/\bid:\s*("[^"]+"|AntigravityMetric\.\w+)/g)]
      .map(([, id]) => id.startsWith('"') ? id.slice(1, -1) : antigravityConstants[id]);
    assert.deepEqual(providerMetrics[provider.toLowerCase()].rows.map((row) => row.id), native, provider);
  }
});

test('Soft Limit requires a supported subscription meter and the matching reported cycle', () => {
  const week = 7 * 24;
  for (const hours of [28 * 24, 29 * 24, 30 * 24 - 1, 31 * 24 + 1]) {
    assert.equal(softLimitWindowFor('cursor.usage', hours), 'Monthly');
    assert.equal(softLimitWindowFor('kiro.credits', hours), 'Monthly');
  }
  for (const hours of [week - 1, week, week + 1]) {
    assert.equal(softLimitWindowFor('cursor.usage', hours), 'Weekly');
  }
  assert.equal(softLimitWindowFor('kimi.total', undefined), 'Monthly');
  assert.equal(softLimitWindowFor('kimi.total', 5), undefined);
  assert.equal(softLimitWindowFor('cursor.usage', undefined), undefined);
  assert.equal(softLimitWindowFor('kiro.credits', week), undefined);
  for (const hours of [5, 24, week - 2, week + 2, 28 * 24 - 2, 31 * 24 + 2, 90 * 24]) {
    assert.equal(softLimitWindowFor('cursor.usage', hours), undefined);
  }
  for (const metric of ['codex.session', 'claude.last30', 'openrouter.month', 'codex.resetWatch']) {
    assert.equal(softLimitWindowFor(metric, 30 * 24), undefined);
  }
});

test('Soft Limit windows match every native provider declaration', () => {
  const native: Record<string, string[]> = {};
  const files = readdirSync(new URL('../../Sources/Egasu/Providers/', import.meta.url), { recursive: true, encoding: 'utf8' })
    .filter((path) => path.endsWith('Provider.swift'));
  for (const file of files) {
    const family = file.split('/')[0].toLowerCase();
    let metric: string | undefined;
    for (const match of source(`Providers/${file}`).matchAll(/\bid:\s*("[^"]+"|AntigravityMetric\.\w+)|\.supportingSoftLimit\(([^)]+)\)/g)) {
      if (match[1]) {
        metric = match[1].startsWith('"') ? match[1].slice(1, -1).replace('\\(provider.id)', family) : antigravityConstants[match[1]];
      } else {
        assert.ok(metric, `The native metric ID must be resolved in ${file}`);
        const windows = [...match[2].matchAll(/\.(\w+)/g)].map(([, window]) => {
          assert.ok(window === 'weekly' || window === 'monthly', `Unexpected quota period in ${file}: ${window}`);
          return window === 'weekly' ? 'Weekly' : 'Monthly';
        });
        assert.ok(windows.length, `Missing quota period in ${file}`);
        native[metric] = windows;
      }
    }
  }
  assert.ok(Object.values(native).flat().includes('Weekly'));
  assert.ok(Object.values(native).flat().includes('Monthly'));
  assert.deepEqual(softLimitWindows, native);
});

test('Settings includes the native Log Level options and app actions', () => {
  const expected = [...englishSource('Stores/LogLevelSetting.swift').matchAll(/case \.\w+: "([^"]+)"/g)].map((match) => match[1]);
  assert.equal(expected.length, 4, 'Every native log level must be checked');
  const logLevel = settingGroups.flatMap((group) => group.rows).find((row) => row.id === 'logLevel')!.control;
  assert.equal(logLevel.kind, 'picker');
  if (logLevel.kind === 'picker') assert.deepEqual(logLevel.options, expected);
  const actions = settingGroups.flatMap((group) => group.rows).flatMap((row) => row.control.kind === 'action' ? [row.control.label] : []);
  for (const action of ['Record Shortcut', 'Sync', 'Copy Log Path', 'Reveal in Finder', 'Check for Updates…']) assert.ok(actions.includes(action), action);
});

test('Language offers the three app languages and starts in English', () => {
  const control = settingGroups.flatMap((group) => group.rows).find((row) => row.id === 'language')!.control;
  assert.equal(control.kind, 'picker');
  if (control.kind !== 'picker') return;
  assert.deepEqual(control.options, ['English', '한국어', '日本語']);
  assert.equal(initialPreviewState().preferences.language, 'English');
  for (const language of control.options) {
    const changed = changePreference(initialPreviewState(), 'language', language);
    assert.equal(restorePreviewState(JSON.parse(JSON.stringify(changed))).preferences.language, language);
  }
  assert.equal(settingGroups[0].title, 'General');
  assert.throws(() => changePreference(initialPreviewState(), 'language', 'System'));
  const oldState = initialPreviewState();
  delete oldState.preferences.language;
  assert.equal(restorePreviewState(oldState).preferences.language, 'English');
});

test('public account examples are shared, generic, and have one active account', () => {
  for (const family of accountFamilies) {
    assert.ok(family.profiles.every((profile) => /^Account \d+$/.test(profile.name)));
    assert.equal(family.profiles.filter((profile) => profile.id === family.activeAccount).length, 1);
  }
});

test('both accounts remain registered when the active account changes', () => {
  const initial = initialPreviewState();
  const switched = activateAccount(initial, 'codex', 'account-2');
  assert.equal(switched.activeAccounts.codex, 'account-2');
  assert.equal(switched.activeAccounts.claude, 'account-1');
  assert.deepEqual(switched.accountOrder.codex, ['account-1', 'account-2']);
  assert.deepEqual(restorePreviewState(JSON.parse(JSON.stringify(switched))), switched);
});

test('swapped account names restore regardless of saved entry order', () => {
  let state = changePreference(initialPreviewState(), 'theme', 'Dark');
  state = renameAccount(state, 'claude', 'account-1', 'Temporary');
  state = renameAccount(state, 'claude', 'account-2', 'Account 1');
  state = renameAccount(state, 'claude', 'account-1', 'Account 2');
  assert.deepEqual(restorePreviewState(JSON.parse(JSON.stringify(state))), state);
  const reversed = { ...state, accountNames: Object.fromEntries(Object.entries(state.accountNames).reverse()) };
  assert.deepEqual(restorePreviewState(JSON.parse(JSON.stringify(reversed))), state);
});

test('restored account names keep normalization and reject final name conflicts', () => {
  const state = initialPreviewState();
  const restored = restorePreviewState({ ...state, accountNames: {
    'claude:account-1': ' Account 2 ', 'claude:account-2': ' ', 'codex:account-1': 'Work',
  } });
  assert.deepEqual(restored.accountNames, {
    'claude:account-1': 'Account 2', 'claude:account-2': 'claude.account-2@example.com', 'codex:account-1': 'Work',
  });
  for (const accountNames of [
    { 'claude:account-1': 'Account 2' },
    { 'claude:account-1': 'Work', 'claude:account-2': 'Work' },
    { 'claude:account-1': 'Work', 'claude:account-2': ' work ' },
    { 'claude:account-1': 'claude.account-2@example.com', 'claude:account-2': '' },
  ]) {
    assert.throws(() => restorePreviewState({ ...state, accountNames }), /already in use/);
  }
});

test('canonically equivalent account names conflict during rename and restore', () => {
  const decomposed = 'E\u0301quipe';
  const state = renameAccount(initialPreviewState(), 'claude', 'account-1', decomposed);
  assert.equal(restorePreviewState(state).accountNames['claude:account-1'], decomposed);
  assert.throws(() => renameAccount(state, 'claude', 'account-2', 'équipe'), /already in use/);
  assert.throws(() => restorePreviewState({
    ...state, accountNames: { ...state.accountNames, 'claude:account-2': 'équipe' },
  }), /already in use/);
});

test('rename and restore reject control characters but keep valid joined names', () => {
  const initial = initialPreviewState();
  const key = 'claude:account-1';
  for (const name of ['Ops\u0000Team', 'Ops\tTeam', 'Ops\u0085Team', '\tOps', 'Ops\n', '\t']) {
    assert.throws(() => renameAccount(initial, 'claude', 'account-1', name), /control characters/);
    assert.throws(() => restorePreviewState({ ...initial, accountNames: { [key]: name } }), /control characters/);
  }

  const name = '팀 👩\u200d💻';
  const renamed = renameAccount(initial, 'claude', 'account-1', `  ${name}  `);
  assert.equal(renamed.accountNames[key], name);
  assert.equal(restorePreviewState({ ...initial, accountNames: { [key]: `  ${name}  ` } }).accountNames[key], name);
  assert.equal(renameAccount(initial, 'claude', 'account-1', '  ').accountNames[key], 'claude.account-1@example.com');
});

test('saved account order only accepts registered provider families', () => {
  const initial = initialPreviewState();
  const accountOrder = { ...initial.accountOrder, claude: ['account-2', 'account-1'] };
  assert.deepEqual(restorePreviewState({ ...initial, accountOrder }).accountOrder, accountOrder);
  for (const family of ['toString', 'valueOf', '__proto__']) {
    assert.throws(() => restorePreviewState({
      ...initial, accountOrder: { ...accountOrder, [family]: [] },
    }), /Invalid preview account order/);
  }
});

test('obsolete presentation settings migrate while supported preferences survive', () => {
  const restored = restorePreviewState({
    preferences: {
      usageCards: 'Single Card', density: 'Default', increaseTransparency: true,
      theme: 'Dark', showUsageAs: 'Left', allUsageLayout: 'Cards',
      alwaysShowPacing: true, hideFromScreenShare: true, useItOrLoseIt: true,
      underTenPercent: true, healthyToClose: true,
    },
    activeAccounts: { claude: 'account-2' }, viewedAccounts: { claude: 'account-1' },
  });
  assert.equal(restored.preferences.usageCards, undefined);
  assert.equal(restored.preferences.density, undefined);
  assert.equal(restored.preferences.increaseTransparency, undefined);
  assert.equal(restored.preferences.paceMarks, true);
  assert.equal(restored.preferences.privacyMode, true);
  assert.equal(restored.preferences.useItOrLoseItNotification, true);
  assert.equal(restored.preferences.criticalNotification, true);
  assert.equal(restored.preferences.warningNotification, true);
  assert.equal(restored.preferences.theme, 'Dark');
  assert.equal(restored.preferences.showUsageAs, 'Left');
  assert.equal(restored.activeAccounts.claude, 'account-2');
  assert.equal(restored.preferences.allUsageLayout, 'Cards');
  assert.deepEqual(restorePreviewState(JSON.parse(JSON.stringify(restored))), restored);
  assert.throws(() => changePreference(restored, 'allUsageLayout', 'Compact'));
});

test('invalid stored values cannot inject settings or select unknown accounts', () => {
  const state = initialPreviewState();
  assert.throws(() => changePreference(state, 'theme', 'Rainbow'));
  assert.throws(() => changePreference(state, 'showTotalSpend', 'false'));
  assert.throws(() => changePreference(state, 'usageSync', true));
  assert.throws(() => activateAccount(state, 'codex', 'company'));
  assert.throws(() => restorePreviewState([]));
  assert.throws(() => restorePreviewState({ ...state, preferences: { ...state.preferences, theme: 'invalid' } }));
  for (const accountNames of [
    { 'claude:unknown': 'Work' }, { 'unknown:account-1': 'Work' }, { 'claude:account-1:extra': 'Work' },
    { 'claude:account-1': false }, { 'claude:account-1': 'x'.repeat(61) },
    { 'claude:account-1': 'Work/Home' }, { 'claude:account-1': 'Work\\Home' },
  ]) {
    assert.throws(() => restorePreviewState({ ...state, accountNames }));
  }
});

test('time formatting handles noon, midnight, dates, and system preference', () => {
  assert.equal(previewTime('Resets Sep 15 at 00:05', '12-hour', false), 'Resets Sep 15 at 12:05 AM');
  assert.equal(previewTime('Limit today at 12:30', '12-hour', false), 'Limit today at 12:30 PM');
  assert.equal(previewTime('Resets today at 18:20', 'Auto', true), 'Resets today at 6:20 PM');
  assert.equal(previewTime('Resets today at 18:20', 'Auto', false), 'Resets today at 18:20');
  assert.equal(previewTime('Resets in 5h 12m', '12-hour', true), 'Resets in 5h 12m');
});
