import { test, expect, openHome, openSettings, chooseSetting, allUsage, accountDetail, openAccounts } from './fixtures';

test('Accounts confirms switching and preserves both registered account limits', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude', 'account-2');
  const second = app.locator('[data-scr="account:claude:account-2"] [data-account-switch]');
  await second.click();
  const dialog = app.getByRole('dialog', { name: 'Switch Account?' });
  await expect(dialog).toBeVisible();
  await dialog.getByRole('button', { name: 'Cancel', exact: true }).click();
  await expect(second).toBeFocused();
  await expect(second).toHaveAttribute('aria-checked', 'false');
  await second.click();
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(second).toHaveAttribute('aria-checked', 'true');
  await page.reload();
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-2"]')).toHaveAttribute('data-inactive-account', 'false');
});

test('reordering accounts updates All Usage and survives a reload', async ({ page }) => {
  await openHome(page);
  await openAccounts(page);
  const app = page.locator('[data-mock]');
  const accountRows = app.locator('[data-account-list-row][data-provider="claude"]');
  await app.locator('[data-drag-account="claude:account-2"]').dragTo(app.locator('[data-drag-account="claude:account-1"]'));
  await expect(accountRows.first()).toHaveAttribute('data-account-id', 'account-2');
  await expect(accountRows.locator('[data-in-use="claude"]:visible')).toHaveAttribute('data-account-id', 'account-1');
  await app.getByRole('button', { name: 'Back', exact: true }).click();
  await page.reload();
  await allUsage(page);
  const cards = app.locator('[data-family="claude"] [data-card]');
  await expect(cards.first()).toHaveAttribute('data-card', 'claude-account-2');
  await expect(cards.last()).toHaveAttribute('data-card', 'claude-account-1');
});

test('display settings and separate account cards survive a reload', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await chooseSetting(page, 'All Usage Layout', 'Cards');
  await chooseSetting(page, 'Time Format', '12-hour');
  await chooseSetting(page, 'Show Usage As', 'Left');
  await chooseSetting(page, 'Reset Times', 'Countdown');
  await app.getByRole('switch', { name: 'Show Total Spend', exact: true }).click();
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app).toHaveAttribute('data-layout', 'cards');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(app).toHaveAttribute('data-reset', 'relative');
  await allUsage(page);
  await expect(app.locator('.am-spend-card')).toBeHidden();
  await expect(app.locator('[data-family="claude"] .am-account-caption [data-account-name]')).toHaveText(['Account 1', 'Account 2']);
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
});

test('menu bar preview applies pinned selection and filters text values in Bars mode', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const detail = app.locator('[data-scr="account:claude:account-1"]');
  await detail.locator('[data-pin="claude.today"]').click();
  await detail.locator('[data-pin="claude.fable"]').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await app.locator('.am-scr:not([hidden]) .am-back').click();
  await openSettings(page);
  await chooseSetting(page, 'Menu Bar Items', 'Pinned Only');
  await expect(app.locator('.am-menu-preview-item')).toHaveCount(2);
  await chooseSetting(page, 'Icon Style', 'Bars');
  await expect(app.locator('.am-menu-preview-item')).toHaveCount(1);
  await expect(app.locator('.am-menu-preview-bar')).toHaveAttribute('aria-label', 'Claude Fable 100%');
  await chooseSetting(page, 'Max Items In Menu Bar', 'App Icon Only');
  await expect(app.locator('[data-menu-bar-preview]')).toHaveText('◉');
});

test('settings saved before the egasu rename are restored and remain editable', async ({ page }) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('openusage.site.preview.v1')) return;
    localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
      preferences: { theme: 'Dark', showUsageAs: 'Left', usageCards: 'Single Card' },
      activeAccounts: { claude: 'account-1' },
      viewedAccounts: { claude: 'account-2' },
    }));
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
  await expect(app.locator('[data-card="claude-account-1"]')).toBeVisible();
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Light');
  expect(await page.evaluate(() => JSON.parse(localStorage.getItem('openusage.site.preview.v1')!).preferences))
    .toMatchObject({ theme: 'Light', showUsageAs: 'Left', allUsageLayout: 'Minimal' });
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'light');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await allUsage(page);
  await expect(app.locator('[data-card="claude-account-2"]')).toBeVisible();
});

test('legacy meter and reset settings survive the egasu rename', async ({ page }) => {
  await page.addInitScript(() => {
    localStorage.setItem('openusage.site.meterStyle', 'left');
    localStorage.setItem('openusage.site.resetDisplayMode', 'relative');
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-mode', 'left');
  await expect(app).toHaveAttribute('data-reset', 'relative');
});

test('invalid saved settings recover with defaults and a visible explanation', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', '{broken'));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await expect(app).toHaveAttribute('data-mode', 'used');
  await expect(app.getByRole('status')).toContainText('Saved preview settings could not be loaded');
  await expect(app.locator('[data-dashboard-panel="Priority"]')).toBeVisible();
});

test('blocked storage reports unsaved changes while the current preview still works', async ({ page }) => {
  await page.addInitScript(() => {
    Storage.prototype.setItem = () => { throw new DOMException('Storage is blocked', 'SecurityError'); };
  });
  await openHome(page);
  const app = page.locator('[data-mock]');
  await openSettings(page);
  await chooseSetting(page, 'Theme', 'Dark');
  await expect(app).toHaveAttribute('data-theme', 'dark');
  await expect(app.getByRole('status')).toContainText('Preview changes could not be saved');
  await page.reload();
  await expect(app).toHaveAttribute('data-theme', 'light');
});
