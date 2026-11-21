import { test, expect, openHome, openSettings, chooseSetting, allUsage, accountDetail } from './fixtures';

test('turning off every Priority condition shows only All Usage and preserves alerts and the selected tab', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const tablist = app.getByRole('tablist', { name: 'Dashboard' });
  await expect(tablist.getByRole('tab', { name: 'Priority', exact: true })).toHaveAttribute('aria-selected', 'true');
  await openSettings(page);
  await app.getByRole('tab', { name: 'Alerts' }).click();
  await app.getByRole('switch', { name: 'Warning, Receive Alerts', exact: true }).click();
  for (const condition of ['Warning', 'Critical', 'Burning Fast', 'Use It or Lose It']) {
    const toggle = app.getByRole('switch', { name: `${condition}, Show in Priority`, exact: true });
    await expect(toggle).toBeChecked();
    await toggle.click();
  }
  await expect(app.getByRole('switch', { name: 'Warning, Receive Alerts', exact: true })).toBeChecked();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  const all = app.getByRole('region', { name: 'All Usage', exact: true });
  await expect(app).toHaveCSS('width', '340px');
  await expect(all).toBeVisible();
  await expect(all.locator('[data-provider-header="claude"]')).toBeVisible();
  await expect(tablist).toBeHidden();
  expect(await app.locator('.am-dashboard-tabs').boundingBox()).toBeNull();
  await expect(app.getByRole('button', { name: 'Copy Priority', exact: true })).toBeHidden();
  await page.reload();
  await expect(all).toBeVisible();
  await expect(tablist).toBeHidden();
  await openSettings(page);
  await app.getByRole('tab', { name: 'Alerts' }).click();
  await app.getByRole('switch', { name: 'Use It or Lose It, Show in Priority', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(tablist.getByRole('tab', { name: 'Priority', exact: true })).toHaveAttribute('aria-selected', 'true');
  await expect(app.getByRole('tabpanel', { name: 'Priority', exact: true })).toBeVisible();
  await expect(app.locator('[data-all-clear]')).toBeVisible();
  await expect(app.locator('[data-all-clear] .am-clear-row')).toHaveText('No Matching Limits');
});

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

test('provider context menu exposes links and restores focus to its named button', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const header = app.locator('[data-provider-header="claude"]');
  const trigger = header.getByRole('button', { name: 'Claude Links', exact: true });
  const menu = app.locator('.am-family-menu[id="hero-family-claude"]');
  await header.scrollIntoViewIfNeeded();
  if (await page.evaluate(() => matchMedia('(hover: none)').matches)) {
    const grip = header.locator('[data-drag-provider]');
    await expect(grip).toHaveCSS('opacity', '1');
    await expect(grip).toHaveCSS('width', '10px');
  }
  await expect(trigger).toHaveAttribute('aria-haspopup', 'menu');
  await expect(trigger).toHaveAttribute('aria-controls', (await menu.getAttribute('id'))!);
  await expect(trigger).toHaveAttribute('aria-expanded', 'false');
  await header.click({ button: 'right' });
  await expect(trigger).toHaveAttribute('aria-expanded', 'true');
  await expect(menu.getByRole('menuitem', { name: 'Status', exact: true })).toHaveAttribute('href', 'https://status.claude.com/');
  await expect(menu.getByRole('menuitem', { name: 'Dashboard', exact: true })).toHaveAttribute('href', 'https://claude.ai/settings/usage');
  await app.locator('[data-scr="dashboard"] .am-body').evaluate((element) => { element.scrollTop += 50; });
  await expect(menu).toBeHidden();
  await expect(trigger).toBeFocused();
  await expect(trigger).toHaveAttribute('aria-expanded', 'false');

  await trigger.press('Enter');
  await expect(menu.getByRole('menuitem', { name: 'Refresh', exact: true })).toBeFocused();
  await page.keyboard.press('Escape');
  await expect(trigger).toHaveAttribute('aria-expanded', 'false');
  await expect(trigger).toBeFocused();

  await trigger.click();
  await expect(trigger).toHaveAttribute('aria-expanded', 'true');
  await trigger.click();
  await expect(menu).toBeHidden();
  await expect(trigger).toHaveAttribute('aria-expanded', 'false');
  await expect(trigger).toBeFocused();
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

test('Priority keeps its quota ring and pace mark in sync with Used and Left', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  const row = app.locator('[data-priority-key="codex.weekly@account-1"]');
  const arc = row.locator('.am-ring-progress');
  const pace = row.locator('.am-ring-pace');
  const displayedFraction = () => arc.evaluate((element: SVGCircleElement) => {
    const fill = parseFloat(element.getAttribute('stroke-dasharray')!);
    return fill / (element.pathLength.baseVal || element.getTotalLength());
  });
  await expect(row.locator('.am-priority-provider')).toBeVisible();
  await expect(row.locator('.am-priority-value .u')).toBeVisible();
  await expect(row.locator('.am-priority-value .l')).toBeHidden();
  expect(await displayedFraction()).toBeCloseTo(0.97);
  await expect(pace).toHaveAttribute('transform', 'rotate(324 20 20)');
  await row.locator('[data-toggle-meter]').click();
  await expect(row.locator('.am-priority-value .l')).toHaveText('3% left');
  await expect(row.locator('.am-priority-value .l')).toBeVisible();
  await expect(row.locator('.am-priority-value .u')).toBeHidden();
  expect(await displayedFraction()).toBeCloseTo(0.03);
  await expect(pace).toHaveAttribute('transform', 'rotate(36 20 20)');
  await expect(row).toHaveAttribute('data-severity', 'critical');
  await row.locator('[data-toggle-meter]').click();
  expect(await displayedFraction()).toBeCloseTo(0.97);
  await expect(pace).toHaveAttribute('transform', 'rotate(324 20 20)');
  await row.locator('[data-toggle-reset]').click();
  await expect(row.locator('.am-priority-note .rel')).toBeVisible();
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

test('All Usage explains how to restore hidden metrics on an enabled account', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { defaultTab: 'All Usage' }, activeAccounts: {}, enabledProviders: ['antigravity'],
    hiddenMetrics: ['geminiPro', 'geminiWeekly', 'claude', 'claudeWeekly'].map((id) => `antigravity.${id}@default`),
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  const notice = app.getByText('No usage to show. Check visible metrics in Accounts.', { exact: true });
  await expect(notice).toBeVisible();
  await expect(app.getByText('Add an Account', { exact: true })).toBeHidden();
  await app.locator('[data-options]').click();
  await app.locator('.am-optmenu [data-go="accounts"]').click();
  await app.locator('[data-account-list] .am-open[data-go="account:antigravity:default"]').click();
  await app.locator('[data-metric-toggle="antigravity.geminiPro"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await expect(notice).toBeHidden();
  await expect(app.locator('[data-row="antigravity.geminiPro"]')).toBeVisible();
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
