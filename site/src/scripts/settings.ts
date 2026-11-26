import { accountFamilies } from '../data/accounts';
import { initialPreviewState, changePreference, activateAccount, restorePreviewState, previewTime, accountName, accountEmail, renameAccount, type PreviewState } from '../data/preview-state';
import { menuBarUsesText, softLimitAccountStatuses } from '../data/preview-dashboard';
import { languageTags } from '../data/settings';
import { closeMenu } from './menus';
import { applyPreviewLanguage, localizePreview, previewAccountDisplayName, setPreviewAccountText } from './localization';

const STORAGE_KEY = 'openusage.site.preview.v1';
let state = initialPreviewState();
let render = (): void => {};
let notify = (_mock: HTMLElement, _message: string): void => {};
let verifyingTerminalHelper = false;
const pending = new WeakMap<HTMLElement, { family: string; id: string; button: HTMLElement }>();
const notificationPreferences = ['warningNotification', 'criticalNotification', 'closeToRunningOut', 'useItOrLoseItNotification', 'weeklyMonthlyResetReminders', 'quotaRecovered', 'codexCreditExpiry', 'codexResetWatch'];
const appOnlyPreferences = new Set([
  'launchAtLogin', 'autoStartSubscriptionTimers', ...notificationPreferences, 'shareAnonymousUsage', 'updateAutomatically', 'betaUpdates', 'logLevel',
]);

function report(error: unknown, message: string): void {
  console.warn(message, error);
  const mock = document.querySelector<HTMLElement>('[data-mock]');
  if (mock) notify(mock, message);
}

function save(): void {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(state)); }
  catch (error) { report(error, 'Preview changes could not be saved. They will last until you reload.'); }
}

export function previewState(): PreviewState { return state; }
export function previewPreference(id: string): string | boolean { return state.preferences[id]; }

export function updatePreviewState(next: PreviewState): void {
  state = next;
  render();
  save();
}

export function renamePreviewAccount(family: string, id: string, value: string): void {
  updatePreviewState(renameAccount(state, family, id, value,
    (otherID) => previewAccountDisplayName(state, family, otherID).displayed));
}

export function setPreviewPreference(id: string, value: string | boolean): void {
  const next = changePreference(state, id, value);
  if (id === 'defaultTab') document.querySelectorAll<HTMLElement>('[data-mock]').forEach((mock) => { mock.dataset.dashboardTab = String(value); });
  updatePreviewState(next);
}

export function choosePreviewSetting(mock: HTMLElement, id: string, value: string): void {
  setPreviewPreference(id, value);
  if (appOnlyPreferences.has(id)) notify(mock, 'Preview value changed. Apply this setting in the Mac app.');
}

function closeAccountDialog(mock: HTMLElement): void {
  const previous = pending.get(mock);
  mock.querySelector<HTMLDialogElement>('[data-account-dialog]')?.close();
  pending.delete(mock);
  previous?.button.focus({ preventScroll: true });
}

export function handleSettingsClick(target: Element, mock: HTMLElement): boolean {
  if (target.closest('[data-terminal-helper]')) {
    if (!state.preferences.betaUpdates || verifyingTerminalHelper) return true;
    if (state.terminalHelperInstalled) {
      mock.querySelector<HTMLDialogElement>('[data-remove-helper-dialog]')!.showModal();
    } else {
      verifyingTerminalHelper = true;
      updatePreviewState({ ...state, terminalHelperInstalled: true });
      window.setTimeout(() => { verifyingTerminalHelper = false; render(); }, 1000);
    }
    return true;
  }
  if (target.closest('[data-helper-confirm]')) {
    if (state.preferences.betaUpdates) updatePreviewState({ ...state, terminalHelperInstalled: false });
    return true;
  }
  const native = target.closest<HTMLElement>('[data-native-action]');
  if (native) {
    const menu = native.closest<HTMLElement>('[role="menu"]');
    if (menu) closeMenu(menu);
    notify(mock, native.dataset.nativeAction ?? 'Open the Mac app to use this feature.');
    return true;
  }
  if (target.closest('[data-soft-cancel], [data-soft-confirm]')) {
    if (target.closest('[data-soft-confirm]')) setPreviewPreference('softLimitEnabled', true);
    mock.querySelector<HTMLDialogElement>('[data-soft-limit-dialog]')!.close();
    mock.querySelector<HTMLElement>('[data-setting="softLimitEnabled"]')?.focus({ preventScroll: true });
    return true;
  }
  if (target.closest('[data-account-cancel]')) { closeAccountDialog(mock); return true; }
  if (target.closest('[data-account-confirm]')) {
    const selection = pending.get(mock);
    if (selection) {
      updatePreviewState(activateAccount(state, selection.family, selection.id));
      closeAccountDialog(mock);
    }
    return true;
  }
  const accountSwitch = target.closest<HTMLButtonElement>('[data-account-switch]');
  if (accountSwitch) {
    const family = accountSwitch.dataset.accountSwitch!;
    const id = accountSwitch.dataset.accountId!;
    if (state.activeAccounts[family] === id || accountSwitch.disabled) return true;
    const dialog = mock.querySelector<HTMLDialogElement>('[data-account-dialog]')!;
    const menu = accountSwitch.closest<HTMLElement>('.am-account-actions');
    const trigger = menu?.closest('.am-section')?.querySelector<HTMLElement>('[data-account-actions-trigger]') ?? accountSwitch;
    if (menu) closeMenu(menu);
    pending.set(mock, { family, id, button: trigger });
    const masked = state.preferences.privacyMode === true && trigger.closest('[data-scr="dashboard"]') !== null;
    const display = masked
      ? { name: accountEmail(family, id).replace(/^[^@]+/, '••••'), literal: true }
      : previewAccountDisplayName(state, family, id);
    setPreviewAccountText(
      dialog.querySelector<HTMLElement>('[data-account-confirm-text]')!,
      (name) => `Use ${name} in this demo? Your Mac’s sign-in will stay unchanged.`,
      display.name, display.literal,
    );
    localizePreview(mock);
    dialog.showModal();
    return true;
  }
  const toggle = target.closest<HTMLButtonElement>('button[data-setting]');
  if (toggle) {
    if (toggle.disabled) return true;
    const id = toggle.dataset.setting!;
    if (id === 'softLimitEnabled' && !state.preferences[id]) {
      mock.querySelector<HTMLDialogElement>('[data-soft-limit-dialog]')!.showModal();
      return true;
    }
    setPreviewPreference(id, !state.preferences[id]);
    if (appOnlyPreferences.has(id)) notify(mock, 'Preview value changed. Apply this setting in the Mac app.');
    return true;
  }
  return false;
}

export function applySettingsToMock(mock: HTMLElement): void {
  const preferences = state.preferences;
  mock.dataset.theme = preferences.theme === 'Dark' || (preferences.theme === 'System' && matchMedia('(prefers-color-scheme: dark)').matches) ? 'dark' : 'light';
  mock.dataset.mode = preferences.showUsageAs === 'Left' ? 'left' : 'used';
  mock.dataset.reset = preferences.resetTimes === 'Countdown' ? 'relative' : 'absolute';
  mock.dataset.pacing = String(preferences.paceMarks);
  mock.dataset.layout = String(preferences.allUsageLayout).toLowerCase();
  mock.dataset.privacy = String(preferences.privacyMode);
  mock.dataset.softLimit = preferences.softLimitEnabled ? String(preferences.softLimitWindow) : 'off';
  const threshold = Number(preferences.softLimitThreshold);
  const leftMode = mock.dataset.mode === 'left';
  mock.style.setProperty('--soft-limit-used', `${threshold}%`);
  mock.style.setProperty('--soft-limit-left', `${100 - threshold}%`);
  mock.querySelectorAll<HTMLElement>('[data-soft-fill]').forEach((guide) => {
    const used = Number(guide.dataset.softFill);
    const fill = leftMode ? 100 - used : used;
    guide.toggleAttribute('data-on-fill', fill > 0 && fill >= (leftMode ? 100 - threshold : threshold));
  });
  mock.querySelectorAll<HTMLElement>('[data-requires]').forEach((element) => { element.hidden = !preferences[element.dataset.requires!]; });
  const statusList = mock.querySelector<HTMLElement>('[data-soft-statuses]');
  if (statusList && preferences.softLimitEnabled) {
    const rows = softLimitAccountStatuses(state).map((status) => {
      const row = document.createElement('div');
      const title = document.createElement('strong');
      title.textContent = status.name;
      if (status.accountID) {
        const account = previewAccountDisplayName(state, status.provider, status.accountID);
        const name = document.createElement('span');
        setPreviewAccountText(name, (value) => value, account.name, account.literal);
        title.append(' — ', name);
      }
      const detail = document.createElement('span');
      detail.textContent = status.message;
      row.append(title, detail);
      return row;
    });
    statusList.replaceChildren(...rows);
    mock.querySelector<HTMLElement>('[data-soft-empty]')!.hidden = rows.length > 0;
    mock.querySelector<HTMLElement>('[data-soft-cancellation]')!.hidden = !rows.length;
  }
  const helper = mock.querySelector<HTMLButtonElement>('[data-terminal-helper]');
  if (helper) {
    helper.textContent = verifyingTerminalHelper ? 'Verifying…' : state.terminalHelperInstalled ? 'Uninstall' : 'Install…';
    helper.disabled = verifyingTerminalHelper;
  }
  if (!preferences.betaUpdates) {
    mock.querySelectorAll<HTMLDialogElement>('[data-soft-limit-dialog][open], [data-remove-helper-dialog][open]')
      .forEach((dialog) => dialog.close());
  }
  mock.querySelectorAll<HTMLInputElement>('[data-number-setting]').forEach((input) => { input.value = String(preferences[input.dataset.numberSetting!]); });
  mock.querySelectorAll<HTMLButtonElement>('[data-setting]').forEach((button) => {
    const id = button.dataset.setting!;
    const on = preferences[id] === true;
    if (id === 'menuBarMetricLabels' || id === 'menuBarAccountNames' || id === 'menuBarResetCountdown') {
      button.disabled = !menuBarUsesText(state);
    }
    button.classList.toggle('is-on', on);
    button.setAttribute('aria-checked', String(on));
  });
  mock.querySelectorAll<HTMLButtonElement>('[data-picker]').forEach((button) => {
    const id = button.dataset.picker!;
    const value = preferences[id];
    const label = button.querySelector('[data-picker-value]');
    if (label) {
      label.textContent = String(value);
      if (id === 'language') label.setAttribute('lang', languageTags[String(value)]);
    }
    if (id === 'iconStyle' || id === 'menuBarItems') button.disabled = preferences.menuBarLimit === 'App Icon Only';
    mock.querySelectorAll<HTMLElement>(`[data-pick="${id}"]`).forEach((option) => { option.setAttribute('aria-checked', String(option.dataset.value === value)); });
  });
  mock.querySelectorAll<HTMLButtonElement>('[data-account-switch]').forEach((button) => {
    const family = button.dataset.accountSwitch!;
    const id = button.dataset.accountId!;
    const on = state.activeAccounts[family] === id;
    const provider = accountFamilies.find((entry) => entry.id === family)!;
    const menuItem = button.getAttribute('role') === 'menuitem';
    const ready = provider.profiles.find((account) => account.id === id)?.status === 'Ready';
    button.disabled = !ready || (menuItem && on);
    if (menuItem) {
      const masked = preferences.privacyMode === true;
      const display = masked
        ? { name: accountEmail(family, id).replace(/^[^@]+/, '••••'), literal: true }
        : previewAccountDisplayName(state, family, id);
      setPreviewAccountText(
        button, (name) => `Use ${provider.name}: ${name}`, display.name, display.literal,
      );
    } else {
      button.classList.toggle('is-on', on);
      button.setAttribute('aria-checked', String(on));
      button.setAttribute('aria-disabled', String(on || !ready));
    }
  });
  const hour12 = new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions().hour12 === true;
  mock.querySelectorAll<HTMLElement>('[data-preview-time]').forEach((element) => { element.textContent = previewTime(element.dataset.previewTime!, preferences.timeFormat, hour12); });
  mock.querySelector<HTMLElement>('[data-icloud-preview]')!.hidden = !preferences.syncAcrossMacs;
  mock.querySelector<HTMLElement>('[data-notification-permission]')!.hidden = !notificationPreferences.some((id) => preferences[id]);
  const spend = mock.querySelector<HTMLElement>('.am-spend-card');
  if (spend) spend.hidden = preferences.showTotalSpend === false;
}

export function initPreviewSettings(refresh: () => void, showNotice: typeof notify): void {
  render = () => { refresh(); applyPreviewLanguage(String(state.preferences.language)); };
  notify = showNotice;
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) {
      const stored = JSON.parse(raw);
      state = restorePreviewState(stored);
      if (stored.preferences?.softLimitWindow === '5 Hours' || (stored.preferences?.softLimitEnabled === true && !state.preferences.softLimitEnabled)) save();
    }
    else {
      if (localStorage.getItem('openusage.site.meterStyle') === 'left') state = changePreference(state, 'showUsageAs', 'Left');
      if (localStorage.getItem('openusage.site.resetDisplayMode') === 'relative') state = changePreference(state, 'resetTimes', 'Countdown');
    }
  } catch (error) { report(error, 'Saved preview settings could not be loaded. This page is using the demo defaults.'); }
  document.querySelectorAll<HTMLElement>('[data-mock]').forEach((mock) => { mock.dataset.dashboardTab = String(state.preferences.defaultTab); });
  document.querySelectorAll<HTMLDialogElement>('[data-account-dialog]').forEach((dialog) => {
    dialog.addEventListener('cancel', (event) => { event.preventDefault(); closeAccountDialog(dialog.closest<HTMLElement>('[data-mock]')!); });
  });
  document.querySelectorAll<HTMLDialogElement>('[data-soft-limit-dialog]').forEach((dialog) => {
    dialog.addEventListener('close', () => dialog.closest('[data-mock]')!.querySelector<HTMLElement>('[data-setting="softLimitEnabled"]')?.focus({ preventScroll: true }));
  });
  const rename = (form: HTMLFormElement): void => {
    const input = form.querySelector<HTMLInputElement>('[data-rename-input]')!;
    const error = form.querySelector<HTMLElement>('[data-rename-error]')!;
    try {
      renamePreviewAccount(form.dataset.provider!, form.dataset.accountId!, input.value);
      input.value = accountName(state, form.dataset.provider!, form.dataset.accountId!);
      error.hidden = true;
      input.removeAttribute('aria-invalid');
      input.removeAttribute('aria-describedby');
    } catch (failure) {
      console.warn('Preview account rename failed');
      error.textContent = failure instanceof Error ? failure.message : 'Could not rename this account.';
      error.hidden = false;
      input.setAttribute('aria-invalid', 'true');
      input.setAttribute('aria-describedby', error.id);
      localizePreview(form.closest<HTMLElement>('[data-mock]')!);
    }
  };
  document.querySelectorAll<HTMLFormElement>('[data-rename-form]').forEach((form) => {
    form.addEventListener('submit', (event) => { event.preventDefault(); rename(form); });
    form.addEventListener('change', () => rename(form));
  });
  document.querySelectorAll<HTMLElement>('[data-mock] [data-scr="settings"] .am-body').forEach((body) => {
    const place = (button: HTMLButtonElement): void => {
      const tooltip = button.querySelector('[role="tooltip"]')!.getBoundingClientRect();
      const trigger = button.getBoundingClientRect();
      const row = button.closest('.am-item')!.getBoundingClientRect();
      const viewport = body.getBoundingClientRect();
      const spaceBelow = viewport.bottom - row.bottom;
      const spaceAbove = row.top - viewport.top;
      button.toggleAttribute('data-tooltip-above', spaceBelow < tooltip.height && spaceAbove > spaceBelow);
      const x = (edge: number): string => `${100 * (edge - row.left) / row.width}%`;
      button.style.setProperty('--am-info-hover-bridge',
        `polygon(${x(trigger.left)} 0, ${x(trigger.right)} 0, ${x(tooltip.right)} 100%, ${x(tooltip.left)} 100%)`);
    };
    body.querySelectorAll<HTMLButtonElement>('.am-setting-info').forEach((button) => {
      const reveal = (): void => { delete button.dataset.tooltipDismissed; place(button); };
      button.addEventListener('focus', reveal);
      button.addEventListener('pointerenter', reveal);
      button.addEventListener('click', reveal);
    });
    body.addEventListener('scroll', () => {
      body.querySelectorAll<HTMLButtonElement>('.am-setting-info:not([data-tooltip-dismissed]):is(:hover, :focus)').forEach(place);
    }, { passive: true });
  });
  document.addEventListener('change', (event) => {
    const input = event.target;
    if (!(input instanceof HTMLInputElement) || !input.matches('[data-number-setting]')) return;
    try { setPreviewPreference(input.dataset.numberSetting!, input.value); }
    catch (error) { report(error, 'Enter a whole percentage from 1 to 100. The previous threshold is unchanged.'); render(); }
  });
  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      document.querySelectorAll<HTMLButtonElement>('[data-mock] .am-setting-info:is(:hover, :focus)')
        .forEach((button) => { button.dataset.tooltipDismissed = ''; });
    }
    const input = event.target;
    if (event.key === 'Enter' && input instanceof HTMLInputElement && input.matches('[data-number-setting]')) {
      event.preventDefault();
      input.dispatchEvent(new Event('change', { bubbles: true }));
    }
  });
  matchMedia('(prefers-color-scheme: dark)').addEventListener('change', render);
  render();
}
