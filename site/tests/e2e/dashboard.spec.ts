import { test, expect, openHome, openSettings, chooseSetting, allUsage, accountDetail, openAccounts } from './fixtures';

test('Priority and All Usage tabs switch on click', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const priority = app.locator('button[data-dashboard-tab="Priority"][role="tab"]');
  await expect(priority).toHaveAttribute('aria-selected', 'true');
  await allUsage(page);
  await expect(app.locator('[data-dashboard-panel="All Usage"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
  await expect(app.locator('[data-card="codex-account-1"] [data-metric="codex.spark"]')).toBeHidden();
});

test('account metrics hide independently and pin once in Priority', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  await detail.locator('[data-pin="claude.weekly"]').click();
  await detail.locator('[data-metric-toggle="claude.session"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await expect(app.locator('[data-priority-group="pinned"] [data-line-id="claude.weekly"]')).toHaveCount(1);
  await expect(app.locator('[data-priority-group="runningOut"] [data-priority-key="claude.weekly@account-1"]')).toHaveCount(0);
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-1"] [data-row="claude.session"]')).toBeHidden();
  await expect(app.locator('[data-card="claude-account-2"] [data-row="claude.session"]')).toBeVisible();
  await accountDetail(page, 'claude');
  await detail.locator('[data-metric-toggle="claude.session"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await expect(app.locator('[data-card="claude-account-1"] [data-row="claude.session"]')).toBeVisible();
});

test('provider context menu exposes links and closes on scroll with restored focus', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const header = app.locator('[data-provider-header="claude"]');
  await header.scrollIntoViewIfNeeded();
  await header.click({ button: 'right' });
  const menu = app.getByRole('menu', { name: 'Claude Links' });
  await expect(menu.getByRole('menuitem', { name: 'Status', exact: true })).toHaveAttribute('href', 'https://status.claude.com/');
  await expect(menu.getByRole('menuitem', { name: 'Dashboard', exact: true })).toHaveAttribute('href', 'https://claude.ai/settings/usage');
  await app.locator('[data-scr="dashboard"] .am-body').evaluate((element) => { element.scrollTop += 50; });
  await expect(menu).toBeHidden();
  await expect(header).toBeFocused();
});

test('selected spend periods remain readable in the Light theme', async ({ page }) => {
  await openHome(page);
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Light');
  const app = page.locator('[data-mock]');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  const colors = await app.locator('[data-period="today"]').evaluate((element) => ({ text: getComputedStyle(element).color, background: getComputedStyle(element).backgroundColor }));
  const luminance = (color: string) => (color.match(/[\d.]+/g) ?? []).slice(0, 3).map(Number).map((value) => value / 255)
    .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
    .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  const values = [luminance(colors.text), luminance(colors.background)].sort((a, b) => a - b);
  expect((values[1] + 0.05) / (values[0] + 0.05)).toBeGreaterThanOrEqual(4.5);
});

test('spend cycles from its round center or legend and persists the selected metric', async ({ page }) => {
  await openHome(page);
  const card = page.locator('[data-mock] .am-spend-card');
  const center = card.locator('[data-state="today:cost"] .am-ring-center');
  await center.scrollIntoViewIfNeeded();
  const box = await center.boundingBox();
  const ring = await card.locator('[data-state="today:cost"] .am-ring').boundingBox();
  expect(box).not.toBeNull();
  expect(ring).not.toBeNull();
  expect(Math.abs(box!.x + box!.width / 2 - (ring!.x + ring!.width / 2))).toBeLessThan(1);
  expect(Math.abs(box!.y + box!.height / 2 - (ring!.y + ring!.height / 2))).toBeLessThan(1);
  await page.mouse.click(box!.x + 1, box!.y + 1);
  await expect(card).toHaveAttribute('data-spend-metric', 'cost');
  await center.press('Enter');
  await expect(card.locator('[data-state="today:costPerMtok"] .am-ring-center')).toBeFocused();
  await card.locator('[data-state="today:costPerMtok"] [data-spend-provider]').first().click();
  await expect(card).toHaveAttribute('data-spend-metric', 'tokens');
  await page.reload();
  await expect(card.locator('[data-state="today:tokens"]')).toBeVisible();
});

test('spend periods switch on click without scrolling the page', async ({ page }) => {
  await openHome(page);
  const periods = page.getByRole('radiogroup', { name: 'Total Spend Period' });
  const initialY = await page.evaluate(() => scrollY);
  for (const name of ['Yesterday', '30 Days', 'Today']) {
    const period = periods.getByRole('radio', { name, exact: true });
    await period.click();
    await expect(period).toHaveAttribute('aria-checked', 'true');
    await expect(periods.locator('[aria-checked="true"]')).toHaveCount(1);
  }
  expect(await page.evaluate(() => scrollY)).toBe(initialY);
});

test('Priority changes its amount label without reversing the provider ring', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const row = app.locator('[data-priority-key="codex.weekly@account-1"]');
  const arc = await row.locator('.am-ring-progress').getAttribute('stroke-dasharray');
  await expect(row.locator('.am-priority-provider')).toBeVisible();
  await expect(row.locator('.am-priority-value .u')).toBeVisible();
  await expect(row.locator('.am-priority-value .l')).toBeHidden();
  await row.locator('[data-toggle-meter]').click();
  await expect(row.locator('.am-priority-value .l')).toHaveText('3% left');
  await expect(row.locator('.am-priority-value .l')).toBeVisible();
  await expect(row.locator('.am-priority-value .u')).toBeHidden();
  await expect(row.locator('.am-ring-progress')).toHaveAttribute('stroke-dasharray', arc!);
  await row.locator('[data-toggle-reset]').click();
  await expect(row.locator('.am-priority-note .rel')).toBeVisible();
});

test('metric order and custom names survive reload and privacy keeps Accounts editable', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  const input = detail.locator('[data-rename-input]');
  await input.fill('Today');
  await detail.locator('.am-topbar > b').click();
  const title = detail.locator('.am-topbar > b');
  const titleName = title.locator('[data-account-name="claude"][data-account-id="account-1"]');
  await expect(title).toHaveText('Claude: Today');
  await expect(titleName).toHaveText('Today');
  await detail.locator('[data-drag-metric="claude.weekly"]').dragTo(detail.locator('[data-drag-metric="claude.session"]'));
  await expect(detail.locator('[data-metric-list][data-shared="false"] > div').first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await openSettings(page);
  await chooseSetting(page, 'Language', '한국어');
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await app.locator('[data-setting="privacyMode"]').click();
  await page.reload();
  await allUsage(page);
  const name = app.locator('[data-card="claude-account-1"] [data-account-name]');
  await expect(name).toHaveText('Today');
  expect(await name.evaluate((node) => getComputedStyle(node).filter)).toBe('blur(4px)');
  await app.locator('[data-options]').click();
  await app.locator('.am-optmenu [data-go="accounts"]').click();
  await app.locator('[data-account-list] .am-open[data-go="account:claude:account-1"]').click();
  await expect(input).toHaveValue('Today');
  await expect(title).toHaveText('Claude: Today');
  await expect(titleName).toHaveText('Today');
  await expect(input).toBeEditable();
  await expect(detail.locator('[data-metric-list][data-shared="false"] > div').first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
});

test('swapped account names and display settings survive reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await accountDetail(page, 'claude');
  const firstDetail = app.locator('[data-scr="account:claude:account-1"]');
  await firstDetail.locator('[data-rename-input]').fill(' account 2 ');
  await firstDetail.locator('.am-topbar > b').click();
  await expect(firstDetail.locator('[data-rename-error]')).toBeVisible();
  await expect(firstDetail.locator('.am-topbar > b')).toHaveText('Claude: Account 1');
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  for (const [id, name] of [['account-1', 'Temporary'], ['account-2', 'Account 1'], ['account-1', 'Account 2']]) {
    await accountDetail(page, 'claude', id);
    const detail = app.locator(`[data-scr="account:claude:${id}"]`);
    await detail.locator('[data-rename-input]').fill(name);
    await detail.locator('.am-topbar > b').click();
    await expect(detail.locator('[data-rename-error]')).toBeHidden();
    await app.locator('.am-scr:not([hidden]) .am-back').click();
    await app.locator('.am-scr:not([hidden]) .am-back').click();
  }
  await page.reload();
  await allUsage(page);
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app.locator('[data-card="claude-account-1"] [data-account-name]')).toHaveText('Account 2');
  await expect(app.locator('[data-card="claude-account-2"] [data-account-name]')).toHaveText('Account 1');
});

test('All Usage uses the layout selected in Display settings', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const panel = app.locator('[data-dashboard-panel="All Usage"]');
  await expect(app).toHaveAttribute('data-layout', 'minimal');
  const weekly = panel.locator('[data-card="claude-account-1"] [data-metric="claude.weekly"]');
  await expect(weekly).toBeVisible();
  const columns = () => weekly.evaluate((row) => getComputedStyle(row).gridTemplateColumns.split(' ').length);
  expect(await columns()).toBe(4);
  await openSettings(page);
  await chooseSetting(page, 'All Usage Layout', 'Cards');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app).toHaveAttribute('data-layout', 'cards');
  await expect(weekly).toBeVisible();
  expect(await columns()).toBe(2);
  await page.reload();
  await allUsage(page);
  await expect(app).toHaveAttribute('data-layout', 'cards');
  expect(await columns()).toBe(2);
});

test('Accounts can add a dormant provider while All Usage omits unreported limits', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const cursor = app.locator('[data-family="cursor"]');
  await expect(cursor).toBeHidden();
  await openAccounts(page);
  await app.locator('[data-add-account]').click();
  await app.locator('[data-add-provider="cursor"]').click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(cursor).toBeVisible();
  await expect(cursor.locator('[data-family-notice]')).toBeVisible();
  await expect(cursor.locator('[data-metric="cursor.credits"]')).toBeHidden();
  await expect(cursor.locator('.am-meter:visible')).toHaveCount(0);
});

test('All Usage shows reported rows without expanding an On Demand section', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const claude = app.locator('[data-card="claude-account-1"]');
  await expect(claude.locator('[data-metric="claude.trend"]')).toBeVisible();
  await expect(claude.locator('[data-expand]')).toHaveCount(0);
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  for (const metric of ['claude.session', 'claude.weekly', 'claude.fable']) {
    await detail.locator(`[data-metric-toggle="${metric}"]`).click();
  }
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(claude.locator('[data-metric="claude.trend"]')).toBeVisible();
  await expect(claude.locator('[data-metric="claude.weekly"]')).toBeHidden();
});

test('pinning a private metric moves it to Priority and hiding it clears only that account', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const priority = app.locator('button[data-dashboard-tab="Priority"][role="tab"]');
  const accountOne = app.locator('[data-card="codex-account-1"] [data-metric="codex.weekly"]');
  const accountTwo = app.locator('[data-card="codex-account-2"] [data-metric="codex.weekly"]');
  const priorityRow = '[data-priority-key="codex.weekly@account-1"]';
  const menu = app.getByRole('menu', { name: 'Metric Actions' });

  await accountOne.click({ button: 'right' });
  await menu.getByRole('menuitem', { name: 'Pin', exact: true }).click();
  await priority.click();
  await expect(app.locator(`[data-priority-group="pinned"] ${priorityRow}`)).toBeVisible();
  await expect(app.locator(`[data-priority-group="runningOut"] ${priorityRow}`)).toHaveCount(0);

  await allUsage(page);
  await accountOne.click({ button: 'right' });
  await expect(menu.getByRole('menuitem', { name: 'Unpin', exact: true })).toBeVisible();
  await menu.getByRole('menuitem', { name: 'Hide', exact: true }).click();
  await expect(accountOne).toBeHidden();
  await expect(accountTwo).toBeVisible();
  await priority.click();
  await expect(app.locator(priorityRow)).toBeHidden();

  await page.reload();
  await allUsage(page);
  await expect(accountOne).toBeHidden();
  await expect(accountTwo).toBeVisible();
  await priority.click();
  await expect(app.locator(priorityRow)).toBeHidden();
});

test('a menu closes on a later content scroll and restores its trigger focus', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const button = app.getByRole('button', { name: 'Options', exact: true });
  await button.click();
  await expect(app.getByRole('menu', { name: 'Options', exact: true })).toBeVisible();
  await app.locator('[data-scr="dashboard"] .am-body').evaluate((element) => { element.scrollTop = 50; });
  await expect(app.getByRole('menu', { name: 'Options', exact: true })).toBeHidden();
  await expect(button).toBeFocused();
});

test('spend period radios support arrow keys without scrolling the page', async ({ page }) => {
  await openHome(page);
  const periods = page.getByRole('radiogroup', { name: 'Total Spend Period' });
  await periods.getByRole('radio', { name: 'Today', exact: true }).focus();
  const initialY = await page.evaluate(() => scrollY);
  await page.keyboard.press('ArrowRight');
  const yesterday = periods.getByRole('radio', { name: 'Yesterday', exact: true });
  await expect(yesterday).toHaveAttribute('aria-checked', 'true');
  await expect(yesterday).toBeFocused();
  await page.keyboard.press('ArrowDown');
  await expect(periods.getByRole('radio', { name: '30 Days', exact: true })).toHaveAttribute('aria-checked', 'true');
  await page.keyboard.press('ArrowRight');
  await expect(periods.getByRole('radio', { name: 'Today', exact: true })).toHaveAttribute('aria-checked', 'true');
  await expect(periods.locator('[tabindex="0"]')).toHaveCount(1);
  expect(await page.evaluate(() => scrollY)).toBe(initialY);
});

test('a saved dashboard without providers only shows its provider empty state', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: {}, activeAccounts: {}, viewedAccounts: {}, enabledProviders: [],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app.getByText('Add an Account', { exact: true })).toBeVisible();
  await expect(app.locator('.am-dashboard-tabs')).toBeHidden();
  await expect(app.locator('[data-dashboard-panel="Priority"]')).toBeHidden();
  await expect(app.locator('[data-dashboard-panel="All Usage"]')).toBeHidden();
  await expect(app.locator('[data-priority-copy]')).toBeHidden();
});

test('keyboard unpinning restores focus when the Priority row disappears', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const priority = app.getByRole('tab', { name: 'Priority', exact: true });
  const session = app.locator('[data-card="claude-account-1"] [data-metric="claude.session"]');
  const menu = app.getByRole('menu', { name: 'Metric Actions' });
  const row = app.locator('[data-priority-key="claude.session@account-1"]');

  await session.click({ button: 'right' });
  await menu.getByRole('menuitem', { name: 'Pin', exact: true }).click();
  await priority.click();
  await expect(row).toBeVisible();
  await row.press('Shift+F10');
  await menu.getByRole('menuitem', { name: 'Unpin', exact: true }).press('Enter');
  await expect(row).toBeHidden();
  await expect(priority).toBeFocused();
});

test('the saved default tab applies on load and ordinary tab changes remain temporary', async ({ page }) => {
  await page.addInitScript(() => {
    const key = 'openusage.site.preview.v1';
    if (!localStorage.getItem(key)) {
      localStorage.setItem(key, JSON.stringify({
        preferences: { defaultTab: 'All Usage' }, activeAccounts: {}, viewedAccounts: {},
      }));
    }
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  const usage = app.getByRole('tab', { name: 'All Usage', exact: true });
  const priority = app.getByRole('tab', { name: 'Priority', exact: true });
  await expect(usage).toHaveAttribute('aria-selected', 'true');

  await priority.click();
  await app.locator('[data-priority-key="codex.weekly@account-1"] [data-toggle-meter]').click();
  await expect(priority).toHaveAttribute('aria-selected', 'true');
  await page.reload();
  await expect(usage).toHaveAttribute('aria-selected', 'true');
});

for (const period of ['yesterday', 'last30']) {
  test(`spend focus falls back to the center when Cursor leaves ${period}`, async ({ page }) => {
    await openHome(page);
    const card = page.locator('[data-mock] .am-spend-card');
    await card.locator(`[data-period="${period}"]`).click();
    const cursor = card.locator(`[data-state="${period}:cost"] [data-spend-provider="cursor"]`);
    await expect(cursor).toBeVisible();
    await cursor.press('Enter');

    const costPerMtok = card.locator(`[data-state="${period}:costPerMtok"]`);
    await expect(costPerMtok).toBeVisible();
    await expect(costPerMtok.locator('[data-spend-provider="cursor"]')).toHaveCount(0);
    await expect(costPerMtok.locator('.am-ring-center')).toBeFocused();

    await page.keyboard.press('Space');
    await expect(card.locator(`[data-state="${period}:tokens"] .am-ring-center`)).toBeFocused();
  });
}

test('account Actions reports its menu state and preserves the active account history', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  await expect(app.locator('[data-family="antigravity"]')).toBeVisible();
  const first = app.locator('[data-card="codex-account-1"]');
  const second = app.locator('[data-card="codex-account-2"]');
  const more = second.getByRole('button', { name: 'Codex Actions', exact: true });
  const menu = second.locator('.am-account-actions');
  const history = ['codex.trend', 'codex.today', 'codex.yesterday', 'codex.last30'];
  for (const id of history) {
    await expect(first.locator(`[data-row="${id}"]`)).toBeVisible();
    await expect(second.locator(`[data-row="${id}"]`)).toBeHidden();
  }
  await expect(more).toHaveAttribute('aria-haspopup', 'menu');
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await expect(more).toHaveAttribute('aria-controls', (await menu.getAttribute('id'))!);
  await more.click();
  await expect(menu).toBeVisible();
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  await page.keyboard.press('Escape');
  await expect(menu).toBeHidden();
  await expect(more).toHaveAttribute('aria-expanded', 'false');
  await expect(more).toBeFocused();
  await second.locator('.am-account-caption').press('Shift+F10');
  await expect(more).toHaveAttribute('aria-expanded', 'true');
  await menu.getByRole('menuitem', { name: 'Use Codex: Account 2', exact: true }).click();
  await app.getByRole('dialog').getByRole('button', { name: 'Switch Account', exact: true }).click();
  for (const id of history) {
    await expect(first.locator(`[data-row="${id}"]`)).toBeHidden();
    await expect(second.locator(`[data-row="${id}"]`)).toBeVisible();
  }
});

test('inline rename ignores composition keys and preserves focus when committing with Tab', async ({ page }) => {
  await page.addInitScript(() => {
    const key = 'openusage.site.preview.v1';
    if (!localStorage.getItem(key)) localStorage.setItem(key, JSON.stringify({
      preferences: { language: '日本語' }, activeAccounts: {},
    }));
  });
  await openHome(page);
  await allUsage(page);
  const card = page.locator('[data-mock] [data-card="claude-account-1"]');
  const more = card.locator('[data-open-account-menu]');
  const name = card.locator('[data-toggle-account-name]');
  const input = card.getByRole('textbox', { name: 'アカウント名' });
  const edit = async (): Promise<void> => {
    await more.press('Enter');
    await card.locator('[data-rename-account]').press('Enter');
    await expect(input).toBeFocused();
  };

  await edit();
  await input.fill('仕事');
  for (const key of ['Enter', 'Escape']) {
    await input.dispatchEvent('keydown', { key, isComposing: true });
    await expect(input).toBeFocused();
  }
  await input.press('Tab');
  await expect(input).toHaveCount(0);
  await expect(more).toBeFocused();
  await expect(name).toHaveText('仕事');

  await edit();
  await input.fill('Cancel this');
  await input.press('Escape');
  await expect(name).toBeFocused();
  await expect(name).toHaveText('仕事');

  await edit();
  await input.fill('チーム');
  await input.press('Enter');
  await expect(name).toBeFocused();
  await expect(name).toHaveText('チーム');

  await page.reload();
  await allUsage(page);
  await expect(name).toHaveText('チーム');
});

test('keyboard reorder moves providers, accounts and metrics within their sections and saves the order', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const families = app.locator('[data-dashboard-panel="All Usage"] [data-family]:visible');
  const claudeProvider = app.locator('[data-drag-provider="claude"]');
  await expect(families.first()).toHaveAttribute('data-family', 'claude');
  await expect(claudeProvider).toHaveAttribute('aria-keyshortcuts', 'ArrowUp ArrowDown');
  await claudeProvider.press('ArrowDown');
  await expect(families.nth(0)).toHaveAttribute('data-family', 'codex');
  await expect(families.nth(1)).toHaveAttribute('data-family', 'claude');
  await expect(claudeProvider).toBeFocused();

  await openAccounts(page);
  const claudeAccounts = app.locator('[data-account-list-row][data-provider="claude"]');
  const secondAccount = app.locator('[data-drag-account="claude:account-2"]');
  await expect(claudeAccounts.first()).toHaveAttribute('data-account-id', 'account-1');
  await secondAccount.press('ArrowDown');
  await expect(claudeAccounts.first()).toHaveAttribute('data-account-id', 'account-1');
  await expect(secondAccount).toBeFocused();
  await secondAccount.press('ArrowUp');
  await expect(claudeAccounts.first()).toHaveAttribute('data-account-id', 'account-2');
  await expect(secondAccount).toBeFocused();

  await app.locator('[data-scr="accounts"] .am-back').click();
  await accountDetail(page, 'claude', 'account-1');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  const accountMetrics = detail.locator('[data-metric-list][data-shared="false"] > div');
  const weekly = detail.locator('[data-drag-metric="claude.weekly"]');
  await expect(accountMetrics.first()).toHaveAttribute('data-metric-setting', 'claude.session');
  await weekly.press('ArrowUp');
  await expect(accountMetrics.first()).toHaveAttribute('data-metric-setting', 'claude.weekly');
  await expect(weekly).toBeFocused();

  await page.reload();
  await allUsage(page);
  await expect(families.nth(0)).toHaveAttribute('data-family', 'codex');
  await expect(families.nth(1)).toHaveAttribute('data-family', 'claude');
  const cards = app.locator('[data-family="claude"] [data-card]:visible');
  await expect(cards.first()).toHaveAttribute('data-card', 'claude-account-2');
  await expect(cards.last()).toHaveAttribute('data-card', 'claude-account-1');
  const firstAccountRows = cards.last().locator('[data-row]:visible');
  await expect(firstAccountRows.first()).toHaveAttribute('data-row', 'claude.weekly');
  await expect(firstAccountRows.nth(1)).toHaveAttribute('data-row', 'claude.session');
});
