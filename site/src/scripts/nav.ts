import { metricKey, providerMetrics } from '../data/metrics';
import { setMetric, setProviderEnabled, moveMetric, renameAccount, accountName } from '../data/preview-state';
import { renderDashboard, setDashboardTab } from './dashboard';
import { initPreviewSettings, applySettingsToMock, choosePreviewSetting, handleSettingsClick, previewState, updatePreviewState } from './settings';
import { openMenu, closeMenu } from './menus';
import { localizePreview } from './localization';

const PILL_MS = 4500;
// 앱은 패널 높이를 min(내용, 화면 85%)로 자르고 넘치면 내부 스크롤(PanelHeightController.swift:139·152).
// 웹에서는 화면 높이를 알 필요가 없으니 그 성격만 가져와 상한을 고정 — 화면을 옮겨도 페이지가 크게 움직이지 않음.
const MAX_H = 560;

function root(el: Element): HTMLElement | null {
  return el.closest<HTMLElement>('[data-mock]');
}

/** 화면 교체. 앱은 밀어 넣지 않고 제자리 교체하므로 hidden만 바꿈. */
function go(mock: HTMLElement, screen: string): void {
  mock.dataset.screen = screen;
  mock.querySelectorAll<HTMLElement>('.am-scr').forEach((s) => {
    s.hidden = s.dataset.scr !== screen;
  });
  closeOptions(mock);
  const shown = mock.querySelector<HTMLElement>('.am-scr:not([hidden])');
  const body = shown?.querySelector<HTMLElement>('.am-body');
  if (body) body.scrollTop = 0;
  fitHeight(mock);
  shown?.querySelector<HTMLElement>('button, [tabindex="0"]')?.focus({ preventScroll: true });
}

// 팝오버 높이를 보이는 화면에 맞춰 px로 고정. CSS의 transition이 그 사이를 이어 줌.
// 높이를 auto로 두면 화면·행이 바뀔 때마다 아래 내용이 통째로 튐. 앱도 패널 높이를 애니메이션함.
function fitHeight(mock: HTMLElement): void {
  const shown = mock.querySelector<HTMLElement>('.am-scr:not([hidden])');
  if (!shown) return;
  let natural = 0;
  for (const part of Array.from(shown.children) as HTMLElement[]) {
    natural += part.classList.contains('am-body')
      ? Array.from(part.children).reduce((height, child) => height + (child as HTMLElement).offsetHeight, 0)
      : part.offsetHeight;
  }
  const height = `${Math.min(natural, MAX_H)}px`;
  if (mock.style.height !== height) mock.style.height = height;
}

// caret 펼침·지표 스위치·기간 전환처럼 화면 안에서 높이가 바뀌는 경우까지 한 번에 받음.
function watchHeights(): void {
  if (!('ResizeObserver' in window)) return;
  document.querySelectorAll<HTMLElement>('[data-mock]').forEach((mock) => {
    const io = new ResizeObserver(() => requestAnimationFrame(() => fitHeight(mock)));
    mock.querySelectorAll<HTMLElement>('.am-content, .am-screen, .am-topbar, .am-foot, .am-settings-tabs').forEach((s) => io.observe(s));
  });
}

function closePickers(mock: HTMLElement): void {
  mock.querySelectorAll<HTMLElement>('.am-pickmenu').forEach((m) => {
    closeMenu(m);
  });
  mock.querySelectorAll<HTMLElement>('[data-picker]').forEach((b) => {
    b.setAttribute('aria-expanded', 'false');
  });
}

function closeOptions(mock: HTMLElement): void {
  closePickers(mock);
  mock.querySelectorAll<HTMLElement>('.am-optmenu, .am-account-actions, .am-family-menu, .am-row-menu').forEach((m) => {
    closeMenu(m);
  });
  mock.querySelectorAll<HTMLElement>('[data-options]').forEach((b) => {
    b.setAttribute('aria-expanded', 'false');
  });
}

// 타이머는 팝오버마다 따로 — 하나로 두면 다른 팝오버에서 필을 띄울 때 앞의 필이 안 사라짐.
const pillTimers = new WeakMap<HTMLElement, number>();

function pill(mock: HTMLElement, text: string, notice = false): void {
  const el = mock.querySelector<HTMLElement>('[data-pill]');
  if (!el) return;
  el.textContent = text;
  localizePreview(mock);
  el.classList.toggle('is-notice', notice);
  el.hidden = false;
  window.clearTimeout(pillTimers.get(mock) ?? 0);
  pillTimers.set(mock, window.setTimeout(() => {
    el.hidden = true;
  }, PILL_MS));
}

function sync(mock: HTMLElement): void {
  const focus = document.activeElement;
  applySettingsToMock(mock);
  renderDashboard(mock, previewState());
  localizePreview(mock);
  fitHeight(mock);
  if (focus instanceof HTMLElement && mock.contains(focus) && !focus.closest('[hidden]')) {
    focus.focus({ preventScroll: true });
  }
}

function settingsTab(mock: HTMLElement, tab: string): void {
  closeOptions(mock);
  mock.dataset.settingsTab = tab;
  mock.querySelectorAll<HTMLElement>('[data-settings-panel]').forEach((panel) => { panel.hidden = panel.dataset.settingsPanel !== tab; });
  mock.querySelectorAll<HTMLElement>('button[data-settings-tab]').forEach((button) => {
    const selected = button.dataset.settingsTab === tab;
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
  });
  mock.querySelector<HTMLElement>('[data-scr="settings"] .am-body')!.scrollTop = 0;
  fitHeight(mock);
}

interface RowSelection {
  id: string;
  accountID: string;
  provider: string;
  trigger: HTMLElement;
}

const rowSelections = new WeakMap<HTMLElement, RowSelection>();

function openContext(target: Element, event: Event): void {
  const mock = root(target);
  if (!mock) return;
  const menuTrigger = target.closest<HTMLElement>('[data-provider-header]')
    ?? target.closest('.am-account-caption')?.querySelector<HTMLButtonElement>('[data-account-actions-trigger]');
  if (menuTrigger) {
    const id = menuTrigger.getAttribute('aria-controls');
    const menu = id && mock.querySelector<HTMLElement>(`#${CSS.escape(id)}`);
    if (!menu) return;
    event.preventDefault();
    openMenu(menu, menuTrigger);
    return;
  }
  const row = target.closest<HTMLElement>('[data-row], [data-line-id]');
  const menu = mock.querySelector<HTMLElement>('[data-row-menu]');
  if (!row || !menu) return;
  const id = row.dataset.row ?? row.dataset.lineId!;
  const providerID = row.dataset.provider!;
  const accountID = row.dataset.accountId!;
  const metric = providerMetrics[providerID]?.rows.find((entry) => entry.id === id);
  if (!metric) return;
  const trigger = target.closest<HTMLElement>('[tabindex], button') ?? row;
  rowSelections.set(mock, { id, accountID, provider: providerID, trigger });
  const option = menu.querySelector<HTMLElement>('[data-row-action="pin"]')!;
  option.closest('li')!.hidden = !metric.pinnable;
  menu.querySelectorAll<HTMLElement>('[data-row-account-action]').forEach((item) => { item.hidden = row.hasAttribute('data-priority-key'); });
  option.textContent = previewState().pinnedMetrics.includes(metricKey(id, accountID)) ? 'Unpin' : 'Pin';
  localizePreview(mock);
  event.preventDefault();
  openMenu(menu, trigger);
}

function inlineRename(mock: HTMLElement, family: string, id: string): void {
  if (previewState().preferences.privacyMode) return;
  closeOptions(mock);
  const name = mock.querySelector<HTMLElement>(`.am-account-caption [data-account-name="${family}"][data-account-id="${id}"]`);
  if (!name) return;
  const input = document.createElement('input');
  input.className = 'am-inline-name'; input.value = accountName(previewState(), family, id); input.maxLength = 60;
  input.setAttribute('aria-label', 'Account Name');
  name.hidden = true;
  name.after(input);
  localizePreview(input);
  let finished = false;
  const finish = (restoreFocus: boolean): void => {
    if (finished) return;
    finished = true;
    try { updatePreviewState(renameAccount(previewState(), family, id, input.value)); }
    catch (error) { console.warn('Preview account rename failed'); pill(mock, error instanceof Error ? error.message : 'Could not rename this account.', true); }
    input.remove(); name.hidden = false;
    if (restoreFocus) name.focus({ preventScroll: true });
  };
  input.addEventListener('keydown', (event) => {
    if (event.isComposing) return;
    if (event.key === 'Enter') { event.preventDefault(); finish(true); }
    if (event.key === 'Escape') {
      finished = true;
      input.remove();
      name.hidden = false;
      name.focus({ preventScroll: true });
    }
  });
  input.addEventListener('blur', () => finish(false));
  input.focus(); input.select();
}

export function initPopoverNav(): void {
  document.addEventListener('contextmenu', (event) => {
    if (event.target instanceof Element) openContext(event.target, event);
  });
  document.addEventListener('keydown', (event) => {
    if ((event.key === 'ContextMenu' || (event.shiftKey && event.key === 'F10')) && event.target instanceof Element) {
      openContext(event.target, event);
    }
  });
  document.addEventListener('click', (event) => {
    const target = event.target as Element | null;
    if (!target || !target.closest) return;
    const mock = root(target);
    if (mock && handleSettingsClick(target, mock)) return;

    const rowAction = target.closest<HTMLElement>('[data-row-action]');
    if (rowAction && mock) {
      const selection = rowSelections.get(mock);
      if (!selection) return;
      closeOptions(mock);
      const { id, accountID, provider, trigger } = selection;
      if (rowAction.dataset.rowAction === 'edit') go(mock, `account:${provider}:${accountID}`);
      else {
        const pinned = previewState().pinnedMetrics.includes(metricKey(id, accountID));
        const action = rowAction.dataset.rowAction === 'hide' ? 'hide' : pinned ? 'unpin' : 'pin';
        updatePreviewState(setMetric(previewState(), id, accountID, action));
        const focus = mock.contains(trigger) && !trigger.closest('[hidden]')
          ? trigger
          : mock.querySelector<HTMLElement>('[data-dashboard-tab][aria-selected="true"]');
        focus?.focus({ preventScroll: true });
      }
      return;
    }
    const rename = target.closest<HTMLElement>('[data-rename-account]');
    if (rename && mock) {
      inlineRename(mock, rename.dataset.renameAccount!, rename.dataset.accountId!);
      return;
    }
    if (mock && target.closest('[data-toggle-account-name]')) {
      mock.dataset.showEmails = String(mock.dataset.showEmails !== 'true');
      sync(mock);
      return;
    }
    const settingTab = target.closest<HTMLElement>('button[data-settings-tab]');
    if (settingTab && mock) {
      settingsTab(mock, settingTab.dataset.settingsTab!);
      return;
    }
    const tab = target.closest<HTMLElement>('button[data-dashboard-tab]');
    if (tab && mock) {
      setDashboardTab(mock, tab.dataset.dashboardTab!);
      fitHeight(mock);
      return;
    }
    const accountMenu = target.closest<HTMLButtonElement>('[data-open-account-menu]');
    if (mock && accountMenu) {
      if (accountMenu.getAttribute('aria-expanded') === 'true') {
        closeOptions(mock);
        accountMenu.focus({ preventScroll: true });
      } else openContext(accountMenu, event);
      return;
    }

    const options = target.closest<HTMLElement>('[data-options]');
    if (options && mock) {
      const menu = mock.querySelector<HTMLElement>('.am-optmenu');
      const open = options.getAttribute('aria-expanded') === 'true';
      if (menu) {
        if (open) closeMenu(menu);
        else openMenu(menu, options);
      }
      return;
    }

    // 메뉴 항목·뒤로 가기·L1 chevron이 모두 같은 속성으로 목적지를 말함.
    const dest = target.closest<HTMLElement>('[data-go]');
    if (dest && mock) {
      go(mock, dest.dataset.go ?? 'dashboard');
      return;
    }

    const add = target.closest<HTMLElement>('[data-add-provider]');
    if (add && mock) {
      const state = previewState();
      const id = add.dataset.addProvider!;
      if (state.enabledProviders.includes(id)) pill(mock, 'Add and sign in to accounts in the Mac app.');
      else {
        updatePreviewState(setProviderEnabled(state, id, true));
        go(mock, 'accounts');
        pill(mock, 'Sample provider added. Connect your account in the Mac app.');
      }
      return;
    }

    const picker = target.closest<HTMLElement>('[data-picker]');
    if (picker && mock) {
      const menu = mock.querySelector<HTMLElement>(`#${CSS.escape(picker.getAttribute('aria-controls') ?? '')}`);
      const open = picker.getAttribute('aria-expanded') === 'true';
      closePickers(mock);
      if (!open && menu) {
        openMenu(menu, picker);
      }
      return;
    }

    const pick = target.closest<HTMLElement>('[data-pick]');
    if (pick && mock) {
      const menu = pick.closest<HTMLElement>('[role="menu"]');
      const trigger = menu && mock.querySelector<HTMLElement>(`[aria-controls="${CSS.escape(menu.id)}"]`);
      choosePreviewSetting(mock, pick.dataset.pick!, pick.dataset.value!);
      closePickers(mock);
      trigger?.focus({ preventScroll: true });
      return;
    }

    const metric = target.closest<HTMLButtonElement>('[data-metric-toggle], [data-pin]');
    if (metric && mock && !metric.disabled) {
      metric.focus({ preventScroll: true });
      const state = previewState();
      const id = metric.dataset.metricToggle ?? metric.dataset.pin!;
      const accountID = metric.dataset.accountId!;
      const key = metricKey(id, accountID);
      const action = metric.dataset.pin
        ? (state.pinnedMetrics.includes(key) ? 'unpin' : 'pin')
        : (state.hiddenMetrics.includes(key) ? 'show' : 'hide');
      updatePreviewState(setMetric(state, id, accountID, action));
      return;
    }

    const row = target.closest<HTMLElement>('[data-open]');
    if (row && mock && !target.closest('.am-drag')) {
      go(mock, row.dataset.open!);
      return;
    }

    if (mock) closeOptions(mock);
    else document.querySelectorAll<HTMLElement>('[data-mock]').forEach(closeOptions);
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape') {
      document.querySelectorAll<HTMLElement>('[data-mock]').forEach((mock) => {
        const trigger = mock.querySelector<HTMLElement>('[aria-expanded="true"][aria-haspopup="menu"]');
        closeOptions(mock);
        trigger?.focus({ preventScroll: true });
      });
      return;
    }
    const active = document.activeElement as HTMLElement | null;
    const tablist = active?.closest('[role="tablist"]:is(.am-dashboard-tabs, .am-settings-tabs)');
    if (tablist && ['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(event.key)) {
      const tabs = [...tablist.querySelectorAll<HTMLButtonElement>('button[role="tab"]')];
      const index = tabs.indexOf(active as HTMLButtonElement);
      if (index < 0) return;
      const offset = event.key === 'ArrowLeft' ? -1 : 1;
      const next = event.key === 'Home' ? 0 : event.key === 'End' ? tabs.length - 1 : (index + offset + tabs.length) % tabs.length;
      event.preventDefault();
      tabs[next].click();
      tabs[next].focus({ preventScroll: true });
      return;
    }
    moveInMenu(event);
  });

  initPreviewSettings(() => document.querySelectorAll<HTMLElement>('[data-mock]').forEach(sync), pill);
  watchHeights();
  initReordering();
}

// 열린 메뉴 안에서 위아래·Home/End 이동. Options 메뉴와 Total Spend 지표 메뉴가 같은 role="menu"라 함께 처리.
// aria-disabled 항목은 button이 아니라 초점을 받지 않으므로 자연히 건너뜀.
function moveInMenu(event: KeyboardEvent): void {
  const active = document.activeElement as HTMLElement | null;
  const menu = active?.closest<HTMLElement>('[role="menu"]');
  if (!menu || menu.hidden) return;
  const items = Array.from(menu.querySelectorAll<HTMLElement>('[role^="menuitem"]:not([aria-disabled="true"]):not(:disabled):not(li[hidden] *)'));
  const i = items.indexOf(active!);
  if (i < 0) return;
  const next: Record<string, number> = { ArrowDown: i + 1, ArrowUp: i - 1, Home: 0, End: items.length - 1 };
  if (!(event.key in next)) return;
  event.preventDefault();
  items[(next[event.key] + items.length) % items.length].focus();
}

function reorder(source: HTMLElement, target: HTMLElement): void {
  const state = previewState();
  const move = (order: string[], id: string, target: string): string[] => {
    const result = order.filter((item) => item !== id);
    result.splice(order.indexOf(target), 0, id); return result;
  };
  if (source.dataset.dragMetric && target.dataset.dragMetric) {
    const detail = source.closest<HTMLElement>('[data-account-detail]')!;
    updatePreviewState(moveMetric(state, detail.dataset.accountDetail!, detail.dataset.accountId!, source.dataset.dragMetric, target.dataset.dragMetric));
  } else if (source.dataset.dragProvider && target.dataset.dragProvider) {
    updatePreviewState({ ...state, providerOrder: move(state.providerOrder, source.dataset.dragProvider, target.dataset.dragProvider) });
  } else if (source.dataset.dragAccount && target.dataset.dragAccount) {
    const [family, id] = source.dataset.dragAccount.split(':');
    const [other, targetID] = target.dataset.dragAccount.split(':');
    if (family !== other || !state.accountOrder[family]) return;
    updatePreviewState({ ...state, accountOrder: { ...state.accountOrder, [family]: move(state.accountOrder[family], id, targetID) } });
  }
  source.focus({ preventScroll: true });
}

function initReordering(): void {
  document.addEventListener('keydown', (event) => {
    if (event.defaultPrevented || event.altKey || event.ctrlKey || event.metaKey || event.shiftKey
      || (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') || !(event.target instanceof HTMLElement)) return;
    const handle = event.target.closest<HTMLElement>('.am-drag');
    if (!handle || !root(handle)) return;
    const list = handle.closest('[data-metric-list], [data-account-list], [data-dashboard-panel="All Usage"]');
    if (!list) return;
    const family = handle.dataset.dragAccount?.split(':')[0];
    const handles = [...list.querySelectorAll<HTMLElement>('.am-drag')].filter((item) =>
      !item.closest('[hidden]') && (!family || item.dataset.dragAccount?.startsWith(`${family}:`)));
    const next = handles[handles.indexOf(handle) + (event.key === 'ArrowUp' ? -1 : 1)];
    event.preventDefault();
    if (next) reorder(handle, next);
  });
  let source: HTMLElement | undefined;
  document.addEventListener('dragstart', (event) => {
    source = event.target instanceof HTMLElement ? event.target.closest<HTMLElement>('.am-drag') ?? undefined : undefined;
    if (source) { event.dataTransfer!.setData('text/plain', 'egasu-preview'); event.dataTransfer!.effectAllowed = 'move'; }
  });
  document.addEventListener('dragover', (event) => { if (source && event.target instanceof Element && event.target.closest('[data-mock]')) event.preventDefault(); });
  document.addEventListener('drop', (event) => {
    if (!source || !(event.target instanceof Element)) return;
    const row = event.target.closest<HTMLElement>(source.dataset.dragMetric ? '[data-metric-setting]' : source.dataset.dragAccount ? '[data-account-list-row]' : '[data-provider-header]');
    const target = row?.querySelector<HTMLElement>('.am-drag');
    if (target) { event.preventDefault(); reorder(source, target); }
    source = undefined;
  });
  document.addEventListener('dragend', () => { source = undefined; });
}
