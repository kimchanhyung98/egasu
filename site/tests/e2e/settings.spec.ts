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
  for (const accountID of ['account-1', 'account-2']) {
    const card = app.locator(`[data-card="claude-${accountID}"]`);
    await expect(card).toBeVisible();
    await expect(card.locator('[data-row="claude.session"]')).toBeVisible();
  }
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

test('pinned-only guidance is beside the setting when the saved pin cannot show', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only' }, activeAccounts: {}, enabledProviders: ['antigravity'],
    pinnedMetrics: ['claude.fable@account-1'],
  })));
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(app.locator('[data-menu-bar-preview]')).toHaveText('◉');
  const row = app.locator('.am-item').filter({ has: page.getByRole('button', { name: 'Menu Bar Items', exact: true }) });
  await expect(row.getByRole('button', {
    name: 'Choose Priority or Pinned Only, then pin metrics in All Usage to show them in the menu bar.', exact: true,
  })).toBeVisible();
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

test('active account switch announces unavailability and keeps focus after switching', async ({ page }) => {
  await openHome(page);
  const app = page.locator('[data-mock]');
  await accountDetail(page, 'claude');
  const firstDetail = app.locator('[data-scr="account:claude:account-1"]');
  const first = firstDetail.getByRole('switch', { name: 'Use This Account' });
  const second = app.locator('[data-scr="account:claude:account-2"] [data-account-switch]');
  const dialog = app.locator('[data-account-dialog]');
  await expect(first).toHaveAttribute('aria-disabled', 'true');
  await expect(first).toHaveJSProperty('disabled', false);
  await first.press('Enter');
  await expect(first).toBeFocused();
  await expect(dialog).toBeHidden();

  await firstDetail.locator('.am-back').click();
  await app.locator('[data-account-list] .am-open[data-go="account:claude:account-2"]').click();
  await expect(second).toHaveAttribute('aria-disabled', 'false');
  await second.click();
  await dialog.getByRole('button', { name: 'Switch Account', exact: true }).click();
  await expect(second).toHaveAttribute('aria-checked', 'true');
  await expect(second).toHaveAttribute('aria-disabled', 'true');
  await expect(second).toHaveJSProperty('disabled', false);
  await expect(second).toBeFocused();
  await expect(firstDetail.locator('[data-account-switch]')).toHaveAttribute('aria-disabled', 'false');
});

test('dashboard account display describes its localized action while preserving the visible accessible name', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { language: '한국어' }, activeAccounts: {},
  })));
  await openHome(page);
  await allUsage(page);
  const app = page.locator('[data-mock]');
  const cardName = app.locator('[data-card="claude-account-1"] [data-toggle-account-name]');
  const priorityName = app.locator('[data-priority-key="claude.weekly@account-1"] [data-toggle-account-name]');
  const showEmails = '대시보드에 예시 이메일 주소를 표시합니다.';
  const showNames = '대시보드에 계정 이름을 표시합니다.';
  const masked = 'Privacy Mode에서는 이름과 이메일 주소가 가려집니다.';
  await expect(cardName).toHaveAccessibleDescription(showEmails);
  await expect(cardName).toHaveAccessibleName((await cardName.textContent())!.trim());
  await cardName.press('Enter');
  await expect(cardName).toHaveAccessibleName('claude.account-1@example.com');
  await expect(cardName).toHaveAccessibleDescription(showNames);
  await expect(cardName).toBeFocused();

  await app.locator('button[role="tab"][data-dashboard-tab="Priority"]').click();
  await expect(priorityName).toHaveAccessibleDescription(showNames);
  await priorityName.press('Enter');
  await expect(priorityName).toHaveAccessibleDescription(showEmails);
  await expect(priorityName).toBeFocused();

  await app.locator('[data-options]').click();
  await app.locator('.am-optmenu [data-go="settings"]').click();
  await app.locator('button[data-settings-tab="Advanced"]').click();
  await app.locator('[data-setting="privacyMode"]').click();
  await app.locator('[data-scr="settings"] .am-back').click();
  await expect(priorityName).toHaveAccessibleName('••••@example.com');
  await expect(priorityName).toHaveAccessibleDescription(masked);
  await allUsage(page);
  await expect(cardName).toHaveAccessibleName('••••@example.com');
  await expect(cardName).toHaveAccessibleDescription(masked);
});


test('menu bar text options update names and periods, survive reload and disable for non-text styles', async ({ page }) => {
  await page.addInitScript(() => {
    if (localStorage.getItem('openusage.site.preview.v1')) return;
    localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
      preferences: { menuBarItems: 'Pinned Only', menuBarLimit: 'Up to 1' },
      activeAccounts: {},
      pinnedMetrics: ['claude.weekly@account-1'], accountNames: { 'claude:account-1': 'Personal' },
    }));
  });
  await openHome(page);
  await openSettings(page);
  const app = page.locator('[data-mock]');
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  const names = app.getByRole('switch', { name: 'Show Account Names', exact: true });
  const metrics = app.getByRole('switch', { name: 'Show Metric Labels', exact: true });
  const preview = app.locator('[data-menu-bar-preview]');
  await expect(names).toHaveAttribute('aria-checked', 'false');
  await expect(metrics).toHaveAttribute('aria-checked', 'true');
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('Weekly');
  await names.click();
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('Personal');
  await expect(preview).toContainText('7d');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/Claude Personal Weekly/);
  await metrics.click();
  await expect(preview).not.toContainText('7d');
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('Personal');
  await page.reload();
  await openSettings(page);
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(names).toHaveAttribute('aria-checked', 'true');
  await expect(metrics).toHaveAttribute('aria-checked', 'false');
  await chooseSetting(page, 'Icon Style', 'Bars');
  await expect(names).toBeDisabled();
  await expect(metrics).toBeDisabled();
  await chooseSetting(page, 'Icon Style', 'Text');
  await expect(names).toBeEnabled();
  await chooseSetting(page, 'Max Items In Menu Bar', 'App Icon Only');
  await expect(names).toBeDisabled();
  await expect(metrics).toBeDisabled();
  await chooseSetting(page, 'Max Items In Menu Bar', 'Up to 1');
  await app.getByRole('tab', { name: 'Advanced', exact: true }).click();
  await app.getByRole('switch', { name: 'Privacy Mode', exact: true }).click();
  await app.getByRole('tab', { name: 'Display', exact: true }).click();
  await expect(preview).not.toContainText('Personal');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/Claude Weekly/);
  await expect(preview.getByRole('img')).not.toHaveAccessibleName(/Personal/);
});

test('menu bar names and initials use the selected language', async ({ page }) => {
  await page.addInitScript(() => localStorage.setItem('openusage.site.preview.v1', JSON.stringify({
    preferences: { menuBarItems: 'Pinned Only', menuBarLimit: 'Up to 1', language: '한국어' },
    activeAccounts: {}, pinnedMetrics: ['claude.weekly@account-1'],
  })));
  await openHome(page);
  const app = page.locator('[data-mock]');
  await app.locator('[data-options]').click();
  await app.locator('[data-go="settings"]').click();
  await app.locator('[data-settings-tab="Display"]').click();
  const preview = app.locator('[data-menu-bar-preview]');
  await expect(preview.locator('.am-menu-preview-item > span:first-child')).toHaveText('Claude 계1');
  await app.locator('[data-setting="menuBarAccountNames"]').click();
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('계정 1');
  await expect(preview.getByRole('img')).toHaveAccessibleName(/계정 1/);
  await app.locator('[data-settings-tab="General"]').click();
  await app.locator('[data-picker="language"]').click();
  await app.locator('[data-pick="language"][data-value="日本語"]').click();
  await app.locator('[data-settings-tab="Display"]').click();
  await expect(preview.locator('.am-menu-preview-label')).toHaveText('アカウント1');
  await app.locator('[data-setting="menuBarAccountNames"]').click();
  await expect(preview.locator('.am-menu-preview-item > span:first-child')).toHaveText('Claude ア');
});
