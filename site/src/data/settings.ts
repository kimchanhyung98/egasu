export const languageTags: Record<string, string> = { English: 'en', 한국어: 'ko', 日本語: 'ja' };
export const settingsTabs = ['General', 'Display', 'Alerts', 'Advanced'] as const;
export type SettingsTab = typeof settingsTabs[number];

export type Control =
  | { kind: 'toggle'; on: boolean }
  | { kind: 'number'; value: string; min: number; max: number }
  | { kind: 'picker'; value: string; options: string[] }
  | { kind: 'action'; label: string; message: string };

export interface SettingRow {
  id: string;
  label: string;
  control: Control;
  note?: string;
  info?: string;
  requires?: string;
}

export interface SettingGroup {
  id: string;
  title: string;
  tab: SettingsTab;
  rows: SettingRow[];
}

export const alertConditions = [
  { label: 'Warning', notify: 'warningNotification' },
  { label: 'Critical', notify: 'criticalNotification' },
  { label: 'Burning Fast', shown: 'showBurningFast', notify: 'closeToRunningOut' },
  { label: 'Use It or Lose It', shown: 'showUseItOrLoseIt', notify: 'useItOrLoseItNotification' },
];

// 현재 앱의 네 탭 구성. 시스템 작업은 Mac 앱에서 수행하도록 안내.
export const settingGroups: SettingGroup[] = [
  { id: 'general', title: 'General', tab: 'General', rows: [
    { id: 'launchAtLogin', label: 'Launch at Login', control: { kind: 'toggle', on: false } },
    { id: 'defaultTab', label: 'Default Tab', control: { kind: 'picker', value: 'Priority', options: ['Priority', 'All Usage'] } },
    { id: 'globalShortcut', label: 'Global Shortcut', info: 'Open egasu from anywhere',
      control: { kind: 'action', label: 'Record Shortcut', message: 'Record a global shortcut in the Mac app.' } },
    { id: 'language', label: 'Language', control: { kind: 'picker', value: 'English', options: ['English', '한국어', '日本語'] },
      note: 'This preview changes language immediately. The Mac app applies it after restarting.' },
  ] },
  { id: 'appearance', title: 'Appearance', tab: 'General', rows: [
    { id: 'theme', label: 'Theme', control: { kind: 'picker', value: 'System', options: ['System', 'Light', 'Dark'] } },
    { id: 'timeFormat', label: 'Time Format', control: { kind: 'picker', value: '24-hour', options: ['Auto', '12-hour', '24-hour'] } },
  ] },
  { id: 'icloud', title: 'iCloud Sync', tab: 'General', rows: [
    { id: 'syncAcrossMacs', label: 'Sync Across Macs', control: { kind: 'toggle', on: false },
      info: 'Shares usage history through iCloud, so you can see one combined summary for all your Macs.' },
  ] },
  { id: 'updates', title: 'Updates', tab: 'General', rows: [
    { id: 'updateAutomatically', label: 'Check Automatically', control: { kind: 'toggle', on: true } },
    { id: 'betaUpdates', label: 'Beta Updates', control: { kind: 'toggle', on: false },
      info: 'Receive pre-release builds before they ship to everyone' },
    { id: 'checkForUpdates', label: '', control: { kind: 'action', label: 'Check for Updates…', message: 'Check for signed app updates in the Mac app.' } },
  ] },
  { id: 'menuBar', title: 'Menu Bar Icons', tab: 'Display', rows: [
    { id: 'iconStyle', label: 'Icon Style', control: { kind: 'picker', value: 'Text', options: ['Text', 'Bars'] } },
    { id: 'menuBarLimit', label: 'Max Items In Menu Bar', control: { kind: 'picker', value: 'Up to 3', options: ['App Icon Only', 'Up to 1', 'Up to 2', 'Up to 3', 'Up to 4', 'Up to 5'] } },
    { id: 'menuBarItems', label: 'Menu Bar Items', control: { kind: 'picker', value: 'Running Out', options: ['Running Out', 'Priority', 'Pinned Only'] } },
    { id: 'menuBarExtras', label: 'Show Extra Indicators', control: { kind: 'toggle', on: true }, info: 'Show the +N count and update indicator in the menu bar' },
  ] },
  { id: 'layout', title: 'Appearance', tab: 'Display', rows: [
    { id: 'allUsageLayout', label: 'All Usage Layout', control: { kind: 'picker', value: 'Minimal', options: ['Minimal', 'Cards'] } },
  ] },
  { id: 'usageDisplay', title: 'Usage', tab: 'Display', rows: [
    { id: 'showUsageAs', label: 'Show Usage As', control: { kind: 'picker', value: 'Used', options: ['Used', 'Left'] } },
    { id: 'resetTimes', label: 'Reset Times', control: { kind: 'picker', value: 'Exact Time', options: ['Countdown', 'Exact Time'] } },
    { id: 'paceMarks', label: 'Pace Marks', control: { kind: 'toggle', on: false }, info: 'Where usage would be at an even pace' },
    { id: 'showTotalSpend', label: 'Show Total Spend', control: { kind: 'toggle', on: true }, info: 'Combined spend across your providers at the top of the dashboard' },
  ] },
  { id: 'thresholds', title: 'Thresholds', tab: 'Alerts', rows: [
    { id: 'warning', label: 'Warning', control: { kind: 'picker', value: '30% left', options: Array.from({ length: 11 }, (_, i) => `${70 - i * 5}% left`) }, info: 'When a limit turns into a priority' },
    { id: 'critical', label: 'Critical', control: { kind: 'picker', value: '10% left', options: ['25% left', '20% left', '15% left', '10% left', '5% left'] }, info: 'When a limit turns critically low' },
  ] },
  { id: 'conditions', title: 'Condition', tab: 'Alerts', rows: alertConditions.flatMap((condition): SettingRow[] => [
    ...(condition.shown ? [{ id: condition.shown, label: `${condition.label}, Show in Priority`, control: { kind: 'toggle' as const, on: true } }] : []),
    { id: condition.notify, label: `${condition.label}, Receive Alerts`, control: { kind: 'toggle', on: false } },
  ]) },
  { id: 'notifications', title: 'Other Notifications', tab: 'Alerts', rows: [
    { id: 'codexResetWatch', label: 'Codex Reset Watch', control: { kind: 'toggle', on: false }, info: 'Alert when Reset Watch expects Codex limits to reset soon' },
  ] },
  { id: 'privacy', title: 'Privacy', tab: 'Advanced', rows: [
    { id: 'privacyMode', label: 'Privacy Mode', control: { kind: 'toggle', on: false },
      info: 'Hides dashboard account names and disables renaming. Dashboard account actions show masked emails. Accounts stays visible and editable. During screen sharing or recording, the menu bar shows only the egasu icon.' },
    { id: 'shareAnonymousUsage', label: 'Share Anonymous Usage', control: { kind: 'toggle', on: false },
      info: 'Shares anonymous usage counts and error types to help improve egasu. No account details, credentials, or usage values are sent.' },
  ] },
  { id: 'tokscale', title: 'Tokscale', tab: 'Advanced', rows: [
    { id: 'usageSync', label: 'Usage Sync', control: { kind: 'action', label: 'Sync', message: 'Publish usage to your Tokscale profile from the Mac app. This preview does not upload data.' }, info: 'Sync local usage to your public Tokscale profile.' },
  ] },
  { id: 'softLimit', title: 'Soft Limit', tab: 'Advanced', rows: [
    { id: 'softLimitEnabled', label: 'Enabled', control: { kind: 'toggle', on: false } },
    { id: 'softLimitWindow', label: 'Window', requires: 'softLimitEnabled', control: { kind: 'picker', value: 'Weekly', options: ['5 Hours', 'Weekly'] } },
    { id: 'softLimitThreshold', label: 'Threshold', requires: 'softLimitEnabled', control: { kind: 'number', value: '90', min: 1, max: 100 } },
  ] },
  { id: 'debug', title: 'Debug', tab: 'Advanced', rows: [
    { id: 'logLevel', label: 'Log Level', control: { kind: 'picker', value: 'Info', options: ['Error', 'Warning', 'Info', 'Debug'] }, info: 'How much detail egasu writes to its log file. Choose Debug while you reproduce a problem.' },
    { id: 'copyLogPath', label: '', control: { kind: 'action', label: 'Copy Log Path', message: 'Copy the actual log file path from Settings → Advanced in the Mac app.' } },
    { id: 'revealLog', label: '', control: { kind: 'action', label: 'Reveal in Finder', message: 'Reveal the app log in Finder from the Mac app.' } },
  ] },
];
