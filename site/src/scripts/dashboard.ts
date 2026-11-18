import { dashboardLines, priorityBoard, menuBarItems } from '../data/preview-dashboard';
import { metricKey, providerMetrics } from '../data/metrics';
import { orderedMetrics, accountName, accountEmail, type PreviewState } from '../data/preview-state';
import { providers } from '../data/providers';

export function renderDashboard(mock: HTMLElement, state: PreviewState): void {
  if (!mock.querySelector('[data-dashboard-panel]')) return;
  const lines = dashboardLines(state);
  const board = priorityBoard(state);
  const accounts = mock.querySelectorAll<HTMLElement>('.am-account-section');
  accounts.forEach((section) => {
    const family = section.dataset.provider!;
    const accountID = section.dataset.accountId!;
    const own = lines.filter((line) => line.provider === family && line.accountID === accountID);
    const visible = new Set(own.map((line) => line.id));
    const content = section.querySelector<HTMLElement>('.am-account-metrics')!;
    const order = orderedMetrics(state, family, accountID).map((row) => row.id);
    const rows = [...content.querySelectorAll<HTMLElement>('[data-row]')];
    rows.sort((a, b) => order.indexOf(a.dataset.row!) - order.indexOf(b.dataset.row!)).forEach((row) => {
      row.hidden = !visible.has(row.dataset.row!);
      const line = own.find((line) => line.id === row.dataset.row);
      if (line) row.querySelector<HTMLElement>('[data-severity]')?.setAttribute('data-severity', line.severity);
      content.append(row);
    });
    section.hidden = !state.enabledProviders.includes(family) || !own.length;
    section.dataset.inactiveAccount = String(accountID !== 'default' && state.activeAccounts[family] !== accountID);
  });
  mock.querySelectorAll<HTMLElement>('[data-family]').forEach((family) => {
    const id = family.dataset.family!;
    const hasData = lines.some((line) => line.provider === id);
    const pending = board.pending.includes(id);
    family.hidden = !state.enabledProviders.includes(id) || (!hasData && !pending);
    family.querySelector<HTMLElement>('[data-family-notice]')!.hidden = !pending;
    const container = family.querySelector<HTMLElement>('.am-family-accounts')!;
    const order = state.accountOrder[id] ?? ['default'];
    [...container.children].sort((a, b) => order.indexOf((a as HTMLElement).dataset.accountId!) - order.indexOf((b as HTMLElement).dataset.accountId!)).forEach((account) => container.append(account));
  });
  const allUsage = mock.querySelector<HTMLElement>('[data-dashboard-panel="All Usage"]')!;
  state.providerOrder.forEach((id) => {
    const family = allUsage.querySelector<HTMLElement>(`[data-family="${id}"]`);
    if (family) allUsage.append(family);
  });

  const priorityRows = new Map([...mock.querySelectorAll<HTMLElement>('[data-priority-key]')].map((row) => [row.dataset.priorityKey!, row]));
  priorityRows.forEach((row) => { row.hidden = true; });
  for (const group of ['pinned', 'runningOut', 'useItOrLoseIt', 'usedUp'] as const) {
    const section = mock.querySelector<HTMLElement>(`[data-priority-group="${group}"]`)!;
    section.hidden = !board[group].length;
    board[group].forEach((line) => {
      // 공통 지표는 활성 계정이 바뀌어도 같은 키의 행을 재사용.
      const row = priorityRows.get(line.key);
      if (!row) return;
      row.dataset.accountId = line.accountID;
      row.dataset.severity = line.severity;
      row.dataset.spent = String(line.group === 'usedUp');
      row.hidden = false;
      const name = row.querySelector<HTMLElement>('[data-account-name]');
      if (name) name.dataset.accountId = line.accountID;
      const circle = row.querySelector<SVGCircleElement>('.am-ring-progress');
      const fraction = line.row.kind === 'bounded' ? line.row.used / line.row.limit : line.row.kind === 'forecast' ? line.row.probability / 100 : 0;
      circle?.setAttribute('stroke-dasharray', `${Math.max(0, Math.min(fraction, 1)) * 106.81} 106.81`);
      section.querySelector('.am-priority-items')!.append(row);
    });
  }
  mock.querySelector<HTMLElement>('[data-all-clear]')!.hidden = !board.allClear;
  mock.querySelector<HTMLElement>('[data-no-limits]')!.hidden = !board.noLimits;
  mock.querySelector<HTMLElement>('[data-priority-notices]')!.hidden = !board.pending.length;
  mock.querySelectorAll<HTMLElement>('[data-priority-notice]').forEach((notice) => {
    notice.hidden = !board.pending.includes(notice.dataset.priorityNotice!);
  });
  const empty = !state.enabledProviders.length;
  mock.querySelector<HTMLElement>('[data-empty-dashboard]')!.hidden = !empty;
  mock.querySelector<HTMLElement>('.am-dashboard-tabs')!.hidden = empty;
  mock.dataset.layout = state.preferences.allUsageLayout === 'Cards' ? 'cards' : 'minimal';
  setDashboardTab(mock, mock.dataset.dashboardTab ?? String(state.preferences.defaultTab));

  renderAccountSettings(mock, state);
  renderMenuBar(mock, state);
}

export function setDashboardTab(mock: HTMLElement, tab: string): void {
  const changed = mock.dataset.dashboardTab !== tab;
  mock.dataset.dashboardTab = tab;
  if (changed) mock.querySelector<HTMLElement>('[data-scr="dashboard"] .am-body')!.scrollTop = 0;
  mock.querySelectorAll<HTMLButtonElement>('button[data-dashboard-tab][role="tab"]').forEach((button) => {
    const selected = button.dataset.dashboardTab === tab;
    button.setAttribute('aria-selected', String(selected));
    button.tabIndex = selected ? 0 : -1;
  });
  const hasProviders = mock.querySelector<HTMLElement>('[data-empty-dashboard]')!.hidden;
  mock.querySelectorAll<HTMLElement>('[data-dashboard-panel]').forEach((panel) => {
    panel.hidden = !hasProviders || panel.dataset.dashboardPanel !== tab;
  });
  mock.querySelector<HTMLElement>('[data-priority-copy]')?.toggleAttribute('hidden', !hasProviders || tab !== 'Priority');
}

function renderAccountSettings(mock: HTMLElement, state: PreviewState): void {
  const empty = mock.querySelector<HTMLElement>('[data-accounts-empty]');
  if (empty) empty.hidden = state.enabledProviders.length !== 0;
  mock.querySelectorAll<HTMLElement>('[data-account-list-row]').forEach((row) => {
    row.hidden = !state.enabledProviders.includes(row.dataset.provider!);
  });
  const list = mock.querySelector<HTMLElement>('[data-account-list]');
  if (list) state.providerOrder.forEach((family) => {
    const order = state.accountOrder[family] ?? ['default'];
    order.forEach((account) => {
      const row = list.querySelector<HTMLElement>(`[data-provider="${family}"][data-account-id="${account}"]`);
      if (row) list.append(row);
    });
  });
  mock.querySelectorAll<HTMLElement>('[data-metric-toggle], [data-pin]').forEach((button) => {
    const id = button.dataset.metricToggle ?? button.dataset.pin!;
    const key = metricKey(id, button.dataset.accountId);
    const shown = !state.hiddenMetrics.includes(key);
    if (button.dataset.pin) {
      const pinned = state.pinnedMetrics.includes(key);
      button.setAttribute('aria-pressed', String(pinned));
      const title = providerMetrics[id.split('.')[0]].rows.find((row) => row.id === id)!.title;
      button.setAttribute('aria-label', `${pinned ? 'Unpin' : 'Pin'} ${title}`);
      (button as HTMLButtonElement).disabled = !shown;
    } else {
      button.setAttribute('aria-checked', String(shown));
      button.classList.toggle('is-on', shown);
    }
  });
  mock.querySelectorAll<HTMLElement>('[data-account-detail]').forEach((detail) => {
    const order = orderedMetrics(state, detail.dataset.accountDetail!, detail.dataset.accountId!).map((metric) => metric.id);
    detail.querySelectorAll<HTMLElement>('[data-metric-list]').forEach((list) => {
      [...list.children].sort((a, b) => order.indexOf((a as HTMLElement).dataset.metricSetting!) - order.indexOf((b as HTMLElement).dataset.metricSetting!)).forEach((row) => list.append(row));
    });
  });
  renderAccountNames(mock, state);
}

function renderAccountNames(mock: HTMLElement, state: PreviewState): void {
  mock.querySelectorAll<HTMLElement>('[data-account-name]').forEach((element) => {
    const family = element.dataset.accountName!;
    const id = element.dataset.accountId!;
    const dashboard = element.closest('[data-scr="dashboard"]');
    element.toggleAttribute('data-preview-literal', Object.hasOwn(state.accountNames, `${family}:${id}`) || Boolean(dashboard && mock.dataset.showEmails === 'true'));
    element.textContent = dashboard && mock.dataset.showEmails === 'true' ? accountEmail(family, id) : accountName(state, family, id);
    element.classList.toggle('is-in-use', state.activeAccounts[family] === id);
  });
  mock.querySelectorAll<HTMLElement>('[data-in-use]').forEach((badge) => { badge.hidden = state.activeAccounts[badge.dataset.inUse!] !== badge.dataset.accountId; });
  mock.querySelectorAll<HTMLInputElement>('[data-rename-input]').forEach((input) => {
    const form = input.closest<HTMLElement>('[data-rename-form]')!;
    if (input !== document.activeElement) input.value = accountName(state, form.dataset.provider!, form.dataset.accountId!);
  });
  mock.querySelectorAll<HTMLButtonElement>('[data-rename-account]').forEach((button) => { button.disabled = state.preferences.privacyMode === true; });
}

function renderMenuBar(mock: HTMLElement, state: PreviewState): void {
  const container = mock.querySelector<HTMLElement>('[data-menu-bar-preview]');
  if (!container) return;
  container.replaceChildren();
  const selection = menuBarItems(state);
  if (!selection.items.length) { container.textContent = '◉'; return; }
  for (const item of selection.items) {
    const label = document.createElement('span');
    label.className = 'am-menu-preview-item';
    const provider = providers.find((provider) => provider.id === item.provider)!;
    if (item.row.kind === 'bounded') {
      const fraction = state.preferences.showUsageAs === 'Left' ? 1 - item.row.used / item.row.limit : item.row.used / item.row.limit;
      if (state.preferences.iconStyle === 'Bars') {
        const bar = document.createElement('span');
        bar.className = 'am-menu-preview-bar';
        bar.style.setProperty('--bar-fill', `${Math.round(fraction * 100)}%`);
        bar.setAttribute('aria-label', `${provider.name} ${item.row.label} ${Math.round(fraction * 100)}%`);
        label.append(bar);
      } else label.textContent = `${provider.name} ${Math.round(fraction * 100)}%`;
    } else label.textContent = `${provider.name} ${item.row.kind === 'text' ? item.row.values[0] : item.row.kind === 'forecast' ? `${item.row.probability}%` : ''}`;
    container.append(label);
  }
  if (selection.overflow) container.append(document.createTextNode(` +${selection.overflow}`));
}
