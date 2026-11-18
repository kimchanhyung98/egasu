import { test, expect, openHome, openSettings, chooseSetting, allUsage } from './fixtures';

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

test('All Usage uses the layout selected in the existing Settings screen', async ({ page }) => {
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

test('Customize can enable a dormant provider while All Usage omits unreported limits', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const cursor = app.locator('[data-family="cursor"]');
  await expect(cursor).toBeHidden();
  await app.getByRole('button', { name: 'Options', exact: true }).click();
  await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
  await app.getByRole('switch', { name: 'Cursor', exact: true }).click();
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
  await app.getByRole('button', { name: 'Options', exact: true }).click();
  await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
  await app.getByRole('button', { name: 'Open Claude', exact: true }).click();
  for (const metric of ['claude.session', 'claude.weekly', 'claude.fable']) {
    await app.locator(`[data-metric-toggle="${metric}"]`).click();
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
  const colors = await app.locator('[data-period="today"]').evaluate((element) => ({
    text: getComputedStyle(element).color,
    background: getComputedStyle(element).backgroundColor,
  }));
  const luminance = (color: string) => (color.match(/[\d.]+/g) ?? []).slice(0, 3)
    .map((value) => Number(value) / 255)
    .map((value) => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4)
    .reduce((sum, value, index) => sum + value * [0.2126, 0.7152, 0.0722][index], 0);
  const values = [luminance(colors.text), luminance(colors.background)].sort((a, b) => a - b);
  expect((values[1] + 0.05) / (values[0] + 0.05)).toBeGreaterThanOrEqual(4.5);
});

test('Customize provider and metric switches update dashboard visibility', async ({ page }) => {
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const customize = async (): Promise<void> => {
    await app.getByRole('button', { name: 'Options', exact: true }).click();
    await app.getByRole('menuitem', { name: 'Customize', exact: true }).click();
  };
  await customize();
  await app.getByRole('switch', { name: 'Claude', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeHidden();
  await customize();
  await app.getByRole('switch', { name: 'Claude', exact: true }).click();
  await app.getByRole('button', { name: 'Open Claude', exact: true }).click();
  const metric = app.locator('[data-scr="metrics:claude"] [data-metric-toggle="claude.session"]');
  await expect(metric).toHaveAttribute('aria-checked', 'true');
  const id = await metric.getAttribute('data-metric-toggle');
  await metric.click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator(`[data-card="claude-account-1"] [data-metric="${id}"]`)).toBeHidden();
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

test('a saved dashboard without providers only shows its provider empty state', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: {}, activeAccounts: {}, viewedAccounts: {}, enabledProviders: [],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app.getByText('No Enabled Providers', { exact: true })).toBeVisible();
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
